import Foundation

/// Runs the sequencer's decode jobs one at a time, in order: a serial queue, or a hand-stepped fake.
protocol SequencerExecutor: Sendable {
    func run(_ job: @escaping @Sendable () -> Void)
}

struct SerialQueueExecutor: SequencerExecutor {
    private let queue = DispatchQueue(label: "PlaybackRender.Sequencer", qos: .userInitiated)

    func run(_ job: @escaping @Sendable () -> Void) {
        queue.async(execute: job)
    }
}

/// Owns a window of items in play order and the joins between them (ADR-0018): it decodes ahead on
/// its executor into a small buffer and hands out `TaggedChunk`s tagged (item, media frame).
///
/// Threading rule: callers use it from one queue (the feeder's) and never wait on decode, because
/// sources are read only inside executor jobs and the lock is never held across a source call.
///
/// The window is the only record of items. Decode-ahead joins down it across any number of items;
/// an item leaves it only through `setCurrent` or `release(before:)`, so a seek may land in any item
/// still there and replays the ones after it. Item numbers are unique within the window.
///
/// Every `setCurrent` and `seek` starts a new epoch: the buffer is emptied, the source in flight is
/// interrupted, and whatever an older job decodes is dropped. `setNext` and `clearNext` change only
/// the window's unstarted tail, so they cannot remove audio already decoded; the transport seeks for that.
final class Sequencer: @unchecked Sendable {
    enum Pull {
        case chunk(TaggedChunk)
        /// Decode is behind; pull again later.
        case pending
        /// The last item in the window ended, or nothing is set. A later `setNext` resumes it.
        case ended
        /// The item's source failed; nothing more comes until a `seek` or `setCurrent`.
        case failed(item: Int, error: any Error)
    }

    /// About 370 ms at 44.1 kHz: the feeder keeps its own depth, this only hides decode jitter.
    static let bufferCapacity = 4

    private final class Entry: @unchecked Sendable {
        let item: Int
        let source: any ItemSource
        // Executor-only: set once the source is opened.
        var format: PCMFormat?
        // Locked: decode has reached it, so `setNext` and `clearNext` leave it alone.
        var started = false

        init(item: Int, source: any ItemSource) {
            self.item = item
            self.source = source
        }
    }

    /// The item being decoded and where it has got to.
    private struct Cursor {
        var entry: Entry
        var seekTo: Int64?
        var nextFrame: Int64 = 0
        var tagged = false
        var ended = false
    }

    private let executor: any SequencerExecutor
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var window: [Entry] = []
    private var cursor: Cursor?
    private var buffer: [TaggedChunk] = []
    private var failure: (item: Int, error: any Error)?
    private var scheduled = false

    init(executor: any SequencerExecutor) {
        self.executor = executor
    }

    /// Replaces the whole window with `item` and decodes it from `startFrame` (its start when nil).
    func setCurrent(item: Int, source: any ItemSource, startFrame: Int64? = nil) {
        let interruptStale = lock.withLock {
            let entry = Entry(item: item, source: source)
            entry.started = true
            window = [entry]
            return restart(Cursor(entry: entry, seekTo: startFrame))
        }
        interruptStale()
    }

    /// Follows the window's last item with no gap once it ends: replaces the last item if decode has
    /// not reached it, else appends.
    func setNext(item: Int, source: any ItemSource) {
        lock.withLock {
            let entry = Entry(item: item, source: source)
            if let last = window.last, !last.started {
                window[window.count - 1] = entry
            } else {
                window.append(entry)
            }
            schedule()
        }
    }

    /// Removes the window's last item if decode has not reached it.
    func clearNext() {
        lock.withLock {
            if let last = window.last, !last.started { window.removeLast() }
        }
    }

    /// Restarts decode at `mediaFrame` of `item`, which must still be in the window; the feeder's
    /// `resupply(from:)` passes its `MediaPositionMap.Position` straight through.
    func seek(item: Int, mediaFrame: Int64) {
        let interruptStale = lock.withLock {
            guard let entry = window.first(where: { $0.item == item }) else {
                preconditionFailure("seek to item \(item), which is not in the window")
            }
            entry.started = true
            return restart(Cursor(entry: entry, seekTo: mediaFrame))
        }
        interruptStale()
    }

    /// Drops the items before `item`, which nothing can seek to any more: the transport calls it on
    /// each `crossed(item:)`. Never drops the item being decoded or any after it.
    func release(before item: Int) {
        lock.withLock {
            guard let end = window.firstIndex(where: { $0.item == item }),
                  let cursor, let decoding = window.firstIndex(where: { $0 === cursor.entry }) else { return }
            // A crossed event can trail a seek back past its item.
            window.removeFirst(min(end, decoding))
        }
    }

    /// Never blocks on decode.
    func pull() -> Pull {
        lock.withLock {
            if !buffer.isEmpty {
                let chunk = buffer.removeFirst()
                schedule()
                return .chunk(chunk)
            }
            if let failure { return .failed(item: failure.item, error: failure.error) }
            guard let cursor, !(cursor.ended && entry(after: cursor.entry) == nil) else { return .ended }
            return .pending
        }
    }

    // MARK: Decode, on the executor

    /// Locked. Returns the interrupt of the source in flight, to call once the lock is released:
    /// an interrupt may take the source's own locks, and pull must never wait on those.
    private func restart(_ newCursor: Cursor) -> () -> Void {
        let stale = cursor?.entry.source
        let staleEpoch = epoch
        epoch &+= 1
        cursor = newCursor
        buffer = []
        failure = nil
        scheduled = false
        schedule()
        return { stale?.interrupt(through: staleEpoch) }
    }

    /// Locked. At most one job is queued for the current epoch.
    private func schedule() {
        guard !scheduled, failure == nil, buffer.count < Self.bufferCapacity,
              let cursor, !cursor.ended || entry(after: cursor.entry) != nil else { return }
        scheduled = true
        let epoch = epoch
        executor.run { [self] in step(epoch) }
    }

    /// Locked.
    private func entry(after entry: Entry) -> Entry? {
        guard let index = window.firstIndex(where: { $0 === entry }), index + 1 < window.count else { return nil }
        return window[index + 1]
    }

    /// Decodes one chunk, joining first if the cursor's item has ended.
    private func step(_ jobEpoch: UInt64) {
        guard let cursor: Cursor = lock.withLock({
            guard jobEpoch == epoch, let cursor = self.cursor else { return nil }
            guard cursor.ended else { return cursor }
            // The next item was cleared after this job was queued; decoding the ended one again
            // would tag it twice.
            guard let next = entry(after: cursor.entry) else {
                scheduled = false
                return nil
            }
            joinGapless(to: next)
            return self.cursor
        }) else { return }

        let entry = cursor.entry
        entry.source.begin(epoch: jobEpoch)
        let outcome = Result<(landed: Int64?, samples: [Float]?), any Error> {
            if entry.format == nil { entry.format = try entry.source.open() }
            let landed = try cursor.seekTo.map { try entry.source.seek(toFrame: $0) }
            return (landed, try entry.source.nextChunk())
        }

        lock.withLock {
            guard jobEpoch == epoch, var current = self.cursor else { return }
            scheduled = false
            switch outcome {
            case let .failure(error):
                failure = (entry.item, error)
            case let .success((landed, samples)):
                if let landed { current.nextFrame = landed }
                current.seekTo = nil
                if let format = entry.format, let samples {
                    let frames = Int64(samples.count / format.channelCount)
                    let tag = SegmentTag(item: entry.item, mediaStartFrame: current.nextFrame, frameCount: frames)
                    buffer.append(TaggedChunk(samples: samples, format: format, tags: [tag]))
                    current.nextFrame += frames
                    current.tagged = true
                } else if let format = entry.format {
                    // The timeline reports an item crossed by its tag, so one that played nothing still sends one.
                    if !current.tagged {
                        let tag = SegmentTag(item: entry.item, mediaStartFrame: current.nextFrame, frameCount: 0)
                        buffer.append(TaggedChunk(samples: [], format: format, tags: [tag]))
                    }
                    current.ended = true
                }
            }
            self.cursor = current
            schedule()
        }
    }

    /// Locked. The one join: next starts from its first frame straight after the ended item's last,
    /// and a format change falls here, between chunks. Crossfade replaces this with a `Transition`
    /// that starts before the item ends, reading its tail and next's head to mix them.
    private func joinGapless(to next: Entry) {
        next.started = true
        // A source read before (a seek back replaying the window) is rewound to its start.
        cursor = Cursor(entry: next, seekTo: next.format == nil ? nil : 0)
    }
}
