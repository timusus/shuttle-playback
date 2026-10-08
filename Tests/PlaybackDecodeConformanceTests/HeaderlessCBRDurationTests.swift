import Foundation
import XCTest

@testable import PlaybackDecode

/// Issue #53: a CBR MP3 with no Xing/Info/VBRI header reports a bitrate estimate over the source
/// length as its duration, and the real length is `mediaFramesRead / sampleRate` at EOF (media3's
/// ConstantBitrateSeeker does the same, re-emitting its SeekMap when the decode reaches the
/// garbage). With no total length there is no estimate at all.
final class HeaderlessCBRDurationTests: XCTestCase {
    private static let trueFrames = 124416

    private final class MemoryReader: StreamByteReader {
        private let data: Data
        private let knownLength: Bool
        private var offset: Int64 = 0
        init(_ data: Data, knownLength: Bool) { self.data = data; self.knownLength = knownLength }
        var totalLength: Int64? { knownLength ? Int64(data.count) : nil }
        var position: Int64 { offset }
        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            let take = min(Int(Int64(data.count) - offset), maxLength)
            if take <= 0 { return 0 }
            data.withUnsafeBytes { memcpy(buffer, $0.baseAddress!.advanced(by: Int(offset)), take) }
            offset += Int64(take)
            return take
        }
        func seek(to newOffset: Int64) throws { offset = newOffset }
        func cancel() {}
        func interrupt() {}
        func clearInterrupt() {}
    }

    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bear-cbr-no-seek-table-trailing-garbage.mp3")
        return try Data(contentsOf: url)
    }

    private func drain(_ decoder: FFmpegStreamDecoder, channels: Int) -> Int {
        var floats = 0
        while let chunk = decoder.nextChunk() { floats += chunk.count }
        return floats / channels
    }

    func testUnknownLengthHasNoDurationAndStillDecodesTheWholeAudio() throws {
        let decoder = FFmpegStreamDecoder(reader: MemoryReader(try fixture(), knownLength: false))
        let format = try decoder.open()
        XCTAssertNil(format.duration)
        XCTAssertEqual(drain(decoder, channels: format.channelCount), Self.trueFrames)
        XCTAssertEqual(decoder.endReason, .eof)
    }

    func testKnownLengthEstimatesPastTheAudioAndEofGivesTheRealLength() throws {
        let decoder = FFmpegStreamDecoder(reader: MemoryReader(try fixture(), knownLength: true))
        let format = try decoder.open()
        XCTAssertGreaterThan(try XCTUnwrap(format.duration), 10, "the estimate runs over the garbage")
        let frames = drain(decoder, channels: format.channelCount)
        XCTAssertEqual(decoder.endReason, .eof)
        XCTAssertEqual(Double(frames) / format.sampleRate, 2.821187, accuracy: 0.011)
    }

    /// A seek past the true end, inside the estimate, ends the stream at EOF without an error.
    func testASeekPastTheTrueEndEndsCleanly() throws {
        for target in [5.0, 12.0] {
            let decoder = FFmpegStreamDecoder(reader: MemoryReader(try fixture(), knownLength: true))
            let format = try decoder.open()
            XCTAssertNoThrow(try decoder.seek(toSeconds: target), "seek to \(target)")
            _ = drain(decoder, channels: format.channelCount)
            XCTAssertEqual(decoder.endReason, .eof, "seek to \(target)")
        }
    }
}
