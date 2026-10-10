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

/// Owns the current and next item sources and the join between them (ADR-0018): it decodes ahead
/// on its executor into a small buffer and hands out `TaggedChunk`s tagged (item, media frame).
///
/// Threading rule: callers use it from one queue (the feeder's) and never wait on decode, because
/// sources are read only inside executor jobs and the lock is never held across a source call.
///
/// Every `setCurrent` and `seek` starts a new epoch: the buffer is emptied, the source in flight is
/// interrupted, and whatever an older job decodes is dropped. `setNext` and `clearNext` change only
/// what follows current's end, so they cannot remove audio already decoded past a join; the
/// transport seeks for that.
final class Sequencer: @unchecked Sendable {
    enum Pull {
        case chunk(TaggedChunk)
        /// Decode is behind; pull again later.
        case pending
        /// Current ended with no next set, or nothing is set. A later `setNext` resumes it.
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
    private var cursor: Cursor?
    private var next: Entry?
    // The item last joined from, kept so a resupply into its tail (an auto-flush) can go back to it.
    private var previous: Entry?
    private var buffer: [TaggedChunk] = []
    private var failure: (item: Int, error: any Error)?
    private var scheduled = false

    init(executor: any SequencerExecutor) {
        self.executor = executor
    }

    /// Replaces everything, next and the joined-from item included, and decodes `item` from
    /// `startFrame` (its start when nil).
    func setCurrent(item: Int, source: any ItemSource, startFrame: Int64? = nil) {
        lock.withLock {
            restart(Cursor(entry: Entry(item: item, source: source), seekTo: startFrame))
            next = nil
            previous = nil
        }
    }

    /// Follows current with no gap once current ends, replacing any next not yet joined.
    func setNext(item: Int, source: any ItemSource) {
        lock.withLock {
            next = Entry(item: item, source: source)
            if cursor?.ended == true { schedule() }
        }
    }

    func clearNext() {
        lock.withLock { next = nil }
    }

    /// Restarts decode at `mediaFrame` of `item`, which is current or the item last joined from; the
    /// feeder's `resupply(from:)` passes its `MediaPositionMap.Position` straight through.
    func seek(item: Int, mediaFrame: Int64) {
        lock.withLock {
            guard let current = cursor?.entry else { return }
            if item == current.item {
                restart(Cursor(entry: current, seekTo: mediaFrame))
            } else if let previous, item == previous.item {
                restart(Cursor(entry: previous, seekTo: mediaFrame))
                self.previous = nil
                next = current
            } else {
                assertionFailure("seek to item \(item), which is neither current nor the one joined from")
            }
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
            guard let cursor, !(cursor.ended && next == nil) else { return .ended }
            return .pending
        }
    }

    // MARK: Decode, on the executor

    /// Locked.
    private func restart(_ newCursor: Cursor) {
        // Under the lock, so the interrupt lands before the new epoch's first job clears it with a seek.
        cursor?.entry.source.interrupt()
        epoch &+= 1
        cursor = newCursor
        buffer = []
        failure = nil
        scheduled = false
        schedule()
    }

    /// Locked. At most one job is queued for the current epoch.
    private func schedule() {
        guard !scheduled, failure == nil, buffer.count < Self.bufferCapacity,
              let cursor, !cursor.ended || next != nil else { return }
        scheduled = true
        let epoch = epoch
        executor.run { [self] in step(epoch) }
    }

    /// Decodes one chunk, joining first if current has ended.
    private func step(_ jobEpoch: UInt64) {
        guard let cursor: Cursor = lock.withLock({
            guard jobEpoch == epoch else { return nil }
            if self.cursor?.ended == true { joinGapless() }
            return self.cursor
        }) else { return }

        let entry = cursor.entry
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

    /// Locked. The one join: next starts from its first frame straight after current's last, and a
    /// format change falls here, between chunks. Crossfade replaces this with a `Transition` that
    /// starts before current ends, reading its tail and next's head to mix them.
    private func joinGapless() {
        guard let ended = cursor?.entry, let joining = next else { return }
        previous = ended
        next = nil
        // A source read before (a seek back to the joined-from item) is rewound to its start.
        cursor = Cursor(entry: joining, seekTo: joining.format == nil ? nil : 0)
    }
}
