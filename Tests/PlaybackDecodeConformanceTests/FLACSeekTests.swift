import Foundation
import XCTest

@testable import PlaybackDecode

/// A FLAC seek on a stream with no seek table (issue #38), beyond what `flac_stereo.flac`'s golden
/// pins: that fixture is four seconds, so a far seek in a long file, where libavformat's bisection
/// outruns the seek budget and the byte estimate is all a seek used to have, is generated here.
final class FLACSeekTests: XCTestCase {

    /// A file reader that counts what it serves and how often it is sent somewhere.
    private final class CountingReader: StreamByteReader {
        private let inner: FileByteReader
        private(set) var bytesRead: Int64 = 0
        private(set) var seeks = 0

        init(_ url: URL) throws { inner = try FileByteReader(url: url) }

        var totalLength: Int64? { inner.totalLength }
        var position: Int64 { inner.position }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            let n = try inner.read(into: buffer, maxLength: maxLength)
            bytesRead += Int64(n)
            return n
        }

        func seek(to offset: Int64) throws {
            seeks += 1
            try inner.seek(to: offset)
        }

        func cancel() { inner.cancel() }
        func interrupt() { inner.interrupt() }
        func clearInterrupt() { inner.clearInterrupt() }
    }

    private static let rate = 44100

    /// A 60 s stereo 16-bit FLAC with no SEEKTABLE whose bitrate swings as far as FLAC's can: quiet
    /// stretches of CONSTANT subframes (a few bytes a frame) between stretches of noise in VERBATIM
    /// ones (16 KiB a frame), so a byte ratio places a time tens of seconds wrong. An 8 KiB PADDING
    /// block puts the first frame past the bytes the decoder keeps from the open. `variable` codes
    /// sample numbers rather than frame numbers, with block sizes alternating 4096 and 1152.
    /// Returns the file, its PCM interleaved, and its largest frame.
    private func writeFLAC(variable: Bool) throws -> (URL, [Int16], Int) {
        let total = 60 * Self.rate
        var frames = Data()
        var pcm: [Int16] = []
        pcm.reserveCapacity(total * 2)
        var maxFrame = 0
        var first = 0
        var index = 0
        while first < total {
            let blockSize = min(variable && index % 2 == 1 ? 1152 : 4096, total - first)
            let seconds = first / Self.rate
            let noise = (seconds >= 20 && seconds < 40) || seconds >= 50
            var frame: [UInt8] = [0xFF, variable ? 0xF9 : 0xF8]
            let sizeCode: UInt8 = blockSize == 4096 ? 12 : blockSize == 1152 ? 3 : 7
            frame.append(sizeCode << 4 | 9)          // 44.1 kHz
            frame.append(1 << 4 | 4 << 1)            // two independent channels, 16 bits
            frame += Self.utf8(UInt64(variable ? first : index))
            if sizeCode == 7 { frame += [UInt8((blockSize - 1) >> 8), UInt8((blockSize - 1) & 0xFF)] }
            frame.append(Self.crc8(frame))
            for channel in 0..<2 {
                if noise {
                    frame.append(0x02)               // VERBATIM
                    for k in 0..<blockSize {
                        let v = Self.noise(first + k, channel)
                        frame += [UInt8(UInt16(bitPattern: v) >> 8), UInt8(UInt16(bitPattern: v) & 0xFF)]
                    }
                } else {
                    frame.append(0x00)               // CONSTANT
                    let v = Int16(index % 64 * 8 - 256 + channel)
                    frame += [UInt8(UInt16(bitPattern: v) >> 8), UInt8(UInt16(bitPattern: v) & 0xFF)]
                }
            }
            let crc = Self.crc16(frame)
            frame += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            for k in 0..<blockSize {
                for channel in 0..<2 {
                    pcm.append(noise ? Self.noise(first + k, channel) : Int16(index % 64 * 8 - 256 + channel))
                }
            }
            maxFrame = max(maxFrame, frame.count)
            frames.append(contentsOf: frame)
            first += blockSize
            index += 1
        }

        var file = Data("fLaC".utf8)
        file += [0x00, 0x00, 0x00, 34]               // STREAMINFO, not the last block
        let minBlock = variable ? 1152 : 4096
        file += [UInt8(minBlock >> 8), UInt8(minBlock & 0xFF), 0x10, 0x00]
        file += [0, 0, 0, UInt8(maxFrame >> 16), UInt8(maxFrame >> 8 & 0xFF), UInt8(maxFrame & 0xFF)]
        let packed = UInt64(Self.rate) << 44 | 1 << 41 | 15 << 36 | UInt64(total)
        file += (0..<8).map { UInt8(packed >> (56 - 8 * $0) & 0xFF) }
        file += [UInt8](repeating: 0, count: 16)     // no MD5
        let padding = 8192
        file += [0x81, UInt8(padding >> 16), UInt8(padding >> 8 & 0xFF), UInt8(padding & 0xFF)]
        file += [UInt8](repeating: 0, count: padding)
        file += frames

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-no-seektable-\(UUID().uuidString).flac")
        try file.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, pcm, maxFrame)
    }

    private static func noise(_ sample: Int, _ channel: Int) -> Int16 {
        var z = UInt64(sample * 2 + channel) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int16(truncatingIfNeeded: (z ^ (z >> 31)) >> 48)
    }

    private static func utf8(_ v: UInt64) -> [UInt8] {
        if v < 0x80 { return [UInt8(v)] }
        var n = 2
        while v >= UInt64(1) << (5 * n + 1) { n += 1 }
        var bytes = [UInt8((0xFF << (8 - n)) & 0xFF | Int(v >> (6 * (n - 1))))]
        for i in 1..<n { bytes.append(0x80 | UInt8(v >> (6 * (n - 1 - i)) & 0x3F)) }
        return bytes
    }

    private static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? crc << 1 ^ 0x07 : crc << 1 }
        }
        return crc
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x8005 : crc << 1 }
        }
        return crc
    }

    /// **A FLAC with no seek table seeks to the requested sample, far or near, within its budget.**
    ///
    /// Every frame header says which frame it is, so the seek reads headers at interpolated (or,
    /// where the bitrate jumps, bisected) bytes until it has a frame at most 32 KiB before the
    /// target, then decodes from there and drops up to the target. The bytes a seek reads before
    /// its first audio are bounded: 128 KiB of probing (plus the probe that crosses it, at most two
    /// frames), a placement at most 64 KiB before the target, the ten frames the FLAC parser
    /// buffers before it hands out the first, and one AVIO refill. The file is as hard as a FLAC
    /// gets (its bitrate jumps 700-fold); before issue #38 its far seeks landed by byte ratio,
    /// seconds from their target, and said they had landed on it.
    func testAFLACWithNoSeekTableSeeksExactlyFarAndNearWithinItsBudget() throws {
        for variable in [false, true] {
            let (url, pcm, maxFrame) = try writeFLAC(variable: variable)
            let reader = try CountingReader(url)
            let decoder = FFmpegStreamDecoder(reader: reader)
            let format = try decoder.open()
            XCTAssertEqual(format.sampleRate, Double(Self.rate))
            let budget = Int64(128 * 1024 + 2 * maxFrame + 64 + 64 * 1024 + 11 * maxFrame + 32 * 1024)
            let window = 4096

            // Far into each kind of stretch, both ways, then near the last landing both ways.
            for target in [45.0, 30.5, 55.123, 0.25, 59.9, 21.0, 21.1, 20.95, 12.345, 12.3] {
                let label = "\(variable ? "variable" : "fixed") blocksize, seek to \(target)s"
                let bytesBefore = reader.bytesRead
                let seeksBefore = reader.seeks
                let landed = try decoder.seek(toSeconds: target)
                var got: [Float] = []
                while got.count < window * 2, let chunk = decoder.nextChunk() { got += chunk }
                let bytes = reader.bytesRead - bytesBefore
                got = Array(got.prefix(window * 2))

                XCTAssertEqual(landed, target, accuracy: 0.5 / Double(Self.rate), "\(label): landed \(landed)")
                let start = Int((target * Double(Self.rate)).rounded()) * 2
                let want = pcm[start..<min(start + window * 2, pcm.count)].map { Float($0) / 32768 }
                XCTAssertEqual(got.count, want.count, "\(label): frames after the landing")
                if let miss = zip(got, want).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                    XCTFail("\(label): PCM differs from the stream's at frame \(miss / 2) after the landing")
                }
                XCTAssertLessThanOrEqual(bytes, budget, "\(label): read \(bytes) bytes before its first audio")
                XCTAssertLessThanOrEqual(reader.seeks - seeksBefore, 16, "\(label): positioned the reader \(reader.seeks - seeksBefore) times")
            }
        }
    }
}
