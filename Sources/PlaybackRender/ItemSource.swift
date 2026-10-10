import Foundation
import PlaybackDecode

/// One queue item's decoded PCM as the sequencer drives it. Every call but `interrupt(through:)`
/// comes from the sequencer's executor, one at a time, and may block on the network.
protocol ItemSource: AnyObject, Sendable {
    /// Never blocks: the calls that follow belong to the sequencer's `epoch`.
    func begin(epoch: UInt64)
    /// The format every chunk of this item has.
    func open() throws -> PCMFormat
    /// Sample-accurate (ADR-0009); returns the media frame it landed on, which reads continue from.
    func seek(toFrame frame: Int64) throws -> Int64
    /// Interleaved PCM, nil at the item's end. A failure throws, so it is never mistaken for an end.
    func nextChunk() throws -> [Float]?
    /// Any thread, never blocks: brings back early every call of `epoch` or before, one in flight or
    /// one about to start, and leaves later epochs' calls alone.
    func interrupt(through epoch: UInt64)
}

/// `FFmpegStreamDecoder` as an item source. The decoder already trims encoder delay and padding
/// (the gapless goldens), so its frames are the item's frames and the join adds no trim.
final class FFmpegItemSource: ItemSource, @unchecked Sendable {
    private let reader: EpochReader
    private let lock = NSLock()
    // Read by `interrupt(through:)` from any thread; only the executor replaces it.
    private var decoder: FFmpegStreamDecoder?
    private var sampleRate: Double = 0

    init(reader: StreamByteReader) {
        self.reader = EpochReader(reader)
    }

    func begin(epoch: UInt64) {
        reader.begin(epoch: epoch)
    }

    func open() throws -> PCMFormat {
        // A decoder whose open was interrupted is unusable, so each open starts a fresh one. The
        // clear forgets an interrupt aimed at a dropped call and keeps one aimed at this epoch.
        reader.clearInterrupt()
        let decoder = FFmpegStreamDecoder(reader: reader)
        lock.withLock { self.decoder = decoder }
        do {
            let format = try decoder.open()
            sampleRate = format.sampleRate
            return PCMFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        } catch {
            lock.withLock { self.decoder = nil }
            throw error
        }
    }

    func seek(toFrame frame: Int64) throws -> Int64 {
        let decoder = try opened()
        try decoder.seek(toSeconds: Double(frame) / sampleRate)
        return decoder.mediaFramesRead
    }

    func nextChunk() throws -> [Float]? {
        let decoder = try opened()
        if let chunk = decoder.nextChunk() { return chunk }
        switch decoder.endReason {
        case .eof: return nil
        case .cancelled: throw StreamDecoderError.cancelled
        case .interrupted: throw StreamDecoderError.interrupted
        // `nextChunk()` does not surface FFmpeg's status, so -1 stands for "unknown".
        case .running, .failure: throw StreamDecoderError.failed(status: -1)
        }
    }

    func interrupt(through epoch: UInt64) {
        reader.interrupt(through: epoch) {
            if let decoder = lock.withLock({ decoder }) {
                decoder.interrupt()
            } else {
                reader.interrupt()
            }
        }
    }

    private func opened() throws -> FFmpegStreamDecoder {
        guard let decoder = lock.withLock({ decoder }) else { throw StreamDecoderError.invalidState("not open") }
        return decoder
    }
}

/// The reader the decoder sees. The decoder clears the interrupt flags at the start of every seek,
/// which would erase an interrupt landing just before; this re-raises one aimed at the epoch in flight.
private final class EpochReader: StreamByteReader, @unchecked Sendable {
    private let inner: StreamByteReader
    private let lock = NSLock()
    private var epoch: UInt64?
    private var interruptedThrough: UInt64?

    init(_ inner: StreamByteReader) {
        self.inner = inner
    }

    func begin(epoch: UInt64) {
        lock.withLock { self.epoch = epoch }
    }

    /// Records the interrupt, then runs `raise` if it is aimed at the calls in flight. Under the lock,
    /// so `raise` cannot land after a later `begin` and stop the next epoch's call.
    func interrupt(through epoch: UInt64, raise: () -> Void) {
        lock.withLock {
            interruptedThrough = max(interruptedThrough ?? epoch, epoch)
            if let current = self.epoch, current <= epoch { raise() }
        }
    }

    func clearInterrupt() {
        inner.clearInterrupt()
        // After the clear, so an interrupt racing it is either re-raised here or lands after it.
        let aimedHere = lock.withLock {
            guard let epoch, let interruptedThrough else { return false }
            return interruptedThrough >= epoch
        }
        if aimedHere { inner.interrupt() }
    }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        try inner.read(into: buffer, maxLength: maxLength)
    }

    func seek(to offset: Int64) throws {
        try inner.seek(to: offset)
    }

    func cancel() { inner.cancel() }

    func interrupt() { inner.interrupt() }
}
