import Foundation
import XCTest

@testable import PlaybackDecode

/// A fragmented MP4 has no edit list, so nothing in the file says to skip the AAC encoder's priming.
/// `aac_fragmented_sidx.m4a` and `aac_edit_list.m4a` are the same source through the
/// same encoder, the second with an edit list, so the first must decode to the same content: the
/// content length, starting at the first real sample rather than 1024 samples of priming.
final class FragmentedPrimingTests: XCTestCase {
    private func decode(_ name: String) throws -> (StreamAudioFormat, [Float]) {
        let url = try XCTUnwrap(GoldenStore.fixtureURLs().first { $0.lastPathComponent == name })
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try decoder.open()
        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm += chunk }
        return (format, pcm)
    }

    func testFragmentedMP4DropsThePrimingAndKeepsTheContent() throws {
        let (format, fragmented) = try decode("aac_fragmented_sidx.m4a")
        let (_, reference) = try decode("aac_edit_list.m4a")
        let channels = format.channelCount
        XCTAssertEqual(fragmented.count / channels, 176_400)
        XCTAssertEqual(try XCTUnwrap(format.duration), 4.0, accuracy: 0.001)
        XCTAssertEqual(fragmented.count, reference.count)

        // Two encodes of one source differ by quantisation noise, not by a 1024-sample shift.
        let n = 8192 * channels
        var diff = 0.0, energy = 0.0
        for i in 0..<n {
            let d = Double(fragmented[i] - reference[i])
            diff += d * d
            energy += Double(reference[i]) * Double(reference[i])
        }
        XCTAssertGreaterThan(energy, 0)
        XCTAssertLessThan(diff / energy, 0.01, "the start is not the content's first sample")
    }

    func testFileWithAnEditListIsLeftAsItWas() throws {
        let (format, pcm) = try decode("aac_edit_list.m4a")
        XCTAssertEqual(pcm.count / format.channelCount, 176_400)
    }
}

/// An edit list with media_time 0 is the encoder saying "no priming": nothing is to be dropped, and
/// FFmpeg cannot tell it from no edit list at all, so the box tree is read.
final class ExplicitNoPrimingTests: XCTestCase {
    private func frames(of url: URL) throws -> Int {
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try decoder.open()
        var count = 0
        while let chunk = decoder.nextChunk() { count += chunk.count / format.channelCount }
        return count
    }

    func testEditListWithMediaTimeZeroKeepsEverySample() throws {
        let source = try XCTUnwrap(GoldenStore.fixtureURLs().first { $0.lastPathComponent == "aac_edit_list.m4a" })
        var bytes = try Data(contentsOf: source)
        let original = try frames(of: source)

        // elst: size, 'elst', version/flags, entry count, then per entry segment_duration,
        // media_time (4 bytes each in version 0, 8 in version 1), rate.
        let tag = Data("elst".utf8)
        let at = try XCTUnwrap(bytes.range(of: tag)).upperBound
        let version = bytes[at]
        let mediaTime = at + 4 + 4 + (version == 1 ? 8 : 4)
        let width = version == 1 ? 8 : 4
        XCTAssertGreaterThan(bytes[mediaTime..<mediaTime + width].reduce(0, { $0 | Int($1) }), 0)
        for i in mediaTime..<mediaTime + width { bytes[i] = 0 }

        let patched = FileManager.default.temporaryDirectory
            .appendingPathComponent("elst0-\(UUID().uuidString).m4a")
        try bytes.write(to: patched)
        defer { try? FileManager.default.removeItem(at: patched) }

        // The edit list is still read for its duration, but no priming is dropped by us either:
        // the frame count matches the original, not 1024 fewer.
        let kept = try frames(of: patched)
        XCTAssertEqual(kept, original)
    }

    func testProgressiveMP4WithoutAnEditListIsUnchanged() throws {
        let source = try XCTUnwrap(GoldenStore.fixtureURLs().first { $0.lastPathComponent == "tone_moov_first.m4a" })
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: source))
        let format = try decoder.open()
        var count = 0
        while let chunk = decoder.nextChunk() { count += chunk.count / format.channelCount }
        let duration = try XCTUnwrap(format.duration)
        // Whatever the container says, a progressive file gets no extra trim: the frames match
        // the reported duration to within a codec frame.
        XCTAssertEqual(Double(count) / format.sampleRate, duration, accuracy: 1024.0 / format.sampleRate + 0.001)
    }
}
