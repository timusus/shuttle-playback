import Foundation
import XCTest

@testable import PlaybackDecode

/// A source that can only move forward (an unknown-length chunked transcode): no total length, and
/// any seek behind the read position throws ``StreamByteReaderError/unseekable``.
private final class ForwardOnlyByteReader: StreamByteReader {
    private let data: Data
    private var offset: Int64 = 0
    private(set) var refusedSeeks = 0
    private(set) var refusedTargets: [Int64] = []

    private let knowsLength: Bool

    init(_ data: Data, knowsLength: Bool = false) {
        self.data = data
        self.knowsLength = knowsLength
    }

    var totalLength: Int64? { knowsLength ? Int64(data.count) : nil }
    var position: Int64 { offset }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let take = min(Int(Int64(data.count) - offset), maxLength)
        if take <= 0 { return 0 }
        data.withUnsafeBytes { memcpy(buffer, $0.baseAddress!.advanced(by: Int(offset)), take) }
        offset += Int64(take)
        return take
    }

    func seek(to newOffset: Int64) throws {
        guard newOffset >= offset else {
            refusedSeeks += 1
            refusedTargets.append(newOffset)
            throw StreamByteReaderError.unseekable
        }
        offset = newOffset
    }

    func cancel() {}
    func interrupt() {}
    func clearInterrupt() {}
}

/// Issue #45: a seek the source cannot serve is reported as such, not as a corrupt stream.
final class ForwardOnlySourceTests: XCTestCase {
    private func reader(_ fixture: String = "tone.mp3") throws -> ForwardOnlyByteReader {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixture)")
        return ForwardOnlyByteReader(try Data(contentsOf: url))
    }

    private func drain(_ decoder: FFmpegStreamDecoder) -> Int {
        var floats = 0
        while let chunk = decoder.nextChunk() { floats += chunk.count }
        return floats
    }

    /// Far enough that offset 0 has left libavformat's read buffer, so the seek reaches the reader.
    private func readPast100KB(_ decoder: FFmpegStreamDecoder) {
        while decoder.bytesConsumed < 100_000, decoder.nextChunk() != nil {}
        XCTAssertGreaterThanOrEqual(decoder.bytesConsumed, 100_000)
    }

    func testOpenAndSequentialDecodeWork() throws {
        let decoder = FFmpegStreamDecoder(reader: try reader())
        _ = try decoder.open()
        XCTAssertGreaterThan(drain(decoder), 0)
        XCTAssertEqual(decoder.endReason, .eof)
    }

    /// A forward-only source that knows its length (a download that has not started a range): an
    /// untagged CBR MP3 must open and decode with no seek behind the read position, so no open-time
    /// look at the file's tail.
    func testUntaggedCBRMP3OfKnownLengthOpensAndDecodesWithoutATailSeek() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/cbr_no_table.mp3")
        let source = ForwardOnlyByteReader(try Data(contentsOf: url), knowsLength: true)
        let decoder = FFmpegStreamDecoder(reader: source)
        _ = try decoder.open()
        XCTAssertGreaterThan(drain(decoder), 0)
        XCTAssertEqual(decoder.endReason, .eof)
        // The one refusal is the ID3 probe putting its 10 header bytes back (rewind to 0); it is
        // tolerated. Nothing seeks to the tail.
        XCTAssertTrue(source.refusedTargets.allSatisfy { $0 == 0 }, "refused: \(source.refusedTargets)")
    }

    func testBackwardSeekFailsAsUnseekableNotAsCorruptStream() throws {
        let source = try reader()
        let decoder = FFmpegStreamDecoder(reader: source)
        _ = try decoder.open()
        readPast100KB(decoder)
        XCTAssertThrowsError(try decoder.seek(toSeconds: 0)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .unseekable)
        }
        XCTAssertGreaterThan(source.refusedSeeks, 0)
    }

    /// The decoder's state after the refusal is specified: it has failed, and reads end.
    func testDecoderIsFailedAfterTheRefusedSeek() throws {
        let decoder = FFmpegStreamDecoder(reader: try reader())
        _ = try decoder.open()
        readPast100KB(decoder)
        XCTAssertThrowsError(try decoder.seek(toSeconds: 0))
        XCTAssertEqual(decoder.endReason, .failure)
        XCTAssertNil(decoder.nextChunk())
    }

    /// Terminal means terminal: a later forward seek must not succeed over the broken demuxer.
    func testSeekAfterTheRefusalIsRefusedWithoutReachingTheReader() throws {
        let source = try reader()
        let decoder = FFmpegStreamDecoder(reader: source)
        _ = try decoder.open()
        readPast100KB(decoder)
        XCTAssertThrowsError(try decoder.seek(toSeconds: 0))
        let refused = source.refusedSeeks
        let position = source.position
        XCTAssertThrowsError(try decoder.seek(toSeconds: 1)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .unseekable)
        }
        XCTAssertEqual(source.refusedSeeks, refused)
        XCTAssertEqual(source.position, position)
        XCTAssertEqual(decoder.endReason, .failure)
    }

    /// A refusal is per decoder and per seek: a fresh decoder, and a later seek that the source
    /// can serve, are not reported as unseekable.
    func testARefusalDoesNotLeakIntoAFreshDecoder() throws {
        let first = FFmpegStreamDecoder(reader: try reader())
        _ = try first.open()
        readPast100KB(first)
        XCTAssertThrowsError(try first.seek(toSeconds: 0))

        let second = FFmpegStreamDecoder(reader: try reader())
        _ = try second.open()
        let landed = try second.seek(toSeconds: 0.5)
        XCTAssertEqual(landed, 0.5, accuracy: 0.05)
        XCTAssertEqual(second.endReason, .running)
        XCTAssertGreaterThan(drain(second), 0)
    }

    func testForwardSeekOnTheForwardOnlyReaderSucceeds() throws {
        let source = try reader()
        let decoder = FFmpegStreamDecoder(reader: source)
        _ = try decoder.open()
        let landed = try decoder.seek(toSeconds: 1)
        XCTAssertEqual(landed, 1, accuracy: 0.05)
        XCTAssertNotNil(decoder.nextChunk())
    }
}
