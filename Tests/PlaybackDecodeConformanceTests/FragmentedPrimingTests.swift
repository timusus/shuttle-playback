import Foundation
import XCTest

@testable import PlaybackDecode

/// A fragmented MP4 has no edit list, so nothing in the file says to skip the AAC encoder's priming
/// (issue #25). `aac_fragmented_sidx.m4a` and `aac_edit_list.m4a` are the same source through the
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
