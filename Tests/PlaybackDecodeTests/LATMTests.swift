import Foundation
import XCTest

@testable import PlaybackDecode

/// Raw LATM in LOAS framing opens through the `loas` demuxer. The fixture lives with the
/// conformance corpus (made by its `make-fixtures.sh`), so it is read by path.
final class LATMTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/latm_loas.aac")
    }

    func testRawLATMOpensAndDecodes() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fixtureURL))
        let format = try decoder.open()
        XCTAssertEqual(format.sampleRate, 44100)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.codec, "aac_latm")
        XCTAssertEqual(format.container, "loas")

        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm.append(contentsOf: chunk) }
        XCTAssertEqual(decoder.endReason, .eof)

        // 4 s of stereo; the encoder's priming and padding move the count by a frame or two.
        let frames = pcm.count / 2
        XCTAssertEqual(Double(frames), 4 * 44100, accuracy: 4096)

        // A sane tone: audible, finite, and near the 0.7 source level.
        let peak = pcm.reduce(0) { max($0, abs($1)) }
        XCTAssertFalse(pcm.contains { !$0.isFinite })
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertLessThan(peak, 1.2)  // lossy overshoot of a 0.7 tone
    }
}
