import Foundation
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

/// What the container says about the audio behind a ``StreamByteReader``.
public struct StreamAudioFormat: Equatable {
    /// The SOURCE's rate. The output's too, unless
    /// ``FFmpegStreamDecoder/setOutputFormat(sampleRate:channelCount:)`` fixed another.
    public let sampleRate: Double
    public let channelCount: Int
    /// From the container (`AVFormatContext.duration`: MP4's sample table, MP3's Xing TOC, or
    /// `Content-Length` ÷ bitrate). `nil` when the container does not know (ADTS AAC, or an MP3
    /// with no Xing/Info header, read with no total length), in which case the caller falls back
    /// to whatever duration it has from elsewhere. Never 0.
    ///
    /// For a CBR MP3 without a Xing/Info/VBRI header it is an estimate (bitrate over the source
    /// length), too long if the file ends in non-audio bytes. Once ``FFmpegStreamDecoder/endReason``
    /// is `.eof`, `mediaFramesRead / sampleRate` is the real length (media3 re-emits its SeekMap
    /// the same way).
    public let duration: TimeInterval?
    public let codec: String
    public let container: String

    public init(sampleRate: Double, channelCount: Int, duration: TimeInterval?, codec: String, container: String) {
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
/// budget this decoder has always used (64 KiB, 1 s), which identifies a single-stream audio
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
    /// ``FFmpegStreamDecoder/seek(toSeconds:)`` needed a position the reader refused with
    /// ``StreamByteReaderError/unseekable`` (a forward-only source), so the stream is not
    /// corrupt. Terminal for this decoder (its read position is unknown); open a new one over a
    /// seekable source.
    case unseekable

    public var description: String {
        switch self {
        case .unavailable: return "no streaming decode path in this build"
        case let .invalidState(why): return "streaming decoder: \(why)"
        case let .failed(status): return "streaming decode failed, status \(status)"
        case .cancelled: return "streaming decode cancelled"
        case .interrupted: return "streaming decode interrupted for a seek"
        case .unseekable: return "streaming decode: the source cannot seek"
        }
    }
}

/// **The playback decoder: encoded bytes in, interleaved float32 out, a chunk at a time.**
///
/// It produces what a *player* schedules over a reader that may block: the source's own rate and
/// channel count, or, after ``setOutputFormat(sampleRate:channelCount:)``, one fixed format for a
/// player that runs a single graph across tracks.
///
/// Not thread-safe. One thread calls `open`, `seek`, `nextChunk` and `read`; ``cancel()`` and
/// ``interrupt()`` are the two calls allowed from another thread. `cancel` turns a stalled network
/// read into a clean end; `interrupt` brings it back so a seek can be applied and leaves the
/// decoder usable.
public final class FFmpegStreamDecoder {

    /// Why ``nextChunk()`` last returned nil. `.running` until it has.
    public enum EndReason: String {
        case running, eof, failure, cancelled
        /// ``interrupt()`` brought the read back so a seek could be applied. The only one of these
        /// a caller must NOT report as the end of the stream: the next ``seek(toSeconds:)`` puts
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
    /// What a seek reports once the reader has refused one (a forward-only source): the decoder is
    /// terminal, so it refuses without touching the demuxer (a forward seek could otherwise
    /// "succeed" over a broken one). A failed read, or a seek that failed on a read or I/O error,
    /// sets no failure here: the source may come back, and a seek is how a player resumes the same
    /// decoder once it has.
    private var failure: StreamDecoderError?
    /// Whether the most recent seek landed sample-exact. False only after a VBR MP3 seek placed by
    /// Xing TOC or bitrate estimate, whose end-of-file time can then be skewed; true before any
    /// seek and for every other format. A new decoder starts true.
    public private(set) var lastSeekWasExact = true
    private var framesRead: Int64 = 0
    private var chunk: [Float] = []
    /// What ``nextChunk()`` and ``read(into:maxFrames:)`` hand out: the source's rate and channels
    /// until ``setOutputFormat(sampleRate:channelCount:)``.
    private var outputRate: Double = 0
    private var outputChannels: Int = 0
    private let probeBudget: StreamProbeBudget
    private let forcesProbe: Bool
    /// True when ``open()`` skipped FFmpeg's stream-info probe because the header already described
    /// a FLAC, ALAC or PCM WAV/AIFF stream. A caller whose open turns out wrong can retry with
    /// `forcesProbe: true`.
    public private(set) var skippedProbe = false
    #if canImport(CStreamDecode)
        private var handle: OpaquePointer?
    #endif

    /// `forcesProbe` always runs the stream-info probe, even where the header suffices; the default
    /// skips it for FLAC, ALAC and PCM WAV/AIFF.
    public init(reader: StreamByteReader, probeBudget: StreamProbeBudget = .default, forcesProbe: Bool = false) {
        self.reader = reader
        self.box = ReaderBox(reader: reader)
        self.probeBudget = probeBudget
        self.forcesProbe = forcesProbe
    }

    deinit {
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_close(handle) }
        #endif
    }

    public var endReason: EndReason { reason }

    /// Frames of *media* handed to the caller so far, at the output rate. Media time, not wall time:
    /// position is this divided by the output rate, which is why silence a later effect drops never
    /// moves it.
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
    /// A failure here is always thrown, never swallowed — a caller can answer it with another
    /// player, and a decoder that reported success on nothing would present as a stream that
    /// plays silence and never ends.
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
                max_analyze_duration_us: Int64((probeBudget.analyzeDuration * 1_000_000).rounded()),
                force_probe: forcesProbe ? 1 : 0
            )
            guard let opened = stream_decoder_open_with(&callbacks, opaque, &options, &info, &status) else {
                // An interrupt is a seek arriving while the stream opens, not a format this build
                // cannot play: `.failed` would send the caller to its fallback player.
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
            skippedProbe = info.skipped_probe != 0
            let format = StreamAudioFormat(
                sampleRate: Double(info.sample_rate),
                channelCount: Int(info.channel_count),
                duration: info.duration_sec > 0 ? info.duration_sec : nil,
                codec: Self.string(from: &info.codec_name, capacity: 32),
                container: Self.string(from: &info.container_name, capacity: 64)
            )
            self.format = format
            outputRate = format.sampleRate
            outputChannels = format.channelCount
            chunk = [Float](repeating: 0, count: Self.framesPerChunk * max(format.channelCount, 1))
            return format
        #else
            throw StreamDecoderError.unavailable
        #endif
    }

    /// Seek to `seconds` and return where the stream actually landed.
    ///
    /// **The return value is the answer, not the argument.** It is the requested sample, reached by
    /// decoding a short pre-roll and dropping it, except in a VBR MP3 more than one seek's byte
    /// budget from a frame of known time, which lands by Xing TOC or bitrate estimate. A caller
    /// that set its position to the requested number instead would show a scrubber that disagrees
    /// with the audio, and every seek computed from that position would be against a time nobody
    /// played.
    ///
    /// A seek the reader refuses (``StreamDecoderError/unseekable``) is terminal: every later seek
    /// rethrows it without reading. Any other failure (``StreamDecoderError/failed(status:)``, such
    /// as a source still offline) ends this call only; the next seek reads again.
    @discardableResult
    public func seek(toSeconds seconds: TimeInterval) throws -> TimeInterval {
        #if canImport(CStreamDecode)
            guard let handle else { throw StreamDecoderError.invalidState("not open") }
            if reason == .failure, let failure { throw failure }
            // The seek is the answer to an interruption, so both sides of it are cleared before
            // anything reads: leaving either latched would make one interrupted read permanent.
            reader.clearInterrupt()
            stream_decoder_clear_interrupt(handle)
            var landed: Double = 0
            let status = stream_decoder_seek(handle, seconds, &landed)
            switch status {
            case Int32(STREAM_DECODE_OK.rawValue):
                reason = .running
                lastSeekWasExact = stream_decoder_last_seek_exact(handle) != 0
                framesRead = Int64((landed * outputRate).rounded())
                return landed
            case Int32(STREAM_DECODE_EOF.rawValue):
                reason = .eof
                lastSeekWasExact = stream_decoder_last_seek_exact(handle) != 0
                framesRead = Int64((landed * outputRate).rounded())
                return landed
            case Int32(STREAM_DECODE_ERR_CANCELLED.rawValue):
                reason = .cancelled
                throw StreamDecoderError.cancelled
            case Int32(STREAM_DECODE_ERR_INTERRUPTED.rawValue):
                reason = .interrupted
                throw StreamDecoderError.interrupted
            case Int32(STREAM_DECODE_ERR_UNSEEKABLE.rawValue):
                reason = .failure
                failure = .unseekable
                throw StreamDecoderError.unseekable
            default:
                // Not latched: a source still offline fails the seek, and the next seek, once it
                // is back, must read again rather than rethrow.
                reason = .failure
                throw StreamDecoderError.failed(status: status)
            }
        #else
            throw StreamDecoderError.unavailable
        #endif
    }

    /// Convert everything read from here on to `sampleRate` Hz and `channelCount` channels.
    ///
    /// For a player that runs one fixed format across tracks, so two sources of different rates
    /// can be scheduled back to back on one node (gapless playback). More channels are downmixed by
    /// swresample's default matrix (5.1 to stereo, stereo to mono); mono is duplicated to every
    /// channel at full level.
    ///
    /// Call after ``open()`` and before the first read or seek; it may be called again in that
    /// window, and throws ``StreamDecoderError/invalidState(_:)`` after it, or for a rate or
    /// channel count <= 0. The format ``open()`` returned keeps describing the source. Seeks still
    /// land on the requested sample and return media seconds; ``mediaFramesRead`` counts output
    /// frames.
    public func setOutputFormat(sampleRate: Double, channelCount: Int) throws {
        #if canImport(CStreamDecode)
            guard let handle else { throw StreamDecoderError.invalidState("not open") }
            let rate = sampleRate.rounded()
            guard rate >= 1, rate <= Double(Int32.max), channelCount > 0, channelCount <= Int(Int32.max) else {
                throw StreamDecoderError.invalidState("output format \(sampleRate) Hz, \(channelCount) channels")
            }
            let status = stream_decoder_set_output(handle, Int32(rate), Int32(channelCount))
            switch status {
            case Int32(STREAM_DECODE_OK.rawValue):
                outputRate = rate
                outputChannels = channelCount
                chunk = [Float](repeating: 0, count: Self.framesPerChunk * channelCount)
            case Int32(STREAM_DECODE_ERR_ARGS.rawValue):
                throw StreamDecoderError.invalidState("output format set after the first read or seek")
            default:
                throw StreamDecoderError.failed(status: status)
            }
        #else
            throw StreamDecoderError.unavailable
        #endif
    }

    /// Read up to `maxFrames` interleaved frames straight into `buffer`, which holds `maxFrames`
    /// times the output channel count floats. Returns the frames written; 0 means the stream ended
    /// and ``endReason`` says why, exactly as nil does for ``nextChunk()``.
    ///
    /// The same samples as ``nextChunk()``, without a per-chunk allocation: a real-time pull fills
    /// the player's own buffer. The two may be mixed on one decoder.
    ///
    /// `maxFrames` must be positive: a zero-sized request is a programming error rather than a
    /// quiet 0, so that 0 only ever means the stream ended.
    public func read(into buffer: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        precondition(maxFrames > 0, "read(into:maxFrames:) needs a positive maxFrames; 0 means the stream ended")
        #if canImport(CStreamDecode)
            guard let handle, format != nil, reason == .running else { return 0 }
            return readFrames(handle, into: buffer, maxFrames: Int32(clamping: maxFrames))
        #else
            return 0
        #endif
    }

    /// Shrink the byte budget one seek may spend before it falls back to the byte estimate.
    /// **Tests only** — see `stream_decoder_set_seek_budget_bytes`.
    public func setSeekBudgetBytesForTesting(_ bytes: Int64) {
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_set_seek_budget_bytes(handle, bytes) }
        #endif
    }

    /// Strip every packet's timestamps before the codec sees them.
    /// **Tests only** — see `stream_decoder_drop_timestamps_for_testing`.
    func dropTimestampsForTesting() {
        #if canImport(CStreamDecode)
            if let handle { stream_decoder_drop_timestamps_for_testing(handle) }
        #endif
    }

    /// The next chunk of interleaved float32 in [-1, 1], or nil once the stream has ended.
    ///
    /// nil is not by itself "the stream finished": ``endReason`` says whether it was EOF, a
    /// cancel or a failure, and the caller must distinguish them. A transport failure reported as
    /// the end would mark the item played and move the listener on.
    public func nextChunk() -> [Float]? {
        #if canImport(CStreamDecode)
            guard let handle, format != nil, reason == .running else { return nil }
            let frames = chunk.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return readFrames(handle, into: base, maxFrames: Int32(Self.framesPerChunk))
            }
            guard frames > 0 else { return nil }
            let count = frames * outputChannels
            return count == chunk.count ? chunk : Array(chunk[0..<count])
        #else
            return nil
        #endif
    }

    #if canImport(CStreamDecode)
        /// The one `stream_decoder_read` call: frames written, or 0 with ``endReason`` set.
        private func readFrames(_ handle: OpaquePointer, into buffer: UnsafeMutablePointer<Float>, maxFrames: Int32) -> Int {
            var frames: Int32 = 0
            let status = stream_decoder_read(handle, buffer, maxFrames, &frames)
            guard status == Int32(STREAM_DECODE_OK.rawValue), frames > 0 else {
                switch status {
                case Int32(STREAM_DECODE_EOF.rawValue): reason = .eof
                case Int32(STREAM_DECODE_ERR_CANCELLED.rawValue): reason = .cancelled
                case Int32(STREAM_DECODE_ERR_INTERRUPTED.rawValue): reason = .interrupted
                default: reason = .failure
                }
                return 0
            }
            framesRead += Int64(frames)
            return Int(frames)
        }
    #endif

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
    /// decode; this ends only the call. Safe from any thread.
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
        } catch StreamByteReaderError.unseekable {
            return Int32(STREAM_READ_UNSEEKABLE)
        } catch {
            return Int32(STREAM_READ_ERROR)
        }
    }

    func size() -> Int64 {
        reader.totalLength ?? -1
    }
}
