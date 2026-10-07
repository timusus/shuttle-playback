import Foundation
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

/// What the container says about the audio behind a ``StreamByteReader``.
public struct StreamAudioFormat: Equatable {
    /// The SOURCE's rate. The player runs at it; nothing here resamples.
    public let sampleRate: Double
    public let channelCount: Int
    /// From the container (`AVFormatContext.duration`: MP4's sample table, MP3's Xing TOC, or
    /// `Content-Length` ÷ bitrate). Zero when the container does not know, in which case the
    /// caller falls back to feed metadata (plan §5.3).
    public let duration: TimeInterval
    public let codec: String
    public let container: String

    public init(sampleRate: Double, channelCount: Int, duration: TimeInterval, codec: String, container: String) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.codec = codec
        self.container = container
    }
}

/// **How much of the stream ``FFmpegStreamDecoder/open()`` may spend identifying it.**
///
/// libavformat's own defaults are a 5 MB probe and 5 s of analysis, spent before the first frame
/// plays; for a decoder whose bytes may be cellular data that is the wrong trade. ``default`` is the
/// budget this decoder has always used (64 KiB, 1 s), which identifies a single-stream podcast
/// container as well as the full probe does. An app whose files need more analysis passes a larger
/// one; a value <= 0 falls back to the default on the C side.
public struct StreamProbeBudget: Equatable, Sendable {
    /// Upper bound on bytes read while probing (`AVFormatContext.probesize`).
    public var bytes: Int64
    /// Upper bound on media analysed for stream info (`AVFormatContext.max_analyze_duration`).
    public var analyzeDuration: TimeInterval

    public init(bytes: Int64, analyzeDuration: TimeInterval) {
        self.bytes = bytes
        self.analyzeDuration = analyzeDuration
    }

    /// 64 KiB and 1 s: `STREAM_DECODE_DEFAULT_PROBE_BYTES` and `STREAM_DECODE_DEFAULT_MAX_ANALYZE_US`.
    public static let `default` = StreamProbeBudget(bytes: 64 * 1024, analyzeDuration: 1)
}

/// Why a decoder stopped producing audio.
public enum StreamDecoderError: Error, Equatable, CustomStringConvertible {
    /// This build has no FFmpeg xcframework, so there is no decode path at all.
    case unavailable
    /// `open()` was called twice, or a read/seek was asked for before `open()`.
    case invalidState(String)
    /// FFmpeg refused the bytes. `status` is a `StreamDecodeStatus`.
    case failed(status: Int32)
    /// The reader was cancelled while the decoder was waiting on it.
    case cancelled
    /// The call was ended early by ``FFmpegStreamDecoder/interrupt()`` so the caller could seek.
    /// **Not terminal**: the decoder is still open, and the seek that follows clears it. When
    /// `open()` throws it, nothing was opened: the caller opens again, with a fresh decoder.
    case interrupted

    public var description: String {
        switch self {
        case .unavailable: return "no streaming decode path in this build"
        case let .invalidState(why): return "streaming decoder: \(why)"
        case let .failed(status): return "streaming decode failed, status \(status)"
        case .cancelled: return "streaming decode cancelled"
        case .interrupted: return "streaming decode interrupted for a seek"
        }
    }
}

/// **The playback decoder: encoded bytes in, interleaved float32 out, a chunk at a time.**
///
/// The streaming sibling of Shuttle Podcasts' `AudioDecoder`, and the reason the two are separate
/// is worth stating plainly: `AudioDecoder` produces the ad-skip matcher's 8 kHz mono PCM, which is defined by the
/// bench and measured bit for bit against it. This produces what the *player* schedules — the
/// source's own rate and channel count — over a reader that may block. Plan of record:
/// `mobile/ios/docs/plans/2026-09-09-streaming-audio-pipeline.md` §6 Phase 1.
///
/// Not thread-safe. One thread calls `open`, `seek` and `nextChunk`; ``cancel()`` and
/// ``interrupt()`` are the two calls allowed from another thread. `cancel` turns a stalled network
/// read into a clean end; `interrupt` brings it back so a seek can be applied and leaves the
/// decoder usable.
public final class FFmpegStreamDecoder {

    /// Why ``nextChunk()`` last returned nil. `.running` until it has.
    public enum EndReason: String {
        case running, eof, failure, cancelled
        /// ``interrupt()`` brought the read back so a seek could be applied. The only one of these
        /// a caller must NOT report as the end of an episode: the next ``seek(toSeconds:)`` puts
        /// the decoder back to `.running`.
        case interrupted
    }

    /// Frames per ``nextChunk()``, about 93 ms at 44.1 kHz. The one definition: the player reads it
    /// as `PlaybackTunables.framesPerChunk` and derives its decode budget from it. A chunk is large
    /// enough that scheduling is not per-codec-frame — an MP3 frame is 1152 frames, an AAC one 1024
    /// — and small enough that a seek discards little.
    public static let framesPerChunk = 4096

    /// Whether this build has the streaming decode path (`scripts/build-ffmpeg.sh`).
    public static var isAvailable: Bool {
        #if canImport(CStreamDecode)
            return true
        #else
            return false
        #endif
    }

    private let reader: StreamByteReader
    /// Kept for the lifetime of the decoder because the C side holds an unretained pointer to it.
    private let box: ReaderBox
    private var format: StreamAudioFormat?
    private var reason: EndReason = .running
    private var framesRead: Int64 = 0
    private var chunk: [Float] = []
    private let probeBudget: StreamProbeBudget
    #if canImport(CStreamDecode)
        private var handle: OpaquePointer?
    #endif

    public init(reader: StreamByteReader, probeBudget: StreamProbeBudget = .default) {
        self.reader = reader
        self.box = ReaderBox(reader: reader)
        self.probeBudget = probeBudget
    }

    deinit {
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_close(handle) }
        #endif
    }

    public var endReason: EndReason { reason }

    /// Frames of *media* handed to the caller so far. Media time, not wall time: position is this
    /// divided by the sample rate (plan §5.1), which is why silence the DSP drops never moves it.
    public var mediaFramesRead: Int64 { framesRead }

    /// Bytes the reader has been asked for. The bandwidth number the `moov`-at-end test asserts on.
    public var bytesConsumed: Int64 {
        #if canImport(CStreamDecode)
            if let handle { return stream_decoder_position_bytes(handle) }
        #endif
        return 0
    }

    /// Probe the container and open its best audio stream. Blocking: it reads through `reader`.
    ///
    /// A failure here is always thrown, never swallowed — the caller's answer to it is the
    /// `AVPlayer` fallback with a counter (plan §1), and a decoder that reported success on
    /// nothing would present as an episode that plays silence and never ends.
    @discardableResult
    public func open() throws -> StreamAudioFormat {
        #if canImport(CStreamDecode)
            guard handle == nil else { throw StreamDecoderError.invalidState("already open") }
            var callbacks = StreamDecodeCallbacks(
                read: { opaque, buffer, count in
                    guard let opaque, let buffer else { return Int32(STREAM_READ_ERROR) }
                    return ReaderBox.from(opaque).read(into: buffer, count: count)
                },
                seek: { opaque, offset in
                    guard let opaque else { return Int32(STREAM_READ_ERROR) }
                    return ReaderBox.from(opaque).seek(to: offset)
                },
                size: { opaque in
                    guard let opaque else { return -1 }
                    return ReaderBox.from(opaque).size()
                }
            )
            var info = StreamAudioInfo()
            var status: Int32 = 0
            let opaque = Unmanaged.passUnretained(box).toOpaque()
            var options = StreamDecodeOptions(
                probe_bytes: probeBudget.bytes,
                max_analyze_duration_us: Int64((probeBudget.analyzeDuration * 1_000_000).rounded())
            )
            guard let opened = stream_decoder_open_with(&callbacks, opaque, &options, &info, &status) else {
                // An interrupt is a seek arriving while the episode opens, not a format this build
                // cannot play: `.failed` would send the caller to its `AVPlayer` fallback.
                switch status {
                case Int32(STREAM_DECODE_ERR_CANCELLED.rawValue):
                    reason = .cancelled
                    throw StreamDecoderError.cancelled
                case Int32(STREAM_DECODE_ERR_INTERRUPTED.rawValue):
                    reason = .interrupted
                    throw StreamDecoderError.interrupted
                default:
                    reason = .failure
                    throw StreamDecoderError.failed(status: status)
                }
            }
            handle = opened
            let format = StreamAudioFormat(
                sampleRate: Double(info.sample_rate),
                channelCount: Int(info.channel_count),
                duration: info.duration_sec,
                codec: Self.string(from: &info.codec_name, capacity: 32),
                container: Self.string(from: &info.container_name, capacity: 64)
            )
            self.format = format
            chunk = [Float](repeating: 0, count: Self.framesPerChunk * max(format.channelCount, 1))
            return format
        #else
            throw StreamDecoderError.unavailable
        #endif
    }

    /// Seek to `seconds` and return where the stream actually landed.
    ///
    /// **The return value is the answer, not the argument.** It is the first decoded frame's
    /// timestamp; MP3 without a TOC lands on a frame boundary near a bitrate estimate. A caller
    /// that set its position to the requested number instead would show a scrubber that disagrees
    /// with the audio, and every ad-skip seek would be computed against a time nobody played
    /// (plan §5.1).
    @discardableResult
    public func seek(toSeconds seconds: TimeInterval) throws -> TimeInterval {
        #if canImport(CStreamDecode)
            guard let handle else { throw StreamDecoderError.invalidState("not open") }
            // The seek is the answer to an interruption, so both sides of it are cleared before
            // anything reads: leaving either latched would make one interrupted read permanent.
            reader.clearInterrupt()
            stream_decoder_clear_interrupt(handle)
            var landed: Double = 0
            let status = stream_decoder_seek(handle, seconds, &landed)
            switch status {
            case Int32(STREAM_DECODE_OK.rawValue):
                reason = .running
                framesRead = Int64((landed * (format?.sampleRate ?? 0)).rounded())
                return landed
            case Int32(STREAM_DECODE_EOF.rawValue):
                reason = .eof
                return landed
            case Int32(STREAM_DECODE_ERR_CANCELLED.rawValue):
                reason = .cancelled
                throw StreamDecoderError.cancelled
            case Int32(STREAM_DECODE_ERR_INTERRUPTED.rawValue):
                reason = .interrupted
                throw StreamDecoderError.interrupted
            default:
                reason = .failure
                throw StreamDecoderError.failed(status: status)
            }
        #else
            throw StreamDecoderError.unavailable
        #endif
    }

    /// Shrink the byte budget one seek may spend before it falls back to the byte estimate.
    /// **Tests only** — see `stream_decoder_set_seek_budget_bytes`.
    public func setSeekBudgetBytesForTesting(_ bytes: Int64) {
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_set_seek_budget_bytes(handle, bytes) }
        #endif
    }

    /// The next chunk of interleaved float32 in [-1, 1], or nil once the stream has ended.
    ///
    /// nil is not by itself "the episode finished": ``endReason`` says whether it was EOF, a
    /// cancel or a failure, and the caller must distinguish them. Reporting a transport failure as
    /// the end of an episode marks it played and moves the listener on (plan §5.4).
    public func nextChunk() -> [Float]? {
        #if canImport(CStreamDecode)
            guard let handle, let format, reason == .running else { return nil }
            var frames: Int32 = 0
            let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return Int32(STREAM_DECODE_ERR_ARGS.rawValue) }
                return stream_decoder_read(handle, base, Int32(Self.framesPerChunk), &frames)
            }
            guard status == Int32(STREAM_DECODE_OK.rawValue), frames > 0 else {
                switch status {
                case Int32(STREAM_DECODE_EOF.rawValue): reason = .eof
                case Int32(STREAM_DECODE_ERR_CANCELLED.rawValue): reason = .cancelled
                case Int32(STREAM_DECODE_ERR_INTERRUPTED.rawValue): reason = .interrupted
                default: reason = .failure
                }
                return nil
            }
            framesRead += Int64(frames)
            let count = Int(frames) * format.channelCount
            return count == chunk.count ? chunk : Array(chunk[0..<count])
        #else
            return nil
        #endif
    }

    /// Abort the decode from any thread. Unblocks a reader that is waiting on the network; the
    /// pull loop then returns nil with ``endReason`` `.cancelled`.
    public func cancel() {
        box.cancel()
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_cancel(handle) }
        #endif
    }

    /// Bring a blocked read back so a seek can be applied, leaving the decoder open.
    ///
    /// The race it closes is the player's: the pull loop can be inside a read on a stalled
    /// connection while a seek waits behind it on the same serial queue, so on a dead link the seek
    /// never happens and on a slow one it lands late. ``cancel()`` would answer it and end the
    /// episode; this ends only the call. Safe from any thread.
    public func interrupt() {
        box.interrupt()
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_interrupt(handle) }
        #endif
    }

    #if canImport(CStreamDecode)
        /// Read a fixed-size C char array as a Swift string. `withUnsafeBytes` on the imported
        /// tuple is the only way to see it as contiguous storage.
        private static func string<T>(from field: inout T, capacity: Int) -> String {
            withUnsafeBytes(of: &field) { raw in
                let bytes = raw.bindMemory(to: CChar.self)
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base)
            }
        }
    #endif
}

/// The bridge the C callbacks land in. It exists so the `@convention(c)` closures have a single
/// class to recover from their `void *` — a Swift closure with captured state cannot be one.
private final class ReaderBox {
    private let reader: StreamByteReader

    init(reader: StreamByteReader) { self.reader = reader }

    static func from(_ opaque: UnsafeMutableRawPointer) -> ReaderBox {
        Unmanaged<ReaderBox>.fromOpaque(opaque).takeUnretainedValue()
    }

    func cancel() { reader.cancel() }

    func interrupt() { reader.interrupt() }

    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        do {
            let n = try reader.read(into: UnsafeMutableRawPointer(buffer), maxLength: Int(count))
            /* Zero from the reader means end of stream, and it must not reach libavformat as a
             * zero: a 0-length read there is "nothing yet, ask again" and it spins forever. */
            return n > 0 ? Int32(n) : Int32(STREAM_READ_EOF)
        } catch StreamByteReaderError.cancelled {
            return Int32(STREAM_READ_CANCELLED)
        } catch StreamByteReaderError.interrupted {
            return Int32(STREAM_READ_INTERRUPTED)
        } catch {
            return Int32(STREAM_READ_ERROR)
        }
    }

    func seek(to offset: Int64) -> Int32 {
        do {
            try reader.seek(to: offset)
            return 0
        } catch StreamByteReaderError.cancelled {
            return Int32(STREAM_READ_CANCELLED)
        } catch StreamByteReaderError.interrupted {
            return Int32(STREAM_READ_INTERRUPTED)
        } catch {
            return Int32(STREAM_READ_ERROR)
        }
    }

    func size() -> Int64 {
        reader.totalLength ?? -1
    }
}
