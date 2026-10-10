import Foundation
import PlaybackDecode

/// One queue item's decoded PCM as the sequencer drives it. Every call but `interrupt()` comes from
/// the sequencer's executor, one at a time, and may block on the network.
protocol ItemSource: AnyObject, Sendable {
    /// The format every chunk of this item has.
    func open() throws -> PCMFormat
    /// Sample-accurate (ADR-0009); returns the media frame it landed on, which reads continue from.
    func seek(toFrame frame: Int64) throws -> Int64
    /// Interleaved PCM, nil at the item's end. A failure throws, so it is never mistaken for an end.
    func nextChunk() throws -> [Float]?
    /// Any thread: brings a blocked call back early. The sequencer seeks or drops the source after it.
    func interrupt()
}

/// `FFmpegStreamDecoder` as an item source. The decoder already trims encoder delay and padding
/// (the gapless goldens), so its frames are the item's frames and the join adds no trim.
final class FFmpegItemSource: ItemSource, @unchecked Sendable {
    private let reader: StreamByteReader
    private let lock = NSLock()
    // Read by `interrupt()` from any thread; only the executor replaces it.
    private var decoder: FFmpegStreamDecoder?
    private var sampleRate: Double = 0

    init(reader: StreamByteReader) {
        self.reader = reader
    }

    func open() throws -> PCMFormat {
        // A decoder whose open was interrupted is unusable, so each open starts a fresh one; an
        // interrupt latched on the reader belongs to a call already dropped.
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

    func interrupt() {
        if let decoder = lock.withLock({ decoder }) {
            decoder.interrupt()
        } else {
            reader.interrupt()
        }
    }

    private func opened() throws -> FFmpegStreamDecoder {
        guard let decoder = lock.withLock({ decoder }) else { throw StreamDecoderError.invalidState("not open") }
        return decoder
    }
}
