import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

extension StreamDecodeTests {
    // MARK: - Parity against AVAssetReader

    func testDecodeMatchesAVAssetReader() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            let url = try Fixture.url(name)
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            let format = try decoder.open()
            let ours = decodeAll(decoder)
            XCTAssertEqual(decoder.endReason, .eof, "\(name): a full decode must end at EOF")

            let ourFrames = ours.count / format.channelCount
            /* Our side is checked against the fixtures' known length (20 s), never against
             * AVAssetReader alone: #35 measured AVAssetReader returning 336 frames short of the
             * edit list's end on about 1 run in 60 (tone_moov_first.m4a, status .completed, no
             * error), while our count was 882000 every time. */
            XCTAssertEqual(ourFrames, Fixture.frameCount, "\(name): frame count differs from the fixture's known length (the edit list's end is not honoured)")

            /* A short AVAssetReader result is re-read (up to 3 attempts) before it counts. Ours must
             * still match one of its reads exactly, so the check on our side is not weakened. */
            var reference = try ReferenceDecoder.decode(url: url)
            var attempts = [reference.pcm.count / reference.channels]
            while attempts.last != ourFrames, attempts.count < 3 {
                reference = try ReferenceDecoder.decode(url: url)
                attempts.append(reference.pcm.count / reference.channels)
            }
            XCTAssertEqual(reference.channels, format.channelCount, "\(name)")
            let referenceFrames = reference.pcm.count / reference.channels
            XCTAssertEqual(ourFrames, referenceFrames,
                           "\(name): frame count differs from AVAssetReader's (ours \(ourFrames), AVAssetReader attempts \(attempts); the edit list's end is not honoured)")

            let a = PCMComparison.channel(ours, index: 0, of: format.channelCount)
            let b = PCMComparison.channel(reference.pcm, index: 0, of: reference.channels)
            let lag = PCMComparison.bestLag(a, b, sampleRate: format.sampleRate)
            let rms = PCMComparison.rmsDifference(a, b, lag: lag)
            XCTAssertLessThan(rms, 2e-3, "\(name): RMS \(rms) at lag \(lag)")
            /* **The priming check.** `stream_decode.c` never touches `skip_samples`, and the review
             * asked whether an AAC decode therefore starts 2048 frames of encoder priming early.
             * It does not: FFmpeg's own `decode.c` applies `AV_PKT_DATA_SKIP_SAMPLES` unless
             * `AV_CODEC_FLAG2_SKIP_MANUAL` is set, and this file never sets it, so the mov demuxer's
             * edit-list priming is trimmed before a frame reaches us. Measured: lag 0 on all three
             * fixtures. The bound is here so that a future flag change cannot make it 2048 quietly.
             * */
            XCTAssertLessThanOrEqual(abs(lag), 64,
                                     "\(name): \(lag) frames of lag against AVAssetReader — codec priming is not being trimmed")
            XCTAssertEqual(decoder.mediaFramesRead, Int64(ourFrames), "\(name)")
        }
    }

    // MARK: - Seek

    func testSeekLandsOnTheAudioNotTheRequest() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            let url = try Fixture.url(name)
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            let format = try decoder.open()
            let landed = try decoder.seek(toSeconds: 10)
            /* MP3 without a per-frame index lands on a frame boundary near a bitrate estimate, so
             * it gets the looser bound. What both must do is REPORT where they landed. */
            let tolerance = name == Fixture.mp3 ? 0.5 : 0.15
            XCTAssertEqual(landed, 10, accuracy: tolerance, "\(name): landed \(landed)")

            var ours: [Float] = []
            while ours.count < Int(format.sampleRate) * format.channelCount * 3,
                  let chunk = decoder.nextChunk() {
                ours.append(contentsOf: chunk)
            }
            XCTAssertGreaterThan(ours.count, 0, "\(name): nothing decoded after the seek")

            /* Compared against the WHOLE reference decode, anchored at the landed time, because
             * that is the claim being tested: the audio after the seek is the audio at the second
             * the decoder reported, not merely audio that resembles the file somewhere. */
            let reference = try ReferenceDecoder.decode(url: url)
            /* Drop the first 250 ms. Every decoder needs a frame or two of context after a flush —
             * MP3's hybrid filterbank has nothing to overlap-add against and emits silence, AAC
             * ramps in — so the audio right after a seek is warm-up, not the file. Measured here:
             * with the warm-up included the post-seek PCM matches nothing within a second of the
             * landing; with it dropped it is bit-identical to this decoder's own linear decode of
             * the same file at the same second. The player hears the same brief artifact any
             * seeking player does. */
            let warmup = Int(format.sampleRate / 4)
            let a = Array(PCMComparison.channel(ours, index: 0, of: format.channelCount).dropFirst(warmup))
            let b = PCMComparison.channel(reference.pcm, index: 0, of: reference.channels)
            let anchor = Int((landed * format.sampleRate).rounded()) + warmup
            let (lag, rms) = PCMComparison.rms(a, inside: b, nearIndex: anchor, sampleRate: format.sampleRate)
            XCTAssertLessThan(rms, 2e-3, "\(name): post-seek RMS \(rms) at lag \(lag) from \(landed)s")
        }
    }

    /// **A seek that blows its byte budget must still play.**
    ///
    /// The budget is enforced by refusing the read, which reaches libavformat as an IO error — and
    /// `AVIOContext` LATCHES one: `error` keeps the code and `eof_reached` stays 1, while
    /// `avio_seek` resets only the second. So the byte-estimate seek that followed landed
    /// correctly and then every read after it came back with the old EIO without asking the byte
    /// source for anything: `status 7` on a stream that was perfectly readable. Seen first over
    /// HTTP, where the window hands out a few kilobytes at a time, which is why the reader here
    /// answers in 4 KiB pieces — a reader that serves whole buffers refills past the latch and
    /// hides it.
    ///
    /// The budget is shrunk because every fixture in this package seeks by an index or a table of
    /// contents and never spends the real one.
    func testASeekThatBlowsItsBudgetStillLandsAndPlays() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let decoder = FFmpegStreamDecoder(reader: try ChunkedFileByteReader(url: url, chunkBytes: 4 * 1024))
        let format = try decoder.open()
        decoder.setSeekBudgetBytesForTesting(8 * 1024)

        let landed = try decoder.seek(toSeconds: 10)
        XCTAssertEqual(landed, 10, accuracy: 0.5, "landed \(landed) after the fallback estimate")

        var after: [Float] = []
        while after.count < Int(format.sampleRate) * format.channelCount,
              let chunk = decoder.nextChunk() {
            after.append(contentsOf: chunk)
        }
        XCTAssertGreaterThan(after.count, 0, "nothing decoded after the abandoned seek")
        XCTAssertEqual(decoder.endReason, .running, "the decoder ended: \(decoder.endReason)")
        let peak = after.dropFirst(Int(format.sampleRate) / 4).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "the post-seek audio is silence, not the tone")
    }

    /// A far seek in a VBR MP3 lands by its Xing TOC, so it is the one seek that reports inexact;
    /// the same distance in a headerless CBR file is counted by byte offset and stays exact.
    func testLastSeekWasExactIsFalseOnlyForAFarVBRSeek() throws {
        try skipUnlessAvailable()
        let vbr = FFmpegStreamDecoder(reader: try FileByteReader(url: try GeneratedFixture.xingVBRMP3()))
        _ = try vbr.open()
        _ = try vbr.seek(toSeconds: 150)
        XCTAssertFalse(vbr.lastSeekWasExact, "a far VBR seek lands by the TOC")
        _ = try vbr.seek(toSeconds: 0)
        XCTAssertTrue(vbr.lastSeekWasExact, "a later exact seek reports exact again")

        let cbr = FFmpegStreamDecoder(reader: try FileByteReader(url: try GeneratedFixture.largeCBRMP3()))
        _ = try cbr.open()
        _ = try cbr.seek(toSeconds: 900)
        XCTAssertTrue(cbr.lastSeekWasExact, "a far CBR seek is counted by frames")
    }

    func testLastSeekWasExactForEveryFixtureFormat() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(name)))
            _ = try decoder.open()
            XCTAssertTrue(decoder.lastSeekWasExact, "\(name): before any seek")
            _ = try decoder.seek(toSeconds: 10)
            XCTAssertTrue(decoder.lastSeekWasExact, "\(name): seek")
        }
    }

    /// **A seek past the end of an edit-listed file lands on the clipped end, not beyond it.**
    ///
    /// The frames wholly before a far seek's target are skipped, and the final ones overhang the
    /// edit list's end: their timing must be clamped to it all the same.
    func testSeekPastTheEndLandsOnTheClippedEnd() throws {
        try skipUnlessAvailable()
        for name in [Fixture.moovFirst, Fixture.moovLast] {
            let url = try Fixture.url(name)
            let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            let format = try clean.open()
            let end = Double(decodeAll(clean).count / format.channelCount) / format.sampleRate

            for target in [end + 0.5, 1e6] {
                let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
                _ = try decoder.open()
                let landed = try decoder.seek(toSeconds: target)
                XCTAssertEqual(landed, end, accuracy: 1e-9, "\(name): seek to \(target)s landed \(landed)s")
                XCTAssertTrue(decodeAll(decoder).isEmpty, "\(name): PCM after a seek to \(target)s")
            }
        }
    }

    /// **A frame with no timestamp after a seek is timed from where the seek went.**
    ///
    /// The pre-roll before a seek's target is dropped by the frames' timestamps. A frame with none
    /// must not switch the drop off, or the whole pre-roll (16384 samples here) is played and
    /// reported as the target. No demuxer in this build hands out an untimed packet after a seek,
    /// so the test strips them all.
    func testAFrameWithNoTimestampAfterASeekIsTimedFromWhereTheSeekWent() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.moovFirst)
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try clean.open()
        let reference = decodeAll(clean)
        let channels = format.channelCount
        let rate = format.sampleRate

        // Index of the first frame of `after` in the clean decode, searched near `expected`.
        func offset(of after: [Float], near expected: Int, within: Int) -> Int? {
            let probe = Array(after.prefix(512 * channels))
            for frame in max(0, expected - within)...(expected + within) {
                let start = frame * channels
                guard start + probe.count <= reference.count else { break }
                if zip(probe, reference[start..<start + probe.count]).allSatisfy({ abs($0 - $1) < 1e-4 }) {
                    return frame
                }
            }
            return nil
        }

        for target in [0.25, 10.0] {
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            _ = try decoder.open()
            decoder.dropTimestampsForTesting()
            let landed = try decoder.seek(toSeconds: target)
            var after: [Float] = []
            while after.count < Int(rate) * channels, let chunk = decoder.nextChunk() {
                after.append(contentsOf: chunk)
            }
            let landedFrame = Int((landed * rate).rounded())
            let found = offset(of: after, near: landedFrame, within: 4096)
            XCTAssertNotNil(found, "seek to \(target)s: the audio after it is nowhere near \(landed)s")
            guard let found else { continue }
            if target * rate < 16384 {
                // Placed at the start, whose time is known: exact.
                XCTAssertEqual(landed, target, accuracy: 1 / rate)
                XCTAssertEqual(found, landedFrame, "seek to \(target)s from the start")
            } else {
                // Placed by the demuxer at or up to one frame before the pre-roll's start.
                XCTAssertEqual(landed, target, accuracy: 1 / rate)
                XCTAssertLessThanOrEqual(abs(found - landedFrame), 1024,
                                         "seek to \(target)s: audio at frame \(found), reported \(landedFrame)")
            }
        }
    }

}
