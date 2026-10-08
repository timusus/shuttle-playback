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
    /// Refuses every seek, forward ones too (a pure stream).
    private let refusesAllSeeks: Bool
    /// Reads at or past this offset fail with a transport error (an outage), until it is cleared.
    var outageFrom: Int64?

    init(_ data: Data, knowsLength: Bool = false, refusesAllSeeks: Bool = false) {
        self.data = data
        self.knowsLength = knowsLength
        self.refusesAllSeeks = refusesAllSeeks
    }

    var totalLength: Int64? { knowsLength ? Int64(data.count) : nil }
    var position: Int64 { offset }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let end = outageFrom ?? Int64(data.count)
        if offset >= end, outageFrom != nil { throw URLError(.networkConnectionLost) }
        let take = min(Int(min(end, Int64(data.count)) - offset), maxLength)
        if take <= 0 { return 0 }
        data.withUnsafeBytes { memcpy(buffer, $0.baseAddress!.advanced(by: Int(offset)), take) }
        offset += Int64(take)
        return take
    }

    func seek(to newOffset: Int64) throws {
        guard newOffset >= offset, !refusesAllSeeks else {
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
        let forward = try decodeAll(FFmpegStreamDecoder(reader: source))
        // The one refusal is the ID3 probe putting its 10 header bytes back (rewind to 0); the
        // stash serves them, so it is harmless. Nothing seeks to the tail.
        XCTAssertEqual(source.refusedTargets, [0])
        let seekable = try decodeAll(FFmpegStreamDecoder(reader: FileByteReader(url: url, reportsTotalLength: false)))
        XCTAssertGreaterThan(forward.count, 0)
        XCTAssertEqual(forward, seekable)
    }

    /// A reader that refuses every seek, forward ones too: an ID3v2 tag (one, then two stacked) is
    /// skipped by reading, and the decode is bit-identical to the seekable one.
    func testID3TaggedMP3DecodesBitIdenticallyOnAReaderThatRefusesEverySeek() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures")
        let tagged = fixtures.appendingPathComponent("bear-id3.mp3")
        let tone = try Data(contentsOf: fixtureURL("tone.mp3"))

        func tag(size: Int) -> Data {
            let syncsafe = [size >> 21, size >> 14, size >> 7, size].map { UInt8($0 & 0x7F) }
            return Data([0x49, 0x44, 0x33, 4, 0, 0] + syncsafe) + Data(repeating: 0, count: size)
        }
        let stacked = FileManager.default.temporaryDirectory.appendingPathComponent("stacked-id3-\(UUID().uuidString).mp3")
        try (tag(size: 3000) + tag(size: 40) + tone).write(to: stacked)
        defer { try? FileManager.default.removeItem(at: stacked) }

        for url in [tagged, stacked] {
            let seekable = try decodeAll(FFmpegStreamDecoder(reader: FileByteReader(url: url, reportsTotalLength: false)))
            let source = ForwardOnlyByteReader(try Data(contentsOf: url), refusesAllSeeks: true)
            let forward = try decodeAll(FFmpegStreamDecoder(reader: source))
            XCTAssertGreaterThan(forward.count, 0, url.lastPathComponent)
            XCTAssertEqual(forward, seekable, url.lastPathComponent)
        }
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

    /// A failed read is not terminal, but the seek that follows it on a forward-only source is
    /// still a refusal: it fails as unseekable, and stays so once the source is back.
    func testASeekAfterAFailedReadOnTheForwardOnlyReaderIsRefusedAndStaysRefused() throws {
        let source = try reader()
        source.outageFrom = 120_000
        let decoder = FFmpegStreamDecoder(reader: source)
        _ = try decoder.open()
        _ = drain(decoder)
        XCTAssertEqual(decoder.endReason, .failure)

        XCTAssertThrowsError(try decoder.seek(toSeconds: 0)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .unseekable)
        }
        XCTAssertGreaterThan(source.refusedSeeks, 0)

        source.outageFrom = nil
        let refused = source.refusedSeeks
        let position = source.position
        // Forward, so the reader would serve it: only the latch refuses it.
        XCTAssertThrowsError(try decoder.seek(toSeconds: 18)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .unseekable)
        }
        XCTAssertEqual(source.refusedSeeks, refused)
        XCTAssertEqual(source.position, position)
        XCTAssertEqual(decoder.endReason, .failure)
        XCTAssertNil(decoder.nextChunk())
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

    // MARK: Issue #56: the other containers open and decode on a forward-only source

    private static let containers = ["flac_51_48k.flac", "chained_vorbis_44k_48k.ogg", "tone_moov_first.m4a"]

    private func fixtureURL(_ fixture: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(fixture)")
    }

    private func decodeAll(_ decoder: FFmpegStreamDecoder) throws -> [Float] {
        _ = try decoder.open()
        var samples: [Float] = []
        while let chunk = decoder.nextChunk() { samples += chunk }
        XCTAssertEqual(decoder.endReason, .eof)
        return samples
    }

    func testFLACOggAndMP4DecodeBitIdenticallyToTheSeekableDecode() throws {
        for fixture in Self.containers {
            let seekable = try decodeAll(FFmpegStreamDecoder(reader: FileByteReader(url: fixtureURL(fixture), reportsTotalLength: false)))
            let source = try reader(fixture)
            let forward = try decodeAll(FFmpegStreamDecoder(reader: source))
            // The stash path ran: the ID3 probe's one rewind was refused and its bytes replayed.
            XCTAssertEqual(source.refusedSeeks, 1, fixture)
            XCTAssertGreaterThan(forward.count, 0, fixture)
            XCTAssertEqual(forward, seekable, fixture)
        }
    }

    func testBackwardSeekOnFLACOggAndMP4IsUnseekable() throws {
        for fixture in Self.containers {
            let decoder = FFmpegStreamDecoder(reader: try reader(fixture))
            _ = try decoder.open()
            while decoder.bytesConsumed < 100_000, decoder.nextChunk() != nil {}
            XCTAssertThrowsError(try decoder.seek(toSeconds: 0), fixture) { error in
                XCTAssertEqual(error as? StreamDecoderError, .unseekable, fixture)
            }
        }
    }
}
