import Foundation
import XCTest

@testable import PlaybackDecode

/// Issue #50: the Info/Xing byte count is trusted as the end of the audio only when it is
/// plausible. A corrupt one (smaller than the tag frame, or past the end of the file) is ignored,
/// so the whole file stays audio instead of being cut at the bogus end.
final class InfoTagByteCountTests: XCTestCase {
    private final class MemoryReader: StreamByteReader {
        private let data: Data
        private var offset: Int64 = 0
        init(_ data: Data) { self.data = data }
        var totalLength: Int64? { Int64(data.count) }
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
            .appendingPathComponent("Fixtures/test-cbr-info-header-trailing-garbage.mp3")
        return try Data(contentsOf: url)
    }

    private func floats(_ data: Data) throws -> Int {
        let decoder = FFmpegStreamDecoder(reader: MemoryReader(data))
        _ = try decoder.open()
        var count = 0
        while let chunk = decoder.nextChunk() { count += chunk.count }
        return count
    }

    private func patchingByteCount(_ data: Data, to value: UInt32) throws -> Data {
        var out = data
        let tag = try XCTUnwrap(out.range(of: Data("Info".utf8)), "no Info tag in the fixture")
        let at = tag.lowerBound + 12
        for i in 0..<4 { out[at + i] = UInt8((value >> (24 - 8 * UInt32(i))) & 0xFF) }
        return out
    }

    /// A count smaller than the tag frame or past the end of the file is corrupt and must not set
    /// the end of the audio. Past the end, the file is just shorter than declared and the tag's
    /// frame count still applies (same as the clean decode). Too small, mp3dec sees a file far
    /// longer than declared and drops the count, as for any concatenated file: whole file, no trim.
    func testACorruptByteCountDoesNotSetTheEndOfTheAudio() throws {
        let data = try fixture()
        let clean = try floats(data)
        let large = try floats(try patchingByteCount(data, to: UInt32(data.count) * 4))
        XCTAssertEqual(large, clean)
        let small = try floats(try patchingByteCount(data, to: 100))
        XCTAssertGreaterThanOrEqual(small, clean)
        XCTAssertLessThanOrEqual(small, clean + 2 * 875)
    }
}
