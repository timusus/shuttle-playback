import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode

// MARK: - Fixtures

enum Fixture {
    static let mp3 = "tone.mp3"
    static let moovFirst = "tone_moov_first.m4a"
    static let moovLast = "tone_moov_last.m4a"
    static let all = [mp3, moovFirst, moovLast]

    /// The fixtures are committed, so a missing one is a broken checkout, not a reason to skip.
    static func url(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name) missing; see Tests/PlaybackDecodeTests/Fixtures/README.md")
        }
        return url
    }
}

// MARK: - Readers used only by the tests

/// Wraps a reader and records every byte and every seek, so the `moov`-after-`mdat` test can assert
/// on bandwidth rather than on a decode that merely succeeded (plan §3).
final class CountingByteReader: StreamByteReader {
    private let inner: StreamByteReader
    private(set) var bytesRead: Int64 = 0
    private(set) var seekOffsets: [Int64] = []
    private let lock = NSLock()

    init(_ inner: StreamByteReader) { self.inner = inner }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let n = try inner.read(into: buffer, maxLength: maxLength)
        lock.lock(); bytesRead += Int64(n); lock.unlock()
        return n
    }

    func seek(to offset: Int64) throws {
        lock.lock(); seekOffsets.append(offset); lock.unlock()
        try inner.seek(to: offset)
    }

    func cancel() { inner.cancel() }

    func interrupt() { inner.interrupt() }

    func clearInterrupt() { inner.clearInterrupt() }
}

/// A reader whose `read` never returns until `cancel()` — a network transaction that has stalled.
/// The decoder must come back through it, not sit in it forever.
final class BlockingByteReader: StreamByteReader {
    private let gate = DispatchSemaphore(value: 0)
    private let cancelled = NSLock()
    private var isCancelled = false

    var totalLength: Int64? { nil }
    var position: Int64 { 0 }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        gate.wait()
        throw StreamByteReaderError.cancelled
    }

    func seek(to offset: Int64) throws {
        gate.wait()
        throw StreamByteReaderError.cancelled
    }

    func cancel() {
        cancelled.lock()
        defer { cancelled.unlock() }
        guard !isCancelled else { return }
        isCancelled = true
        /* Enough signals that any callback already waiting, and the next few, come straight back. */
        for _ in 0..<8 { gate.signal() }
    }

    func interrupt() {}

    func clearInterrupt() {}
}

/// A file reader that stops delivering after `stallAfterBytes` and blocks there until it is
/// interrupted or cancelled — a bounded response body whose host went quiet mid-episode.
///
/// The interrupt case is what this exists for: the decode has to come back out of that block, and
/// the SAME decoder has to keep working afterwards, which a cancel could never demonstrate.
final class StallingFileByteReader: StreamByteReader {
    private let inner: FileByteReader
    private let stallAfterBytes: Int64
    private let gate = NSCondition()
    private var delivered: Int64 = 0
    private var interrupted = false
    private var cancelled = false
    private var stalledValue = false

    init(url: URL, stallAfterBytes: Int64) throws {
        self.inner = try FileByteReader(url: url)
        self.stallAfterBytes = stallAfterBytes
    }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    /// Whether a read is parked in the stall right now, so a test can interrupt at the moment that
    /// actually reproduces the race rather than after a fixed sleep.
    var isStalled: Bool {
        gate.lock(); defer { gate.unlock() }
        return stalledValue
    }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        gate.lock()
        while delivered >= stallAfterBytes, !interrupted, !cancelled {
            stalledValue = true
            gate.broadcast()
            gate.wait()
        }
        stalledValue = false
        let stopped = cancelled
        let broughtBack = interrupted
        gate.unlock()
        if stopped { throw StreamByteReaderError.cancelled }
        if broughtBack { throw StreamByteReaderError.interrupted }

        let n = try inner.read(into: buffer, maxLength: maxLength)
        gate.lock(); delivered += Int64(n); gate.unlock()
        return n
    }

    func seek(to offset: Int64) throws {
        gate.lock()
        let stopped = cancelled
        let broughtBack = interrupted
        gate.unlock()
        if stopped { throw StreamByteReaderError.cancelled }
        if broughtBack { throw StreamByteReaderError.interrupted }
        try inner.seek(to: offset)
    }

    func cancel() {
        gate.lock()
        cancelled = true
        gate.broadcast()
        gate.unlock()
        inner.cancel()
    }

    func interrupt() {
        gate.lock()
        interrupted = true
        gate.broadcast()
        gate.unlock()
    }

    /// Clearing the interruption also lifts the stall: the seek that follows one is served by a new
    /// transaction, and a host that answers it is the case being modelled.
    func clearInterrupt() {
        gate.lock()
        interrupted = false
        delivered = 0
        gate.broadcast()
        gate.unlock()
        inner.clearInterrupt()
    }
}

/// A file reader that answers in pieces of at most `chunkBytes`, the way an HTTP transaction hands
/// over what its window holds rather than whatever was asked for. Short reads change which of
/// libavformat's paths refill and which return the error the AVIO context is holding, so a bug
/// that only shows over the network needs them to be reproducible here.
final class ChunkedFileByteReader: StreamByteReader {
    private let inner: FileByteReader
    private let chunkBytes: Int

    init(url: URL, chunkBytes: Int) throws {
        self.inner = try FileByteReader(url: url)
        self.chunkBytes = chunkBytes
    }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        try inner.read(into: buffer, maxLength: min(maxLength, chunkBytes))
    }

    func seek(to offset: Int64) throws { try inner.seek(to: offset) }

    func cancel() { inner.cancel() }

    func interrupt() { inner.interrupt() }

    func clearInterrupt() { inner.clearInterrupt() }
}

/// A chunked response (no length) whose connection breaks at `cutoff`: every read from there on
/// fails with a transport error, which is not the end of the stream.
final class TruncatedFileByteReader: StreamByteReader {
    private let inner: FileByteReader
    private let cutoff: Int64

    init(url: URL, cutoff: Int64) throws {
        self.inner = try FileByteReader(url: url, reportsTotalLength: false)
        self.cutoff = cutoff
    }

    var totalLength: Int64? { nil }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let left = cutoff - inner.position
        guard left > 0 else { throw URLError(.networkConnectionLost) }
        return try inner.read(into: buffer, maxLength: min(maxLength, Int(left)))
    }

    func seek(to offset: Int64) throws { try inner.seek(to: offset) }

    func cancel() { inner.cancel() }

    func interrupt() { inner.interrupt() }

    func clearInterrupt() { inner.clearInterrupt() }
}

/// A reader over an in-memory blob, for the garbage-input case.
final class DataByteReader: StreamByteReader {
    private let data: Data
    private var offset: Int64 = 0

    init(_ data: Data) { self.data = data }

    var totalLength: Int64? { Int64(data.count) }
    var position: Int64 { offset }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let remaining = Int64(data.count) - offset
        if remaining <= 0 { return 0 }
        let take = min(Int(remaining), maxLength)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base.advanced(by: Int(offset)), take)
        }
        offset += Int64(take)
        return take
    }

    func seek(to newOffset: Int64) throws {
        guard newOffset >= 0, newOffset <= Int64(data.count) else { throw StreamByteReaderError.unseekable }
        offset = newOffset
    }

    func cancel() {}

    func interrupt() {}

    func clearInterrupt() {}
}

// MARK: - The reference decode

enum ReferenceDecoder {

    /// Decode `url` with `AVAssetReader` to interleaved float32 at the source's rate — the same
    /// shape ``FFmpegStreamDecoder`` produces, so the two can be compared sample for sample.
    ///
    /// This is the honest reference: it is the decoder the app used before this work
    /// (`AudioAssetPCMReader`), so "the streaming path sounds like what shipped" is a measurement
    /// rather than an assertion.
    static func decode(url: URL, from start: TimeInterval? = nil, seconds: TimeInterval? = nil) throws -> (pcm: [Float], sampleRate: Double, channels: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = assetAudioTrack(asset) else {
            throw StreamDecoderError.invalidState("no audio track in \(url.lastPathComponent)")
        }
        let description = trackFormat(track)
        let sampleRate = description?.mSampleRate ?? 44100
        let channels = Int(description?.mChannelsPerFrame ?? 2)

        let reader = try AVAssetReader(asset: asset)
        if let start {
            let begin = CMTime(seconds: start, preferredTimescale: 44100)
            let duration = seconds.map { CMTime(seconds: $0, preferredTimescale: 44100) } ?? CMTime.positiveInfinity
            reader.timeRange = CMTimeRange(start: begin, duration: duration)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var pcm: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) { floats in
                pcm.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / MemoryLayout<Float>.size))
            }
        }
        return (pcm, sampleRate, channels)
    }

    private static func assetAudioTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
        /* The async `loadTracks` variant needs an await; these are local files and the test lane is
         * synchronous, so the deprecated accessor is the honest one here. */
        asset.tracks(withMediaType: .audio).first
    }

    private static func trackFormat(_ track: AVAssetTrack) -> AudioStreamBasicDescription? {
        for case let description as CMAudioFormatDescription in track.formatDescriptions {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                return asbd.pointee
            }
        }
        return nil
    }
}

// MARK: - Comparison

enum PCMComparison {

    /// Take one channel out of interleaved PCM.
    static func channel(_ pcm: [Float], index: Int, of channels: Int) -> [Float] {
        guard channels > 1 else { return pcm }
        return stride(from: index, to: pcm.count, by: channels).map { pcm[$0] }
    }

    /// Best alignment of `b` against `a` within ±`maxLag` frames, by MINIMUM RMS difference over a
    /// short window.
    ///
    /// Not cross-correlation, which was tried first and does not work on this signal: the fixture
    /// is a 440 Hz tone under a 0.05 Hz envelope, so shifting by a whole period (100.2 samples)
    /// leaves the correlation within 0.3% of its true peak and the search happily returned a lag
    /// 38 periods out. RMS difference does not have that blind spot — a period's shift leaves a
    /// 0.23-sample phase error, which is 8° of the carrier and shows up as a large residual.
    static func bestLag(_ a: [Float], _ b: [Float], sampleRate: Double, maxLag: Int = 4096) -> Int {
        let window = Int(sampleRate / 10)        // 100 ms: enough to be decisive, 8193 lags cheap
        let start = Int(sampleRate * 2)          // two seconds in: past every decoder's priming
        guard a.count >= start + window + maxLag, b.count >= start + window + maxLag else { return 0 }

        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var best = 0
                var bestScore = Double.infinity
                for lag in -maxLag...maxLag {
                    var sum = 0.0
                    for i in 0..<window {
                        let d = Double(pa[start + i]) - Double(pb[start + i + lag])
                        sum += d * d
                    }
                    if sum < bestScore { bestScore = sum; best = lag }
                }
                return best
            }
        }
    }

    /// Locate `a` inside `reference` near `nearIndex` and report the residual.
    ///
    /// The seek tests need this rather than ``bestLag``: what is being checked is that the PCM
    /// after a seek is the audio at the time the decoder SAID it landed on, so the search has to be
    /// anchored to that time rather than to the start of the clip.
    static func rms(_ a: [Float], inside reference: [Float], nearIndex: Int, maxLag: Int = 4096,
                    sampleRate: Double) -> (lag: Int, rms: Double) {
        let window = min(a.count, Int(sampleRate / 10))
        guard window > 0 else { return (0, .infinity) }
        var best = 0
        var bestScore = Double.infinity
        a.withUnsafeBufferPointer { pa in
            reference.withUnsafeBufferPointer { pb in
                for lag in -maxLag...maxLag {
                    let origin = nearIndex + lag
                    guard origin >= 0, origin + window <= pb.count else { continue }
                    var sum = 0.0
                    for i in 0..<window {
                        let d = Double(pa[i]) - Double(pb[origin + i])
                        sum += d * d
                    }
                    if sum < bestScore { bestScore = sum; best = lag }
                }
            }
        }
        let origin = nearIndex + best
        let count = min(a.count, reference.count - origin)
        guard origin >= 0, count > 0 else { return (best, .infinity) }
        var sum = 0.0
        for i in 0..<count {
            let d = Double(a[i]) - Double(reference[origin + i])
            sum += d * d
        }
        return (best, (sum / Double(count)).squareRoot())
    }

    /// RMS of `a - b` once `b` is shifted by `lag`, over the region both cover.
    static func rmsDifference(_ a: [Float], _ b: [Float], lag: Int) -> Double {
        let aStart = max(0, -lag)
        let bStart = max(0, lag)
        let count = min(a.count - aStart, b.count - bStart)
        guard count > 0 else { return .infinity }
        var sum = 0.0
        for i in 0..<count {
            let d = Double(a[aStart + i]) - Double(b[bStart + i])
            sum += d * d
        }
        return (sum / Double(count)).squareRoot()
    }
}

// MARK: - Fixtures built at test time

/// The big fixtures, generated rather than committed: a 14 MB MP3 and a 4 MB ID3 tag are not
/// things to put in git, and what they measure — bandwidth on a REAL enclosure's shape — needs
/// their real size to mean anything.
enum GeneratedFixture {

    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    private static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shuttle-stream-fixtures")
    }

    /// 30 minutes of 64 kbps CBR MP3 with **no Xing/Info header** — the shape of most podcast
    /// enclosures, and the one with no table of contents to seek by. About 14 MB.
    ///
    /// Cached between runs: `ffmpeg` takes five seconds and the bytes are deterministic.
    static func largeCBRMP3() throws -> URL {
        try generate("cbr-no-xing-1800s.mp3", encoding: ["-b:a", "64k", "-write_xing", "0"])
    }

    /// 5 minutes of VBR MP3 with a Xing header and TOC, about 1.6 MB: a frame's time is known only
    /// by counting from the first one, and the TOC places a time to 1/256 of the file (3 s per
    /// percent entry here). Every other second has noise over the tone, so frame sizes really vary
    /// (a plain tone encodes as near-constant frames and an estimate lands on the right one by luck).
    static func xingVBRMP3() throws -> URL {
        try generate("vbr-xing-varied-300s.mp3", encoding: ["-q:a", "6"],
                     source: "aevalsrc=0.3*sin(440*2*PI*t)+0.2*mod(floor(t)\\,2)*(2*random(0)-1):d=300:s=44100")
    }

    private static func generate(_ name: String, encoding: [String],
                                 source: String = "sine=frequency=440:duration=1800") throws -> URL {
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw XCTSkip("no ffmpeg at \(ffmpeg); this test generates its own fixture")
        }
        #if os(macOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", source,
            "-c:a", "libmp3lame",
        ] + encoding + [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ffmpeg could not build the fixture (status \(process.terminationStatus))")
        }
        return url
        #else
        throw XCTSkip("the fixture is generated with a host ffmpeg, which an iOS device or simulator lacks")
        #endif
    }

    /// `tone.mp3` behind a padding-only ID3v2 tag of `tagBytes`, standing in for the cover art a
    /// real enclosure carries. The measured case is `darknet-diaries-ep179`: a 13 782 278-byte tag
    /// holding a 3000x3000 PNG, which `mp3_read_header` reads in full.
    static func mp3BehindID3Tag(bytes tagBytes: Int) throws -> URL {
        let source = try Data(contentsOf: try Fixture.url(Fixture.mp3))
        let url = directory.appendingPathComponent("tone-behind-id3-\(tagBytes).mp3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        /* An ID3v2.3 header: "ID3", version, flags, then the tag length as four SYNCSAFE bytes
         * (seven bits each, high bit clear). A body of zeroes is legal padding, so no frame has to
         * be synthesised for the demuxer to have to step over it. */
        let payload = tagBytes - 10
        precondition(payload > 0 && payload < 1 << 28)
        var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        for shift in [21, 14, 7, 0] { tag.append(UInt8((payload >> shift) & 0x7F)) }
        tag.append(Data(count: payload))
        try (tag + source).write(to: url)
        return url
    }
}
