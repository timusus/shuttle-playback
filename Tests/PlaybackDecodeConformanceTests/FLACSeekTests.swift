import Foundation
import XCTest

@testable import PlaybackDecode

/// A FLAC seek on a stream with no seek table (issue #38), beyond what `flac_stereo.flac`'s golden
/// pins: that fixture is four seconds, so a far seek in a long file, where libavformat's bisection
/// outruns the seek budget and the byte estimate is all a seek used to have, is generated here.
final class FLACSeekTests: XCTestCase {

    /// A file reader that counts what it serves and how often it is sent somewhere. With
    /// `failOnceFrom`, the first read at or after that byte fails, as a read the byte source gave up
    /// on would.
    private final class CountingReader: StreamByteReader {
        private struct ReadFailed: Error {}

        private let inner: FileByteReader
        private var failOnceFrom: Int64?
        private(set) var bytesRead: Int64 = 0
        private(set) var seeks = 0

        /// With `failFirstReadAfterSeeks`, the first read after that many seeks since `armed` fails.
        var failFirstReadAfterSeeks: Int?
        private var armedSeeks = 0

        init(_ url: URL, failOnceFrom: Int64? = nil) throws {
            inner = try FileByteReader(url: url)
            self.failOnceFrom = failOnceFrom
        }

        func arm(failingReadAfterSeeks n: Int) {
            failFirstReadAfterSeeks = n
            armedSeeks = 0
        }

        var totalLength: Int64? { inner.totalLength }
        var position: Int64 { inner.position }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            if let from = failOnceFrom, inner.position >= from {
                failOnceFrom = nil
                throw ReadFailed()
            }
            if let after = failFirstReadAfterSeeks, armedSeeks >= after {
                failFirstReadAfterSeeks = nil
                throw ReadFailed()
            }
            let n = try inner.read(into: buffer, maxLength: maxLength)
            bytesRead += Int64(n)
            return n
        }

        func seek(to offset: Int64) throws {
            seeks += 1
            armedSeeks += 1
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
    /// `trailing` zero bytes follow the last frame, as an appended tag would. With `lookalikes`,
    /// the last samples of every second noise frame spell a valid frame header naming an earlier
    /// frame.
    /// Returns the file, its PCM interleaved, and its largest frame.
    private func writeFLAC(variable: Bool, trailing: Int = 0, lookalikes: Bool = false, unknownTotal: Bool = false, steady: Bool = false) throws -> (URL, [Int16], Int) {
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
            let noise = steady || (seconds >= 20 && seconds < 40) || seconds >= 50
            var frame: [UInt8] = [0xFF, variable ? 0xF9 : 0xF8]
            let sizeCode: UInt8 = blockSize == 4096 ? 12 : blockSize == 1152 ? 3 : 7
            frame.append(sizeCode << 4 | 9)          // 44.1 kHz
            frame.append(1 << 4 | 4 << 1)            // two independent channels, 16 bits
            frame += Self.utf8(UInt64(variable ? first : index))
            if sizeCode == 7 { frame += [UInt8((blockSize - 1) >> 8), UInt8((blockSize - 1) & 0xFF)] }
            frame.append(Self.crc8(frame))
            var samples = (0..<2).map { channel in
                noise ? (0..<blockSize).map { Self.noise(first + $0, channel) }
                    : [Int16](repeating: Int16(index % 64 * 8 - 256 + channel), count: blockSize)
            }
            if lookalikes && noise && index % 2 == 0 && blockSize >= 8 {
                // A header of this stream, CRC-8 and all, naming the frame three before this one.
                // In every frame, each would name the one after the last's: a chain as consistent
                // as the real one.
                var fake: [UInt8] = [0xFF, variable ? 0xF9 : 0xF8, 12 << 4 | 9, 1 << 4 | 4 << 1]
                fake += Self.utf8(UInt64(variable ? max(first - 3 * 4096, 0) : max(index - 3, 0)))
                fake.append(Self.crc8(fake))
                fake += [UInt8](repeating: 0, count: fake.count % 2)
                for (i, k) in stride(from: 0, to: fake.count, by: 2).enumerated() {
                    samples[1][blockSize - fake.count / 2 + i] = Int16(bitPattern: UInt16(fake[k]) << 8 | UInt16(fake[k + 1]))
                }
            }
            for channel in 0..<2 {
                if noise {
                    frame.append(0x02)               // VERBATIM
                    for v in samples[channel] {
                        frame += [UInt8(UInt16(bitPattern: v) >> 8), UInt8(UInt16(bitPattern: v) & 0xFF)]
                    }
                } else {
                    frame.append(0x00)               // CONSTANT
                    let v = samples[channel][0]
                    frame += [UInt8(UInt16(bitPattern: v) >> 8), UInt8(UInt16(bitPattern: v) & 0xFF)]
                }
            }
            let crc = Self.crc16(frame)
            frame += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            for k in 0..<blockSize {
                for channel in 0..<2 { pcm.append(samples[channel][k]) }
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
        let packed = UInt64(Self.rate) << 44 | 1 << 41 | 15 << 36 | UInt64(unknownTotal ? 0 : total)
        file += (0..<8).map { UInt8(packed >> (56 - 8 * $0) & 0xFF) }
        file += [UInt8](repeating: 0, count: 16)     // no MD5
        let padding = 8192
        file += [0x81, UInt8(padding >> 16), UInt8(padding >> 8 & 0xFF), UInt8(padding & 0xFF)]
        file += [UInt8](repeating: 0, count: padding)
        file += frames
        file += [UInt8](repeating: 0, count: trailing)

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
    /// target, then decodes from there and drops up to the target. The file is as hard as a FLAC
    /// gets (its bitrate jumps 700-fold); before issue #38 its far seeks landed by byte ratio,
    /// seconds from their target, and said they had landed on it.
    func testAFLACWithNoSeekTableSeeksExactlyFarAndNearWithinItsBudget() throws {
        // Far into each kind of stretch, both ways, then near the last landing both ways.
        try assertSeeksExactly(to: [45.0, 30.5, 55.123, 0.25, 59.9, 21.0, 21.1, 20.95, 12.345, 12.3])
    }

    /// **A FLAC followed by a tag seeks to its end exactly, not into the tag.**
    ///
    /// 64 KiB of zeros after the last frame (an appended ID3v2 or APE tag) count in the file's
    /// length but hold no frame, so a seek near the end interpolated into them and read a largest
    /// frame's worth with no header there. Such a probe bounds the search from above, as a byte
    /// with nothing after it does; before, it ended the search, the byte estimate went into the
    /// tag, and the retry for an estimate past the last frame (issue #28) stepped back once, still
    /// inside the tag, and reported the end.
    func testAFLACFollowedByATagSeeksToItsEndExactly() throws {
        try assertSeeksExactly(to: [59.9, 59.99, 59.5, 30.5], trailing: 64 * 1024)
    }

    /// **A header lookalike inside a frame's data does not move a seek.**
    ///
    /// The last samples of every second noise frame spell a header of this stream with a right
    /// CRC-8, naming the frame three before it, between two real headers. A header at or before
    /// the target is believed only when a later one follows it, so the lookalike costs a frame of
    /// scanning, where taking it would have anchored the seek a frame early and labelled the audio
    /// four frames late; and the real header before it is still followed by the one after it,
    /// where keeping only the latest header met had the lookalike hide it, and a probe read two
    /// more frames to believe one, or gave up.
    func testAHeaderLookalikeInsideAFrameDoesNotMoveASeek() throws {
        try assertSeeksExactly(to: [25.5, 33.3, 21.0, 39.0, 55.123, 52.2], lookalikes: true)
    }

    /// **A search that needs many probes still lands where it says (issue #42).**
    ///
    /// From near the end, 55.123 s lies across the quiet stretch at 40-50 s from the noise either
    /// side, and the bracket narrowed past ten probes. The search stopped there, unplaced, and the
    /// byte estimate began on whatever frame followed its byte while reporting 55.123.
    func testASeekNeedingManyProbesLandsWhereItSays() throws {
        try assertSeeksExactly(to: [59.9, 59.99, 55.123])
    }

    /// **A FLAC followed by a very large tag lands where it says (issue #42).**
    ///
    /// 256 KiB of zeros after the last frame counted in the byte estimate the search used to fall
    /// back on, which landed seconds early while reporting the target. Once a probe has found no
    /// frame after it, the bytes before it are not all audio, so the search bisects rather than
    /// interpolating into the tag again: about eight probes from the end on this file, so it is
    /// allowed twice the usual probing.
    ///
    /// A seek inside the last frame (59.99 s) is included (issue #52): FFmpeg's FLAC parser drops a
    /// lone frame header once 160 KiB follow with no other, so the seek lands two frames earlier
    /// and decodes on to the target.
    func testAFLACFollowedByAVeryLargeTagLandsWhereItSays() throws {
        try assertSeeksExactly(to: [59.9, 59.99, 55.123, 45.0, 30.5], trailing: 256 * 1024, probing: 256 * 1024)
    }

    /// **A search that cannot finish lands on the frame it has, and says so (issue #42).**
    ///
    /// One read fails a megabyte in, where the first probe for 45 s reads, so the probe gives up.
    /// The only frame the seek knows before its target is then seconds back, further than a seek
    /// may decode: it lands there and reports that frame's time, where the byte estimate it used
    /// to take reported 45 s over audio from somewhere else.
    func testASearchThatGivesUpLandsOnTheFrameItHasAndSaysSo() throws {
        let (url, pcm, _) = try writeFLAC(variable: false)
        let decoder = FFmpegStreamDecoder(reader: try CountingReader(url, failOnceFrom: 1 << 20))
        _ = try decoder.open()
        let landed = try decoder.seek(toSeconds: 45.0)
        XCTAssertLessThan(landed, 40.0, "landed \(landed)")
        let window = 4096
        var got: [Float] = []
        while got.count < window * 2, let chunk = decoder.nextChunk() { got += chunk }
        let start = Int((landed * Double(Self.rate)).rounded()) * 2
        XCTAssertEqual(start % (4096 * 2), 0, "landed \(landed), not on a frame")
        let want = pcm[start..<start + window * 2].map { Float($0) / 32768 }
        XCTAssertEqual(Array(got.prefix(window * 2)), want, "PCM differs from the stream's at the landing")
    }

    /// **A FLAC whose STREAMINFO has no sample count seeks exactly (issue #54).**
    ///
    /// What FFmpeg writes to a pipe, where it cannot go back to fill the count in. Such a file has
    /// no duration either, so `can_estimate_bytes` is false and the bounded probe has nothing to
    /// aim from: the demuxer's own bisection is the only seek (media3 gives such a file no seeking
    /// at all). Its cost is not bounded, so neither bytes nor reader seeks are asserted; the
    /// landing and the PCM are.
    func testAFLACWithNoSampleCountSeeksExactly() throws {
        try assertSeeksExactly(to: [45.0, 30.5, 55.123, 0.25, 59.9, 59.99, 21.0, 12.345], unknownTotal: true, bounded: false)
        try assertSeeksExactly(to: [59.9, 59.99, 55.123, 30.5], trailing: 64 * 1024, unknownTotal: true, bounded: false)
    }

    /// **A read that fails during a seek never makes it land by byte estimate (issue #54).**
    ///
    /// The first read after the n-th reader seek fails, for each n a seek makes (the search's
    /// probes, then the anchored placement). Whichever read it is, the seek reports where it
    /// landed and the PCM there is the stream's: never the target over audio from elsewhere.
    func testAReadFailingDuringASeekStillReportsWhereItLanded() throws {
        // The swinging file's byte estimate is tens of seconds wrong, so its fallback probe finds
        // no frame at or before the target and the demuxer's bisection (unbounded) is the last
        // resort: only the landing is held there. On a steady-bitrate file the estimate is
        // right, the fallback is the one probe, and the seek is exact and bounded.
        for steady in [false, true] {
            let (url, pcm, maxFrame) = try writeFLAC(variable: false, steady: steady)
            // A search of up to five probes, the seek budget, the parser's ten frames, one refill.
            let budget = Int64(5 * (2 * maxFrame + 64) + 64 * 1024 + 11 * maxFrame + 32 * 1024)
            var exact = 0
            for n in 0...9 {
                let reader = try CountingReader(url)
                let decoder = FFmpegStreamDecoder(reader: reader)
                _ = try decoder.open()
                reader.arm(failingReadAfterSeeks: n)
                let bytesBefore = reader.bytesRead
                guard let landed = try? decoder.seek(toSeconds: 45.0) else { continue }
                var got: [Float] = []
                while got.count < 4096 * 2, let chunk = decoder.nextChunk() { got += chunk }
                let bytes = reader.bytesRead - bytesBefore
                let label = "\(steady ? "steady" : "swinging") n=\(n)"
                let start = Int((landed * Double(Self.rate)).rounded()) * 2
                XCTAssertLessThanOrEqual(landed, 45.0 + 0.5 / Double(Self.rate), "\(label): landed \(landed)")
                if steady && abs(landed - 45.0) <= 0.5 / Double(Self.rate) {
                    exact += 1
                    XCTAssertLessThanOrEqual(bytes, budget, "\(label): read \(bytes) bytes")
                }
                guard start + 4096 * 2 <= pcm.count else { continue }
                let want = pcm[start..<start + 4096 * 2].map { Float($0) / 32768 }
                XCTAssertEqual(Array(got.prefix(4096 * 2)), want, "\(label): PCM differs from the stream's at \(landed)")
            }
            if steady { XCTAssertGreaterThanOrEqual(exact, 1, "no failing read ended in an exact bounded landing") }
        }
    }

    /// Seek the generated FLAC, fixed and variable blocksize, to each target in turn, and require
    /// the landing, the PCM after it and the bytes read before it to be what an exact seek gives.
    /// The bytes are bounded by `probing` (plus the probe that crosses it, at most two frames), a
    /// placement at most 64 KiB before the target, the ten frames the FLAC parser buffers before it
    /// hands out the first, and one AVIO refill.
    private func assertSeeksExactly(to targets: [Double], trailing: Int = 0, lookalikes: Bool = false, unknownTotal: Bool = false, bounded: Bool = true,
                                    probing: Int = 128 * 1024,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        for variable in [false, true] {
            let (url, pcm, maxFrame) = try writeFLAC(variable: variable, trailing: trailing, lookalikes: lookalikes, unknownTotal: unknownTotal)
            let reader = try CountingReader(url)
            let decoder = FFmpegStreamDecoder(reader: reader)
            let format = try decoder.open()
            XCTAssertEqual(format.sampleRate, Double(Self.rate), file: file, line: line)
            let budget = Int64(probing + 2 * maxFrame + 64 + 64 * 1024 + 11 * maxFrame + 32 * 1024)
            let window = 4096

            for target in targets {
                let label = "\(variable ? "variable" : "fixed") blocksize, seek to \(target)s"
                let bytesBefore = reader.bytesRead
                let seeksBefore = reader.seeks
                let landed = try decoder.seek(toSeconds: target)
                var got: [Float] = []
                while got.count < window * 2, let chunk = decoder.nextChunk() { got += chunk }
                let bytes = reader.bytesRead - bytesBefore
                got = Array(got.prefix(window * 2))

                XCTAssertEqual(landed, target, accuracy: 0.5 / Double(Self.rate), "\(label): landed \(landed)",
                               file: file, line: line)
                // The PCM is checked at the reported landing, so a landing reported at the target
                // with the audio elsewhere fails here as well as above.
                let start = min(max(Int((landed * Double(Self.rate)).rounded()) * 2, 0), pcm.count)
                let want = pcm[start..<min(start + window * 2, pcm.count)].map { Float($0) / 32768 }
                XCTAssertEqual(got.count, want.count, "\(label): frames after the landing", file: file, line: line)
                if let miss = zip(got, want).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                    XCTFail("\(label): PCM differs from the stream's at frame \(miss / 2) after the landing",
                            file: file, line: line)
                }
                guard bounded else { continue }
                XCTAssertLessThanOrEqual(bytes, budget, "\(label): read \(bytes) bytes before its first audio",
                                         file: file, line: line)
                XCTAssertLessThanOrEqual(reader.seeks - seeksBefore, 16,
                                         "\(label): positioned the reader \(reader.seeks - seeksBefore) times",
                                         file: file, line: line)
            }
        }
    }
}
