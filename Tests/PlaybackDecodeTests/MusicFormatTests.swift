import Foundation
import XCTest

@testable import PlaybackDecode

/// The music superset build opens FLAC, ALAC, PCM WAV/AIFF and Opus/Vorbis in Matroska/WebM. The
/// fixtures live with the conformance corpus (made by its `make-fixtures.sh`), so they are read by
/// path.
final class MusicFormatTests: XCTestCase {

    private struct Case {
        var file: String
        var codec: String
        var rate: Int
        var seconds: Double
        /// Frames the codec may add or drop at the ends (priming, padding).
        var slack: Double
    }

    private let cases = [
        Case(file: "flac_stereo.flac", codec: "flac", rate: 44100, seconds: 4, slack: 0),
        Case(file: "alac_stereo.m4a", codec: "alac", rate: 44100, seconds: 4, slack: 0),
        Case(file: "wav_s16.wav", codec: "pcm_s16le", rate: 44100, seconds: 2, slack: 0),
        Case(file: "wav_s24.wav", codec: "pcm_s24le", rate: 44100, seconds: 2, slack: 0),
        Case(file: "aiff_s16.aiff", codec: "pcm_s16be", rate: 44100, seconds: 2, slack: 0),
        Case(file: "opus_stereo.mka", codec: "opus", rate: 48000, seconds: 4, slack: 4096),
        Case(file: "vorbis_stereo.webm", codec: "vorbis", rate: 44100, seconds: 4, slack: 4096),
    ]

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/\(name)")
    }

    func testEachMusicFormatOpensWithItsCodecAndDecodesToItsLength() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        for c in cases {
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url(c.file)))
            let format = try decoder.open()
            XCTAssertEqual(format.codec, c.codec, c.file)
            XCTAssertEqual(Int(format.sampleRate), c.rate, c.file)
            XCTAssertEqual(Int(format.channelCount), 2, c.file)

            var samples = 0
            var peak: Float = 0
            while let chunk = decoder.nextChunk() {
                samples += chunk.count
                peak = chunk.reduce(peak) { max($0, abs($1)) }
            }
            XCTAssertEqual(decoder.endReason, .eof, c.file)
            XCTAssertEqual(Double(samples / 2), c.seconds * Double(c.rate), accuracy: c.slack, c.file)
            XCTAssertGreaterThan(peak, 0.3, c.file)
            XCTAssertLessThan(peak, 1.2, c.file)
        }
    }
}
