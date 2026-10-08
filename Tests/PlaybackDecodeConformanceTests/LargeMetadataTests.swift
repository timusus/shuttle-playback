import Foundation
import XCTest

@testable import PlaybackDecode

/// #46: `StreamProbeBudget` defaults to 64 KiB / 1 s, and no committed fixture has a large metadata
/// block before the audio. A FLAC with a 2 MB PICTURE block and an Ogg Vorbis with a 1 MB comment
/// are built here from the small fixtures (inserting the block in Swift, no tool needed) and opened
/// at the default budget, clean and through every `FaultyByteReader` combination. The metadata is
/// header-described, so it must open, decode the same audio as the small file, and seek.
final class LargeMetadataTests: XCTestCase {

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("large-metadata-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Builders

    private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * (3 - $0))) & 0xFF) } }
    private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    /// `flac_stereo.flac` with a PICTURE block of `pictureBytes` of image data right after STREAMINFO.
    private func flacWithPicture(pictureBytes: Int) throws -> Data {
        let original = try Data(contentsOf: fixture("flac_stereo.flac"))
        XCTAssertEqual(original.prefix(4), Data("fLaC".utf8))
        XCTAssertEqual(original[4] & 0x7F, 0, "first block is STREAMINFO")
        XCTAssertEqual(original[4] & 0x80, 0, "STREAMINFO is not the last block")
        let afterStreamInfo = 4 + 4 + 34
        let mime = Array("image/jpeg".utf8)
        var body: [UInt8] = be32(3) + be32(mime.count) + mime + be32(0)
        body += be32(500) + be32(500) + be32(24) + be32(0) + be32(pictureBytes)
        body += [UInt8](repeating: 0xA5, count: pictureBytes)
        let header: [UInt8] = [6, UInt8(body.count >> 16), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)]
        var out = original.prefix(afterStreamInfo)
        out.append(contentsOf: header + body)
        out.append(original.suffix(from: afterStreamInfo))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    private func oggPage(flags: UInt8, granule: UInt64, serial: UInt32, sequence: UInt32, lacing: [UInt8], payload: [UInt8]) -> [UInt8] {
        var page: [UInt8] = Array("OggS".utf8) + [0, flags]
        page += (0..<8).map { UInt8((granule >> (8 * UInt64($0))) & 0xFF) }
        page += le32(Int(serial)) + le32(Int(sequence)) + [0, 0, 0, 0] + [UInt8(lacing.count)] + lacing + payload
        var crc: UInt32 = 0
        for b in page { crc = (crc << 8) ^ Self.crcTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF] }
        page.replaceSubrange(22..<26, with: le32(Int(crc)))
        return page
    }

    /// `vorbis_stereo.ogg` with its comment header replaced by one carrying `commentBytes` of text;
    /// the setup header and every audio page follow, renumbered.
    private func vorbisWithComment(commentBytes: Int) throws -> Data {
        let src = [UInt8](try Data(contentsOf: fixture("vorbis_stereo.ogg")))
        struct Page { var granule: UInt64; var serial: UInt32; var lacing: [UInt8]; var payload: [UInt8]; var flags: UInt8 }
        var pages: [Page] = []
        var at = 0
        while at + 27 <= src.count, src[at..<at + 4].elementsEqual("OggS".utf8) {
            let count = Int(src[at + 26])
            let lacing = Array(src[at + 27..<at + 27 + count])
            let size = lacing.reduce(0) { $0 + Int($1) }
            let start = at + 27 + count
            let granule = (0..<8).reduce(UInt64(0)) { $0 | UInt64(src[at + 6 + $1]) << (8 * UInt64($1)) }
            let serial = (0..<4).reduce(UInt32(0)) { $0 | UInt32(src[at + 14 + $1]) << (8 * UInt32($1)) }
            pages.append(Page(granule: granule, serial: serial, lacing: lacing, payload: Array(src[start..<start + size]), flags: src[at + 5]))
            at = start + size
        }
        XCTAssertEqual(at, src.count)
        // Header pages: the identification page, then every page up to the first with audio.
        let firstAudio = try XCTUnwrap(pages.firstIndex { $0.granule != 0 && $0.granule != .max })
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        for page in pages[1..<firstAudio] {
            var offset = 0
            for lace in page.lacing {
                current += page.payload[offset..<offset + Int(lace)]
                offset += Int(lace)
                if lace < 255 { packets.append(current); current = [] }
            }
        }
        XCTAssertTrue(current.isEmpty)
        XCTAssertEqual(packets.count, 2, "comment and setup headers")
        let vendor = Array("probe-test".utf8)
        let text = Array("PADDING=".utf8) + [UInt8](repeating: 0x41, count: commentBytes)
        let comment: [UInt8] = [3] + Array("vorbis".utf8) + le32(vendor.count) + vendor + le32(1)
            + le32(text.count) + text + [1]

        let serial = pages[0].serial
        var out = oggPage(flags: pages[0].flags, granule: 0, serial: serial, sequence: 0, lacing: pages[0].lacing, payload: pages[0].payload)
        var sequence: UInt32 = 1
        var lacing: [UInt8] = []
        for packet in [comment, packets[1]] {
            lacing += [UInt8](repeating: 255, count: packet.count / 255) + [UInt8(packet.count % 255)]
        }
        let body = comment + packets[1]
        var consumed = 0
        var continued = false
        var lacingAt = 0
        while lacingAt < lacing.count {
            let slice = Array(lacing[lacingAt..<min(lacingAt + 255, lacing.count)])
            let size = slice.reduce(0) { $0 + Int($1) }
            let last = lacingAt + slice.count == lacing.count
            out += oggPage(flags: continued ? 1 : 0, granule: slice.last == 255 ? .max : 0, serial: serial, sequence: sequence,
                           lacing: slice, payload: Array(body[consumed..<consumed + size]))
            sequence += 1
            consumed += size
            lacingAt += slice.count
            continued = !last && slice.last == 255
        }
        for page in pages[firstAudio...] {
            out += oggPage(flags: page.flags, granule: page.granule, serial: serial, sequence: sequence, lacing: page.lacing, payload: page.payload)
            sequence += 1
        }
        return Data(out)
    }

    // MARK: Assertions

    private func decodeAll(_ decoder: FFmpegStreamDecoder, channels: Int) -> Int {
        var frames = 0
        while let chunk = decoder.nextChunk() { frames += chunk.count / channels }
        return frames
    }

    /// Open, decode the whole file and compare with the small file's decode; then seek to the middle.
    /// An injected I/O error interrupts a decode, which the matrix recovers by seeking (and a resumed
    /// decode restarts the codec), so the `ioErrorOncePerPosition` combinations compare the frame
    /// count only and skip both the PCM comparison and the seek, which `FaultyByteReader` would
    /// interrupt too. With `seekFailsWithUnknownLength` the seek of the unknown-length combinations is
    /// pinned as an expected failure (#55): fixing the bug fails the test, so remove the pin then.
    private func assertOpensDecodesAndSeeks(large: URL, reference: DecodeRun, name: String, switches: FaultSwitches,
                                            seekFailsWithUnknownLength: Bool) throws {
        let label = "\(name) \(switches)"
        let run = try ConformanceMatrix.decode(large, switches: switches)
        XCTAssertEqual(run.outcome, .decoded(end: "eof"), label)
        XCTAssertEqual(run.frames, reference.frames, label)
        XCTAssertEqual(run.format?.sampleRate, reference.format?.sampleRate, label)
        if !switches.contains(.unknownLength) {
            XCTAssertEqual(run.format?.duration ?? 0, reference.format?.duration ?? -1, accuracy: 0.05, label)
        }
        if !switches.contains(.ioErrorOncePerPosition) { XCTAssertTrue(run.pcm == reference.pcm, "\(label): PCM differs") }
        guard !switches.contains(.ioErrorOncePerPosition) else { return }
        // A seek of the 2 MB-PICTURE FLAC with no length fails (#55); the open and decode above do not.
        if seekFailsWithUnknownLength, switches.contains(.unknownLength) {
            XCTExpectFailure("\(label): known decoder bug, https://github.com/timusus/shuttle-playback/issues/55") {
                seekToTheMiddle(large: large, reference: reference, label: label, switches: switches)
            }
        } else {
            seekToTheMiddle(large: large, reference: reference, label: label, switches: switches)
        }
    }

    private func seekToTheMiddle(large: URL, reference: DecodeRun, label: String, switches: FaultSwitches) {
        do { try seekToTheMiddleOrThrow(large: large, reference: reference, label: label, switches: switches) } catch {
            XCTFail("\(label): \(error)")
        }
    }

    private func seekToTheMiddleOrThrow(large: URL, reference: DecodeRun, label: String, switches: FaultSwitches) throws {
        let decoder = FFmpegStreamDecoder(reader: try FaultyByteReader(url: large, switches: switches))
        let format = try decoder.open()
        let duration = Double(reference.frames) / format.sampleRate
        let target = duration / 2
        let landed: Double
        do { landed = try decoder.seek(toSeconds: target) } catch {
            return XCTFail("\(label): seek to \(target)s failed: \(error)")
        }
        XCTAssertEqual(landed, target, accuracy: 0.05, "\(label): seek landing")
        let after = decodeAll(decoder, channels: format.channelCount)
        XCTAssertEqual(Double(after) / format.sampleRate, duration - landed, accuracy: 0.05, "\(label): frames after the seek")
    }

    private func assertAtEveryReader(large: URL, small: URL, name: String, minBytesBeforeAudio: Int64,
                                     seekFailsWithUnknownLength: Bool = false) throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let reference = try ConformanceMatrix.decode(small, switches: [])
        // The file must stress the budget, or the test proves nothing.
        let clean = try ConformanceMatrix.decode(large, switches: [])
        XCTAssertGreaterThan(clean.bytesBeforeFirstAudio, minBytesBeforeAudio,
                             "\(name): bytes before the first audio vs the \(StreamProbeBudget.default.bytes) byte probe budget")
        XCTAssertGreaterThan(clean.bytesBeforeFirstAudio, 10 * StreamProbeBudget.default.bytes)
        for switches in [FaultSwitches()] + FaultSwitches.allCombinations {
            try assertOpensDecodesAndSeeks(large: large, reference: reference, name: name, switches: switches,
                                           seekFailsWithUnknownLength: seekFailsWithUnknownLength)
        }
    }

    func testFLACWithA2MBPictureOpensDecodesAndSeeksAtTheDefaultBudget() throws {
        let large = try write(try flacWithPicture(pictureBytes: 2 * 1024 * 1024), ext: "flac")
        try assertAtEveryReader(large: large, small: fixture("flac_stereo.flac"), name: "FLAC 2 MB PICTURE",
                           minBytesBeforeAudio: 2 * 1024 * 1024, seekFailsWithUnknownLength: true)
    }

    func testVorbisWithA1MBCommentOpensDecodesAndSeeksAtTheDefaultBudget() throws {
        let large = try write(try vorbisWithComment(commentBytes: 1024 * 1024), ext: "ogg")
        try assertAtEveryReader(large: large, small: fixture("vorbis_stereo.ogg"), name: "Vorbis 1 MB comment",
                           minBytesBeforeAudio: 1024 * 1024)
    }
}
