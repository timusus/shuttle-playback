import Foundation
import XCTest

@testable import PlaybackDecode

/// A reader over bytes held in memory, so a test can damage a committed fixture without writing it.
private final class MemoryByteReader: StreamByteReader {
    private let bytes: [UInt8]
    private let lock = NSLock()
    private var offset = 0
    private var cancelled = false

    init(_ data: Data) { bytes = [UInt8](data) }

    var totalLength: Int64? { Int64(bytes.count) }
    var position: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(offset)
    }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw StreamByteReaderError.cancelled }
        let n = max(0, min(maxLength, bytes.count - offset))
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
        offset += n
        return n
    }

    func seek(to offset: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        self.offset = Int(max(0, min(offset, Int64(bytes.count))))
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func interrupt() {}
    func clearInterrupt() {}
}

/// One bad frame costs a glitch, not the rest of the recording.
final class CorruptStreamTests: XCTestCase {

    private func decode(_ data: Data) throws -> (frames: Int, reason: FFmpegStreamDecoder.EndReason) {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let decoder = FFmpegStreamDecoder(reader: MemoryByteReader(data))
        let format = try decoder.open()
        var samples = 0
        while let chunk = decoder.nextChunk() { samples += chunk.count }
        return (samples / format.channelCount, decoder.endReason)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try Fixture.url(name))
    }

    /// Inverts every third byte over `count` bytes from `offset`: inside the frames, not a clean cut.
    private func damaged(_ data: Data, at offset: Int, count: Int) -> Data {
        var out = data
        for i in stride(from: 0, to: count, by: 3) { out[offset + i] ^= 0xFF }
        return out
    }

    private func assertSurvivesDamage(_ name: String, at fraction: Double, count: Int) throws {
        let clean = try fixture(name)
        let (cleanFrames, cleanReason) = try decode(clean)
        XCTAssertEqual(cleanReason, .eof, name)

        let offset = Int(Double(clean.count) * fraction)
        let (frames, reason) = try decode(damaged(clean, at: offset, count: count))
        XCTAssertEqual(reason, .eof, "\(name): damage mid-stream must not end the decode")
        // The damaged frames are lost and a codec may conceal or drop a little around them; a
        // 20 s fixture losing under a second is a glitch, losing the rest is the bug.
        XCTAssertGreaterThan(frames, cleanFrames - 44100, "\(name): decoded \(frames) of \(cleanFrames)")
    }

    func testMP3SurvivesCorruptBytesInTheMiddle() throws {
        try assertSurvivesDamage(Fixture.mp3, at: 0.5, count: 3000)
    }

    func testAACSurvivesCorruptBytesInTheMiddle() throws {
        // Inside mdat, which holds the bulk of the file in both layouts.
        try assertSurvivesDamage(Fixture.moovFirst, at: 0.5, count: 3000)
        try assertSurvivesDamage(Fixture.moovLast, at: 0.4, count: 3000)
    }

    func testLongRunOfGarbageEndsWithAnErrorRatherThanHanging() throws {
        let clean = try fixture(Fixture.mp3)
        // Everything after the first quarter is noise, far more than any cap on skipped frames.
        let start = clean.count / 4
        var data = clean
        var state: UInt32 = 0x1234_5678
        for i in start..<data.count {
            state = state &* 1_664_525 &+ 1_013_904_223
            data[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let (frames, reason) = try decode(data)
        let (cleanFrames, _) = try decode(clean)
        XCTAssertLessThan(frames, cleanFrames, "garbage is not audio")
        XCTAssertNotEqual(reason, .running)
    }
}
