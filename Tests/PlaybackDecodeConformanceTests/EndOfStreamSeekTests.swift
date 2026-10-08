import Foundation
import XCTest

@testable import PlaybackDecode

/// A byte-estimate seek that falls past the start of the last frame: the demuxer finds
/// no frame to sync to, the stream ends with nothing decoded, and audio remains before the declared
/// end. No fixture reaches it with the real 64 KiB budget, since each is read whole by the open or
/// seeks by an index, so the stream here is long, and the budget is shrunk below one frame to
/// stand for an overshoot of several budgets.
final class EndOfStreamSeekTests: XCTestCase {

    /// A file reader that counts what it serves.
    private final class CountingReader: StreamByteReader {
        private let inner: FileByteReader
        private(set) var bytesRead: Int64 = 0

        init(_ url: URL) throws { inner = try FileByteReader(url: url) }

        var totalLength: Int64? { inner.totalLength }
        var position: Int64 { inner.position }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            let n = try inner.read(into: buffer, maxLength: maxLength)
            bytesRead += Int64(n)
            return n
        }

        func seek(to offset: Int64) throws { try inner.seek(to: offset) }
        func cancel() { inner.cancel() }
        func interrupt() { inner.interrupt() }
        func clearInterrupt() { inner.clearInterrupt() }
    }

    /// An ADTS stream of one 158-byte frame of `adts_id3.aac` repeated 6000 times: constant
    /// bitrate, so the duration libavformat estimates from it is the audio's to within 3 ms and a
    /// byte estimate places a time where it is.
    private func writeConstantBitrateADTS() throws -> URL {
        let source = [UInt8](try Data(contentsOf: GoldenStore.fixturesDir.appendingPathComponent("adts_id3.aac")))
        var at = 10 + (Int(source[6]) << 21 | Int(source[7]) << 14 | Int(source[8]) << 7 | Int(source[9]))
        var frame: [UInt8] = []
        for _ in 0...40 {
            let length = Int(source[at + 3] & 3) << 11 | Int(source[at + 4]) << 3 | Int(source[at + 5]) >> 5
            frame = Array(source[at..<at + length])
            at += length
        }
        XCTAssertEqual(frame.count, 158)
        var file = Data()
        for _ in 0..<6000 { file += frame }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adts-cbr-\(UUID().uuidString).aac")
        try file.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// **A seek whose estimate falls in the last frame lands on audio before it, not on the end.**
    ///
    /// With a 32-byte budget the generic ADTS seek is refused at once and the byte estimate, a few
    /// milliseconds before the end, falls up to 150 bytes into the last frame: more than four
    /// budgets. The retry steps back from there, a little further each time, until a frame decodes;
    /// a single step of one budget stays inside the frame and reported the end with nothing
    /// decoded. The landing is where the step went, so the audio after it runs to the stream's end;
    /// and no step walks the file, which the demuxer's own seek would (it has no index past the
    /// open's first frames).
    func testAnEstimatePastTheLastFrameStepsBackToAudio() throws {
        let url = try writeConstantBitrateADTS()
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try clean.open()
        var total = 0
        while let chunk = clean.nextChunk() { total += chunk.count / format.channelCount }
        let end = Double(total) / format.sampleRate
        let frame = 1024 / format.sampleRate

        for back in [0.002, 0.005, 0.012, 0.02] {
            let reader = try CountingReader(url)
            let decoder = FFmpegStreamDecoder(reader: reader)
            _ = try decoder.open()
            decoder.setSeekBudgetBytesForTesting(32)
            let target = end - back
            let bytesBefore = reader.bytesRead
            let landed = try decoder.seek(toSeconds: target)
            let bytes = reader.bytesRead - bytesBefore
            var after = 0
            while let chunk = decoder.nextChunk() { after += chunk.count / format.channelCount }

            let label = "seek to \(target)s, \(back)s before the end"
            XCTAssertGreaterThan(after, 0, "\(label): landed \(landed)s with nothing decoded")
            XCTAssertLessThanOrEqual(landed, target, "\(label): landed \(landed)s")
            XCTAssertGreaterThan(landed, target - 3 * frame, "\(label): landed \(landed)s")
            XCTAssertEqual(landed + Double(after) / format.sampleRate, end, accuracy: 1.5 * frame,
                           "\(label): landed \(landed)s and decoded \(after) frames")
            XCTAssertEqual(decoder.endReason, .eof, "\(label)")
            XCTAssertLessThanOrEqual(bytes, 128 * 1024, "\(label): read \(bytes) bytes")
        }
    }
}
