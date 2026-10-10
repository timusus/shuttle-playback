import Foundation
import XCTest

@testable import PlaybackDecode

/// What an MP3 seek costs and what it decodes, beyond what the goldens pin: the goldens compare a
/// seek's PCM after a warm-up, so a pre-roll too short to converge by the target, or one far longer
/// than it needs, passes them both.
final class MP3SeekTests: XCTestCase {

    /// A file reader that serves at most `chunk` bytes per read, as a download that has just
    /// restarted serves what has arrived, and records every position it is sent to.
    private final class TrickleReader: StreamByteReader {
        private let inner: FileByteReader
        private let chunk: Int
        private(set) var bytesRead: Int64 = 0
        private(set) var positions: [Int64] = []

        init(_ url: URL, chunk: Int = 256) throws {
            inner = try FileByteReader(url: url)
            self.chunk = chunk
        }

        var totalLength: Int64? { inner.totalLength }
        var position: Int64 { inner.position }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            let n = try inner.read(into: buffer, maxLength: min(maxLength, chunk))
            bytesRead += Int64(n)
            return n
        }

        func seek(to offset: Int64) throws {
            positions.append(offset)
            try inner.seek(to: offset)
        }

        func cancel() { inner.cancel() }
        func interrupt() { inner.interrupt() }
        func clearInterrupt() { inner.clearInterrupt() }
    }

    private func fixture(_ name: String) -> URL {
        let seekOnly = GoldenStore.root.appendingPathComponent("SeekFixtures/\(name)")
        if FileManager.default.fileExists(atPath: seekOnly.path) { return seekOnly }
        return GoldenStore.fixtureURLs().first { $0.lastPathComponent == name }!
    }

    private func decodeAll(_ url: URL) throws -> (StreamAudioFormat, [Float]) {
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try decoder.open()
        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm += chunk }
        return (format, pcm)
    }

    /// **A far seek on a constant-bitrate MP3 reads from just before its target, once.**
    ///
    /// On a stream still downloading, a seek past the fetched bytes restarts the download at the
    /// first position the decoder asks for, and plays nothing until the bytes from there to the
    /// target have arrived. 0.3.0 asked for 4 KiB before the frame (mp3_sync's backward window);
    /// 0.3.1 added a 16384-sample pre-roll on top, 7 KiB in all at 64 kbps, which at twice the
    /// bitrate held a far seek into a growing file silent for 470 ms. What a seek needs before its
    /// target is the bit reservoir the target's frames can reach: about 1 KiB at 64 kbps.
    ///
    /// Positions after the first are fine as long as they are inside what the seek has read since
    /// (a growing file serves those from disk); one before the first would be a second restart.
    /// The short fixtures are sought backward from their end: forward, they sit inside AVIO's
    /// short-seek distance and are read through rather than sought.
    func testAFarCBRSeekReadsFromJustBeforeItsTarget() throws {
        let cases = [("tone.mp3", 15.0, false), ("tone.mp3", 6.0, true),
                     ("cbr_no_table.mp3", 2.5, true), ("lame_info_delay_padding.mp3", 2.5, true),
                     ("cbr_32k_dense_reservoir.mp3", 5.0, true), ("cbr_info_64k.mp3", 4.0, true),
                     ("mpeg25_8k_mono.mp3", 12.0, true), ("cbr_22k_8k_padded.mp3", 15.0, true)]
        for (name, target, fromTheEnd) in cases {
            let url = fixture(name)
            let reader = try TrickleReader(url)
            let decoder = FFmpegStreamDecoder(reader: reader)
            let format = try decoder.open()
            var frames = 0
            while fromTheEnd || frames < Int(format.sampleRate) / 2, let chunk = decoder.nextChunk() {
                frames += chunk.count / format.channelCount
            }
            let size = try XCTUnwrap(reader.totalLength)
            let targetByte = Int64(Double(size) * target / (try XCTUnwrap(format.duration)))
            let positionsBefore = reader.positions.count
            let bytesBefore = reader.bytesRead

            let landed = try decoder.seek(toSeconds: target)
            let positions = Array(reader.positions.dropFirst(positionsBefore))
            let bytes = reader.bytesRead - bytesBefore
            let label = "\(name) to \(target)s"

            XCTAssertEqual(landed, target, accuracy: 0.5 / format.sampleRate, "\(label): landed \(landed)")
            guard let first = positions.first else { XCTFail("\(label): the seek never positioned the reader"); continue }
            XCTAssertLessThanOrEqual(targetByte - first, 2048,
                                     "\(label): the seek read from \(targetByte - first) bytes before its target")
            XCTAssert(positions.allSatisfy { $0 >= first && $0 <= first + bytes },
                      "\(label): the seek went back before where it started reading: \(positions)")
            XCTAssertLessThanOrEqual(bytes, 4096, "\(label): the seek read \(bytes) bytes before its first audio")
        }
    }

    /// **An MP3 seek decodes exactly what an unbroken decode does, from the requested sample on.**
    ///
    /// The pre-roll is sized to the bit reservoir rather than a blanket amount, so this is what
    /// says it is long enough: every MP3 fixture, at seven places, against the clean decode, to the
    /// bit. The long ones are there for this: noise at 32 kbps (a frame's main data reaching up to
    /// seven frames back), an 8 kHz MPEG-2.5 stream and an Info-tagged CBR stream, each long enough
    /// that its seeks land by frame placement rather than by decoding forward from the first frame.
    func testMP3SeeksDecodeTheCleanPCMFromTheTargetSample() throws {
        // A VBR stream with no Xing/VBRI tag lands by bitrate estimate and cannot match. Accepted:
        // a tagless VBR MP3 far from a known-time frame seeks by estimate, as in media3; the
        // golden pins its landings. play-trimmed.mp3 does not open.
        let skipped: Set = ["bear-vbr-no-seek-table.mp3", "play-trimmed.mp3"]
        for url in GoldenStore.fixtureURLs() where url.pathExtension == "mp3" && !skipped.contains(url.lastPathComponent) {
            let (format, clean) = try decodeAll(url)
            let channels = format.channelCount
            let duration = Double(clean.count / channels) / format.sampleRate
            for target in (1...6).map({ duration * Double($0) / 7 }) + [duration - 0.5] {
                let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
                _ = try decoder.open()
                let landed = try decoder.seek(toSeconds: target)
                var got: [Float] = []
                while got.count < 4096 * channels, let chunk = decoder.nextChunk() { got += chunk }
                let start = Int((landed * format.sampleRate).rounded()) * channels
                let compared = min(got.count, clean.count - start)
                XCTAssertGreaterThan(compared, 0, "\(url.lastPathComponent): nothing after the seek to \(target)")
                let firstDiff = (0..<max(0, compared)).first { got[$0] != clean[start + $0] }
                XCTAssertNil(firstDiff, "\(url.lastPathComponent): the seek to \(target) differs from the clean decode "
                             + "\(firstDiff.map { $0 / channels } ?? 0) frames after the target")
            }
        }
    }

    /// **A far seek into a VBR MP3 with no Xing header decodes clean audio, whatever its first frame says.**
    ///
    /// The fixture opens on 0.4 s of loud noise at 112 kbps and goes on at 32 to 48 kbps, so its first
    /// frame says nothing about the frames a far seek lands among: three frames of pre-roll cover the
    /// bit reservoir at 112 kbps and not at 32. A seek with too little decodes the frames after it
    /// from a reservoir it never read, which is a burst of noise where the target should be.
    ///
    /// Without a tag nothing in the file says what time a frame is, so a seek this far lands by the
    /// first frame's bitrate and is labelled with the time asked for, and this compares
    /// where the audio is, not when: what follows the seek has to be a stretch of the clean decode,
    /// to the bit. The requested times are fractions of the duration the demuxer estimates, the
    /// range its estimate places inside the file, and are past the reach of a decode from the start.
    func testAFarSeekIntoAVBRMP3WithNoTagDecodesCleanPCM() throws {
        let url = GoldenStore.root.appendingPathComponent("SeekFixtures/vbr_no_xing_bitrate_drop.mp3")
        let (format, clean) = try decodeAll(url)
        let channels = format.channelCount
        let window = 2048 * channels
        for fraction in [0.25, 0.4, 0.55, 0.7, 0.85] {
            let target = try XCTUnwrap(format.duration) * fraction
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            _ = try decoder.open()
            _ = try decoder.seek(toSeconds: target)
            var got: [Float] = []
            while got.count < window, let chunk = decoder.nextChunk() { got += chunk }
            XCTAssertEqual(got.count >= window, true, "seek to \(target)s: only \(got.count / channels) frames after it")
            guard got.count >= window else { continue }
            let found = stride(from: 0, through: clean.count - window, by: channels).first { start in
                clean[start] == got[0] && (0..<window).allSatisfy { clean[start + $0] == got[$0] }
            }
            XCTAssertNotNil(found, "seek to \(target)s: the \(window / channels) frames after it are nowhere in the clean decode")
        }
    }

    /// **A seek into a CBR MP3 whose frames are never padded plays from the sample it reports.**
    ///
    /// At 128 kbps and 44.1 kHz a frame averages 417.96 bytes, but an encoder that never sets the
    /// padding bit writes every frame at 417, and a seek that counts frames by the average lands
    /// 0.23% late: some 8 s an hour. The fixture's Info frame counts its 461 frames and their bytes;
    /// without it, the frames themselves have to say they are never padded.
    func testASeekIntoACBRMP3WithUnpaddedFramesPlaysFromItsTarget() throws {
        let url = GoldenStore.root.appendingPathComponent("SeekFixtures/cbr_128k_unpadded_info.mp3")
        let (format, _) = try decodeAll(url)
        XCTAssertEqual(try XCTUnwrap(format.duration), 461.0 * 1152 / 44100, accuracy: 1e-6)
        try assertSeeksPlayFromTheirTarget(url)

        var untagged = try Data(contentsOf: url)
        let id3 = 10 + 512
        untagged.removeSubrange(id3..<(id3 + 417))
        let untaggedURL = FileManager.default.temporaryDirectory.appendingPathComponent("cbr-unpadded-no-info-\(UUID().uuidString).mp3")
        try untagged.write(to: untaggedURL)
        defer { try? FileManager.default.removeItem(at: untaggedURL) }
        try assertSeeksPlayFromTheirTarget(untaggedURL)
    }

    /// An Info frame count that is off by a few (an encoder that counts the Info frame, say) while its
    /// byte count still ends at the audio's end gives a bytes-per-frame no CBR stream has; it is ignored.
    func testASeekIntoACBRMP3WithAMiscountedInfoFramePlaysFromItsTarget() throws {
        let url = GoldenStore.root.appendingPathComponent("SeekFixtures/cbr_128k_unpadded_info.mp3")
        var miscounted = try Data(contentsOf: url)
        let frameCount = 10 + 512 + 4 + 32 + 8
        XCTAssertEqual(miscounted[(frameCount - 8)..<(frameCount - 4)], Data("Info".utf8))
        miscounted.replaceSubrange(frameCount..<(frameCount + 4), with: [0, 0, 0x01, 0xD0])
        let miscountedURL = FileManager.default.temporaryDirectory.appendingPathComponent("cbr-unpadded-miscounted-\(UUID().uuidString).mp3")
        try miscounted.write(to: miscountedURL)
        defer { try? FileManager.default.removeItem(at: miscountedURL) }
        try assertSeeksPlayFromTheirTarget(miscountedURL)
    }

    private func assertSeeksPlayFromTheirTarget(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let (format, clean) = try decodeAll(url)
        let duration = try XCTUnwrap(format.duration)
        let channels = format.channelCount
        let window = 2048 * channels
        for fraction in [0.5, 0.75, 0.95] {
            let target = duration * fraction
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            _ = try decoder.open()
            let landed = try decoder.seek(toSeconds: target)
            let label = "\(url.lastPathComponent) to \(target)s"
            XCTAssertEqual(landed, target, accuracy: 0.5 / format.sampleRate, label, file: file, line: line)
            var got: [Float] = []
            while got.count < window, let chunk = decoder.nextChunk() { got += chunk }
            XCTAssertGreaterThanOrEqual(got.count, window, "\(label): only \(got.count / channels) frames after it",
                                        file: file, line: line)
            guard got.count >= window else { continue }
            let found = stride(from: 0, through: clean.count - window, by: channels).first { start in
                clean[start] == got[0] && (0..<window).allSatisfy { clean[start + $0] == got[$0] }
            }
            let played = try XCTUnwrap(found, "\(label): the audio after it is nowhere in the clean decode",
                                       file: file, line: line) / channels
            XCTAssertEqual(played, Int((landed * format.sampleRate).rounded()),
                           "\(label): played from \(Double(played) / format.sampleRate)s", file: file, line: line)
        }
    }

    /// The frames of an MPEG-2 Layer III 22.05 kHz stream (the VBR fixture's), as byte ranges.
    private func mp3Frames(_ data: Data) -> [Range<Int>] {
        let kbps = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
        var frames: [Range<Int>] = []
        var pos = 0
        while pos + 4 <= data.count {
            let h = (UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16) | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3])
            let rate = Int((h >> 12) & 15)
            guard h >> 20 == 0xFFF, (h >> 10) & 3 == 0, rate != 0, rate != 15 else { pos += 1; continue }
            let size = 72000 * kbps[rate] / 22050 + Int((h >> 9) & 1)
            guard pos + size <= data.count else { break }
            frames.append(pos..<(pos + size))
            pos += size
        }
        return frames
    }

    /// **A far seek into a VBR MP3 with no tag, onto frames that share the first frame's bitrate by
    /// chance, is not placed as if the stream were constant-bitrate.**
    ///
    /// With no tag frame, a stream was taken for constant-bitrate on its first frame's word alone, and
    /// a far seek read where a constant-bitrate stream would have the frame it wanted and accepted any
    /// frame there with the first frame's bitrate. A VBR file has such frames now and then; this one
    /// has forty of them where the constant-bitrate estimate points, after quiet frames at a third of
    /// the bitrate, so the seek landed there: some eleven seconds into the audio, reported as four.
    /// The file opens with frames of several bitrates, which says it is not constant-bitrate, and its
    /// seek goes by the demuxer's own estimate, which lands within half a second of the request here.
    func testAFarSeekIntoAVBRMP3WithNoTagIsNotPlacedByTheFirstFramesBitrate() throws {
        let source = try Data(contentsOf: GoldenStore.root.appendingPathComponent("SeekFixtures/vbr_no_xing_bitrate_drop.mp3"))
        let frames = mp3Frames(source)
        let first = frames[0]
        let pool = Array(frames[17..<(frames.count - 1)])
        let frameBytes = 576.0 / 8 * 112000 / 22050
        let block = 40
        var offsets = [first.count]
        for n in 0..<(pool.count * 3) { offsets.append(offsets[n] + pool[n % pool.count].count) }
        // Where a constant-bitrate stream would have frame `index`, a byte offset that is a frame
        // boundary of the quiet frames laid out so far.
        var found: (index: Int, count: Int)?
        search: for index in 120..<400 {
            let estimate = Double(first.count) + Double(index - 1) * frameBytes
            for (n, at) in offsets.enumerated() where abs(Double(at) - estimate) <= 2 {
                found = (index, n)
                break search
            }
        }
        let splice = try XCTUnwrap(found)
        var data = source.subdata(in: first)
        for n in 0..<(splice.count + 80) {
            if n == splice.count {
                // Frames of the first frame's bitrate, padded as a constant-bitrate stream pads them.
                var carried = 0.0
                for _ in 0..<block {
                    carried += frameBytes
                    let padded = Int(carried) > Int(carried - frameBytes) + first.count
                    var frame = source.subdata(in: first)
                    if padded { frame[2] |= 0x02; frame.append(0) }
                    data += frame
                }
            }
            data += source.subdata(in: pool[n % pool.count])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vbr-shares-first-bitrate-\(UUID().uuidString).mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (format, clean) = try decodeAll(url)
        let channels = format.channelCount
        let window = 2048 * channels
        let target = (Double(splice.index) + Double(block) / 2) * 576 / format.sampleRate
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try decoder.open()
        let landed = try decoder.seek(toSeconds: target)
        var got: [Float] = []
        while got.count < window, let chunk = decoder.nextChunk() { got += chunk }
        XCTAssertGreaterThanOrEqual(got.count, window)
        guard got.count >= window else { return }
        let found2 = stride(from: 0, through: clean.count - window, by: channels).first { start in
            clean[start] == got[0] && (0..<window).allSatisfy { clean[start + $0] == got[$0] }
        }
        let played = try XCTUnwrap(found2.map { Double($0 / channels) / format.sampleRate }, "the audio after the seek is nowhere in the clean decode")
        XCTAssertEqual(played, landed, accuracy: 0.5, "the seek to \(target)s reported \(landed)s and played from \(played)s")
    }
}
