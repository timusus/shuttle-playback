import Foundation
import XCTest

@testable import PlaybackDecode

/// An MP3 that starts with far more than the 64 KiB probe budget of something that is not audio: a
/// ~13 MB ID3v2 tag (embedded artwork) and a 100 kB run of garbage. Built in memory in front of a
/// committed fixture and written to a temporary file, so the 13 MB never lands in the repo.
/// The PCM and the seeks must equal the bare fixture's, and the bytes read before the first audio
/// must stay near the prefix, not a multiple of it.
final class LeadingBytesTests: XCTestCase {
    private final class CountingReader: StreamByteReader {
        private let inner: FileByteReader
        private(set) var bytesRead: Int64 = 0
        init(_ url: URL) throws { inner = try FileByteReader(url: url) }
        var totalLength: Int64? { inner.totalLength }
        var position: Int64 { inner.position }
        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            let n = try inner.read(into: buffer, maxLength: maxLength)
            bytesRead += Int64(n)
            return n
        }
        func seek(to offset: Int64) throws { try inner.seek(to: offset) }
        func cancel() { inner.cancel() }
        func interrupt() { inner.interrupt() }
        func clearInterrupt() { inner.clearInterrupt() }
    }

    private struct Run {
        var format: StreamAudioFormat
        var pcm: [Float]
        var bytesBeforeFirstAudio: Int64
        var seeks: [(landed: TimeInterval, pcm: [Float])]
    }

    private func run(_ url: URL, budget: StreamProbeBudget = .default) throws -> Run {
        let reader = try CountingReader(url)
        let decoder = FFmpegStreamDecoder(reader: reader, probeBudget: budget)
        let format = try decoder.open()
        var pcm: [Float] = []
        var first: Int64?
        while let chunk = decoder.nextChunk() {
            if first == nil { first = reader.bytesRead }
            pcm += chunk
        }
        var seeks: [(TimeInterval, [Float])] = []
        for fraction in [1.0 / 3, 2.0 / 3] {
            let landed = try decoder.seek(toSeconds: try XCTUnwrap(format.duration) * fraction)
            var window: [Float] = []
            while window.count < 4096 * format.channelCount, let chunk = decoder.nextChunk() { window += chunk }
            seeks.append((landed, Array(window.prefix(4096 * format.channelCount))))
        }
        return Run(format: format, pcm: pcm, bytesBeforeFirstAudio: first ?? -1, seeks: seeks)
    }

    private func id3v2Tag(payload: Int) -> Data {
        // One PRIV-style padding frame is enough: a tag is a 10-byte header and `payload` bytes, the
        // size in four 7-bit bytes. Zero padding is legal tag content.
        var header = Data("ID3".utf8) + Data([3, 0, 0])
        for shift in [21, 14, 7, 0] { header.append(UInt8((payload >> shift) & 0x7f)) }
        return header + Data(count: payload)
    }

    private func check(prefix: Data, label: String, maxBytesBeforeAudio: Int64, budget: StreamProbeBudget = .default) throws {
        let source = GoldenStore.fixtureURLs().first { $0.lastPathComponent == "cbr_padding_bit.mp3" }!
        let body = try Data(contentsOf: source)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("leading-\(UUID().uuidString).mp3")
        try (prefix + body).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bare = try run(source)
        let got = try run(tmp, budget: budget)
        XCTAssertEqual(got.format.sampleRate, bare.format.sampleRate, label)
        XCTAssertEqual(got.format.channelCount, bare.format.channelCount, label)
        XCTAssertEqual(try XCTUnwrap(got.format.duration), try XCTUnwrap(bare.format.duration), accuracy: 0.05, "\(label): duration")
        XCTAssertEqual(got.pcm, bare.pcm, "\(label): PCM differs from the bare file's")
        XCTAssertLessThanOrEqual(got.bytesBeforeFirstAudio, maxBytesBeforeAudio,
                                 "\(label): \(got.bytesBeforeFirstAudio) bytes read before the first audio")
        for (g, b) in zip(got.seeks, bare.seeks) {
            XCTAssertEqual(g.landed, b.landed, accuracy: 0.03, "\(label): seek landing")
            XCTAssertEqual(g.pcm, b.pcm, "\(label): PCM after a seek differs from the bare file's")
            XCTAssertFalse(g.pcm.isEmpty, label)
        }
    }

    func testA13MBID3v2TagBeforeAudio() throws {
        // The tag can be skipped by a seek: only a little of it should be read.
        try check(prefix: id3v2Tag(payload: 13_000_000), label: "13 MB ID3v2", maxBytesBeforeAudio: 256 * 1024)
    }


    private func garbage(_ count: Int) -> Data {
        var state: UInt64 = 404
        return Data((0..<count).map { _ -> UInt8 in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(0x20 + (state >> 33) % 0x5f)  // printable, never the 0xFF sync byte
        })
    }

    /// With a probe budget that covers the prefix, the garbage is scanned past once.
    func testA100kBGarbagePrefixWithALargerProbeBudget() throws {
        try check(prefix: garbage(100_000), label: "100 kB garbage, 256 KiB probe",
                  maxBytesBeforeAudio: 100_000 + 128 * 1024,
                  budget: StreamProbeBudget(bytes: 256 * 1024, analyzeDuration: 1))
    }

    /// Under the default 64 KiB budget a 100 kB prefix is scanned past for the first run of chained
    /// frames.
    func testA100kBGarbagePrefixUnderTheDefaultProbeBudget() throws {
        try check(prefix: garbage(100_000), label: "100 kB garbage, default probe",
                  maxBytesBeforeAudio: 100_000 + 128 * 1024)
    }

    func testA500kBGarbagePrefixUnderTheDefaultProbeBudget() throws {
        try check(prefix: garbage(500_000), label: "500 kB garbage, default probe",
                  maxBytesBeforeAudio: 500_000 + 128 * 1024)
    }

    /// Sync words in the garbage that are not followed by more frames are not the start of the audio.
    func testFalseSyncWordsInGarbageAreNotTakenAsTheStart() throws {
        var junk = garbage(150_000)
        // A valid MPEG1 layer 3 128 kbps 44.1 kHz header (FF FB 90 00) whose next frame is junk, and
        // a bare 0xFFE... that is no header at all.
        for at in [20_000, 70_000, 120_000] { junk.replaceSubrange(at..<at + 4, with: [0xFF, 0xFB, 0x90, 0x00]) }
        for at in [30_000, 90_000] { junk.replaceSubrange(at..<at + 2, with: [0xFF, 0xE3]) }
        try check(prefix: junk, label: "150 kB garbage with false sync words, default probe",
                  maxBytesBeforeAudio: 150_000 + 128 * 1024)
    }

    /// A reader over a file that ends every read at the next boundary, so the scan buffer fills in
    /// the shape a test wants, and counts what was read.
    private final class ShapedReader: StreamByteReader {
        private let inner: FileByteReader
        private let boundaries: [Int64]
        private(set) var bytesRead: Int64 = 0
        init(_ url: URL, boundaries: [Int64] = []) throws {
            inner = try FileByteReader(url: url)
            self.boundaries = boundaries
        }
        var totalLength: Int64? { inner.totalLength }
        var position: Int64 { inner.position }
        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            var limit = maxLength
            if let next = boundaries.first(where: { $0 > inner.position }) { limit = min(limit, Int(next - inner.position)) }
            let n = try inner.read(into: buffer, maxLength: limit)
            bytesRead += Int64(n)
            return n
        }
        func seek(to offset: Int64) throws { try inner.seek(to: offset) }
        func cancel() { inner.cancel() }
        func interrupt() { inner.interrupt() }
        func clearInterrupt() { inner.clearInterrupt() }
    }

    private func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leading-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// MPEG 2.5 layer II at index 14 and 8 kHz is a 2880-byte frame, the longest the header parser
    /// accepts. Two of them chained, with a read that ends just short of the third header, leave the
    /// scan buffer holding more than one 1792-byte frame's worth of look-ahead; the next full read
    /// must not write past the end of it. Meaningful under `-Xswiftc -sanitize=address`.
    func testChainedMaximumLengthMPEG25FramesDoNotOverrunTheScanBuffer() throws {
        let header: [UInt8] = [0xFF, 0xE5, 0xE8, 0xC0]
        let frame = 2880
        for start in [400_000, 400_001, 400_002, 400_003] {
            var data = garbage(start)
            for _ in 0..<2 { data += header + Data(count: frame - header.count) }
            data += garbage(40_000)
            let url = try write(data, ext: "mp3")
            // Reads end where the first header starts and 5763 bytes later: the longest carry a
            // chain of three can need.
            let reader = try ShapedReader(url, boundaries: [Int64(start), Int64(start + 2 * 2880 + 3)])
            let decoder = FFmpegStreamDecoder(reader: reader)
            _ = try? decoder.open()
        }
    }

    /// A body that is plainly not MP3 is not scanned for MP3 frames after the probe gives up, and a
    /// scan that would start past its cap is not begun: the failed open reads the body once (a rescan would read 64 KiB or more of it again).
    func testNonMP3BodiesAreNotRescanned() throws {
        let html = Data("<html><body>".utf8) + garbage(900_000)
        var mp4 = Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data([0, 0, 2, 0]) + Data("isomiso2".utf8)
        mp4 += garbage(900_000)
        for (label, data, ext) in [("html", html, "html"), ("mp4", mp4, "mp4")] {
            let url = try write(data, ext: ext)
            let reader = try ShapedReader(url)
            XCTAssertThrowsError(try FFmpegStreamDecoder(reader: reader).open(), label)
            XCTAssertLessThanOrEqual(reader.bytesRead, Int64(data.count) + 4096, "\(label): \(reader.bytesRead) bytes read")
        }
    }
}
