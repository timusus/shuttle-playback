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
        GoldenStore.fixtureURLs().first { $0.lastPathComponent == name }!
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
    /// bitrate held the podcast player's far seek silent for 470 ms. What a seek needs before its
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
                     ("mpeg25_8k_mono.mp3", 12.0, true)]
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
            let targetByte = Int64(Double(size) * target / format.duration)
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
        for url in GoldenStore.fixtureURLs() where url.pathExtension == "mp3" {
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
    /// first frame's bitrate and is labelled with the time asked for (issue #3), and this compares
    /// where the audio is, not when: what follows the seek has to be a stretch of the clean decode,
    /// to the bit. The requested times are fractions of the duration the demuxer estimates, the
    /// range its estimate places inside the file, and are past the reach of a decode from the start.
    func testAFarSeekIntoAVBRMP3WithNoTagDecodesCleanPCM() throws {
        let url = GoldenStore.root.appendingPathComponent("SeekFixtures/vbr_no_xing_bitrate_drop.mp3")
        let (format, clean) = try decodeAll(url)
        let channels = format.channelCount
        let window = 2048 * channels
        for fraction in [0.25, 0.4, 0.55, 0.7, 0.85] {
            let target = format.duration * fraction
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
}
