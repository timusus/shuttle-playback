import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode

/// `StreamAudioFormat.duration` is nil, never 0, when the container cannot say how long the audio
/// is: ADTS AAC and an MP3 without a Xing/Info header, read with no total length.
final class UnknownDurationTests: XCTestCase {
    private static let conformanceFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures")

    private func fixture(_ name: String) throws -> URL {
        let url = Self.conformanceFixtures.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) missing")
        return url
    }

    private func open(_ url: URL, knownLength: Bool) throws -> StreamAudioFormat {
        try FFmpegStreamDecoder(reader: try FileByteReader(url: url, reportsTotalLength: knownLength)).open()
    }

    func testUnknownLengthADTSAndXinglessMP3HaveNoDuration() throws {
        for name in ["adts_id3.aac", "cbr_no_table.mp3"] {
            let format = try open(try fixture(name), knownLength: false)
            XCTAssertNil(format.duration, "\(name) with no total length")
        }
    }

    func testKnownLengthGivesDurationCloseToAVAsset() async throws {
        for name in ["adts_id3.aac", "cbr_no_table.mp3"] {
            let url = try fixture(name)
            let format = try open(url, knownLength: true)
            let duration = try XCTUnwrap(format.duration, name)
            XCTAssertGreaterThan(duration, 0, name)
            let expected = try await AVURLAsset(url: url).load(.duration).seconds
            XCTAssertEqual(duration, expected, accuracy: 0.5, name)
        }
    }

    func testContainersThatKnowReportItWithUnknownLength() throws {
        for name in [Fixture.moovFirst, Fixture.moovLast, Fixture.mp3] {
            let format = try open(try Fixture.url(name), knownLength: false)
            XCTAssertEqual(try XCTUnwrap(format.duration, name), 20, accuracy: 0.2, name)
        }
        let format = try open(try fixture("vbr_xing.mp3"), knownLength: false)
        XCTAssertGreaterThan(try XCTUnwrap(format.duration), 0)
    }
}
