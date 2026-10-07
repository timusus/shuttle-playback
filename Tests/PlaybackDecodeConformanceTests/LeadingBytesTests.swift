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
            let landed = try decoder.seek(toSeconds: format.duration * fraction)
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
        XCTAssertEqual(got.format.duration, bare.format.duration, accuracy: 0.05, "\(label): duration")
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

    /// Under the default 64 KiB budget a 100 kB prefix is not recovered from (80 kB is: see
    /// garbage_prefix_80k.mp3). Pinned: this is the behaviour wanted, and it fails today.
    func testA100kBGarbagePrefixUnderTheDefaultProbeBudget() throws {
        XCTExpectFailure("a garbage prefix beyond the default probe budget fails to open")
        try check(prefix: garbage(100_000), label: "100 kB garbage, default probe",
                  maxBytesBeforeAudio: 100_000 + 128 * 1024)
    }
}
