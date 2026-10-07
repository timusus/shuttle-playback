import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

/// The playback decoder's tests.
///
/// The two that matter most are the parity ones — the streamed decode has to sound like the
/// `AVAssetReader` decode of the same file — and `testMoovLastCostsOneSeekNotTheWholeFile`, the
/// only place the trailing-`moov` bandwidth trap is measured rather than assumed.
final class StreamDecodeTests: XCTestCase {

    private func skipUnlessAvailable() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    private func decodeAll(_ decoder: FFmpegStreamDecoder) -> [Float] {
        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm.append(contentsOf: chunk) }
        return pcm
    }

    // MARK: - Open

    func testOpenReportsSourceFormat() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(name)))
            let format = try decoder.open()
            XCTAssertEqual(format.sampleRate, 44100, "\(name): the player runs at the source's rate")
            XCTAssertEqual(format.channelCount, 2, "\(name)")
            XCTAssertEqual(try XCTUnwrap(format.duration), 20, accuracy: 0.2, "\(name)")
            XCTAssertFalse(format.codec.isEmpty, "\(name)")
            XCTAssertFalse(format.container.isEmpty, "\(name)")
        }
    }

    func testMoovLastAtomOrder() throws {
        /* Guards the bandwidth test below: if a re-encode ever put `moov` first in both fixtures,
         * that test would pass while measuring nothing. */
        let first = try atomOrder(try Fixture.url(Fixture.moovFirst))
        let last = try atomOrder(try Fixture.url(Fixture.moovLast))
        XCTAssertLessThan(first.firstIndex(of: "moov") ?? .max, first.firstIndex(of: "mdat") ?? .max)
        XCTAssertGreaterThan(last.firstIndex(of: "moov") ?? -1, last.firstIndex(of: "mdat") ?? -1)
    }

    // MARK: - Mid-stream format change

    /// A stitched fixture: 4 s of 440 Hz left / 660 Hz right at one rate glued to 4 s of the same
    /// tone at another, each half `frames` MP3 frames of 1,152 samples (no Xing tag, so nothing is
    /// trimmed).
    private struct Stitch {
        let name: String
        let rates: (Double, Double)
        let frames: (Int, Int)

        /// The output stays at the first half's rate, so the second half is resampled to it.
        var expectedFrames: Double {
            Double(frames.0 * 1152) + Double(frames.1 * 1152) * rates.0 / rates.1
        }
        /// Where the first half ends in the output.
        var switchFrame: Int { frames.0 * 1152 }
    }

    private let stitches = [
        Stitch(name: "stitch_44k_48k_64k.mp3", rates: (44100, 48000), frames: (155, 168)),
        Stitch(name: "stitch_48k_44k_64k.mp3", rates: (48000, 44100), frames: (168, 155)),
    ]

    /// Rising zero crossings per second of `channel` over `range` (frames).
    private func pitch(_ pcm: [Float], channels: Int, channel: Int, range: Range<Int>, rate: Double) -> Double {
        var crossings = 0
        var previous = pcm[range.lowerBound * channels + channel]
        for i in (range.lowerBound + 1)..<range.upperBound {
            let sample = pcm[i * channels + channel]
            if previous <= 0, sample > 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) / (Double(range.count) / rate)
    }

    private func rms(_ pcm: [Float], channels: Int, range: Range<Int>) -> Double {
        let slice = pcm[(range.lowerBound * channels)..<(range.upperBound * channels)]
        return (slice.reduce(0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
    }

    /// The output stays at the rate the stream opened with, so the second half of each stitched
    /// fixture is resampled: its length and its pitch come out right instead of its samples being
    /// played at the first half's rate, and nothing the resampler held at the switch is lost (the
    /// length is exact to a few samples, which a dropped resampler tail is not).
    func testSampleRateChangeMidStreamIsResampledToTheOpenRate() throws {
        try skipUnlessAvailable()
        for stitch in stitches {
            let name = stitch.name
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(name)))
            let format = try decoder.open()
            let rate = format.sampleRate
            XCTAssertEqual(rate, stitch.rates.0, name)
            let channels = format.channelCount
            let pcm = decodeAll(decoder)
            XCTAssertEqual(decoder.endReason, .eof, name)

            let frames = pcm.count / channels
            XCTAssertEqual(Double(frames), stitch.expectedFrames, accuracy: 4, "\(name): output length")

            let first = Int(0.5 * rate)..<Int(2.5 * rate)
            let second = (frames - Int(2.5 * rate))..<(frames - Int(0.5 * rate))
            for (range, half) in [(first, "first"), (second, "second")] {
                XCTAssertEqual(pitch(pcm, channels: channels, channel: 0, range: range, rate: rate), 440,
                               accuracy: 2, "\(name): the \(half) half's left pitch")
                XCTAssertEqual(pitch(pcm, channels: channels, channel: 1, range: range, rate: rate), 660,
                               accuracy: 2, "\(name): the \(half) half's right pitch")
            }

            /* Around the switch: the tone's level in 10 ms windows on either side, outside the
             * encoders' own padding and delay (each well under 60 ms). */
            let tone = rms(pcm, channels: channels, range: first)
            let window = Int(0.01 * rate)
            let gap = Int(0.06 * rate)
            for start in [stitch.switchFrame - gap - window, stitch.switchFrame + gap] {
                XCTAssertEqual(rms(pcm, channels: channels, range: start..<(start + window)), tone,
                               accuracy: 0.1 * tone, "\(name): level at frame \(start)")
            }
        }
    }

    /// A seek into the resampled half lands where it says: the audio after it is the clean decode's
    /// at the reported time, once the resampler, started cold at the landing, has warmed up. The
    /// resampler's output grid after a seek is anchored at the landing rather than at the switch,
    /// so the two decodes agree to within a sample, not bit for bit. A frame past the switch is
    /// timed by its byte offset (`mp3_byte_rate_dts`), true to within one byte: 1/8 ms at 64 kbps.
    func testSeekIntoTheResampledHalfLandsWhereItSays() throws {
        try skipUnlessAvailable()
        for stitch in stitches {
            let name = stitch.name
            let url = try Fixture.url(name)
            let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            let format = try clean.open()
            let reference = decodeAll(clean)
            let channels = format.channelCount
            let rate = format.sampleRate

            for target in [4.5, 6.0, 7.25] {
                let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
                _ = try decoder.open()
                let landed = try decoder.seek(toSeconds: target)
                XCTAssertEqual(landed, target, accuracy: 1 / rate, "\(name): seek to \(target)s")
                var after: [Float] = []
                while after.count < 8192 * channels, let chunk = decoder.nextChunk() {
                    after.append(contentsOf: chunk)
                }
                guard after.count >= 8192 * channels else {
                    XCTFail("\(name): seek to \(target)s: only \(after.count / channels) frames after it")
                    continue
                }
                /* Skip a few ms of resampler warm-up, then find the lag (within half the tone's
                 * 1/220 s period) at which the audio best matches the clean decode. */
                let warmup = Int(0.003 * rate)
                let landedFrame = Int((landed * rate).rounded())
                let span = 4096
                var best = (lag: 0, error: Double.infinity)
                for lag in -90...90 {
                    let start = (landedFrame + warmup + lag) * channels
                    guard start >= 0, start + span * channels <= reference.count else { continue }
                    var sum = 0.0
                    for i in 0..<(span * channels) {
                        let d = Double(after[warmup * channels + i]) - Double(reference[start + i])
                        sum += d * d
                    }
                    let error = (sum / Double(span * channels)).squareRoot()
                    if error < best.error { best = (lag, error) }
                }
                let byte = Int((rate / 8000).rounded(.up))   // one byte at 64 kbps, in frames
                XCTAssertLessThanOrEqual(abs(best.lag), byte, "\(name): seek to \(target)s: audio is \(best.lag) frames off")
                XCTAssertLessThan(best.error, 0.05, "\(name): seek to \(target)s: RMS error \(best.error)")
            }
        }
    }

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
    /// used to switch the drop off, so the whole pre-roll (16384 samples here) was played and
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

    // MARK: - The trailing-moov bandwidth trap

    func testMoovLastCostsOneSeekNotTheWholeFile() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.moovLast)
        let fileSize = try Int64(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        XCTAssertGreaterThan(fileSize, 0)

        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        let afterOpen = counting.bytesRead

        var frames = 0
        while frames < Int(format.sampleRate), let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        XCTAssertGreaterThanOrEqual(frames, Int(format.sampleRate))

        /* Without a seek callback FFmpeg read-discards the entire `mdat` to reach the trailing
         * `moov`: on a real 60 MB file that is 60 MB of cellular data before a note is heard.
         *
         * The bound is absolute bytes rather than a share of the file, because on a fixture this
         * small there is no share worth asserting: the 64 KiB probe budget alone is 40% of 161 KB,
         * while on a 60 MB file that same fixed cost is 0.1%. What these numbers pin down is
         * the SHAPE of the transfer — probe, one seek to the end, the moov, nothing else — and a
         * walked mdat blows through every one of them. */
        let probeBudget: Int64 = 64 * 1024      // stream_decode.c sets AVFormatContext.probesize
        let avioBuffer: Int64 = 32 * 1024       // one refill of slack
        let moovSize: Int64 = 4215              // Fixtures/README.md; testMoovLastAtomOrder walks it
        let mdatSize: Int64 = 160_680
        XCTAssertLessThan(counting.bytesRead, probeBudget + avioBuffer + moovSize,
                          "read \(counting.bytesRead) of \(fileSize) bytes — more than probe + moov")
        XCTAssertLessThan(counting.bytesRead, mdatSize,
                          "read \(counting.bytesRead) bytes, more than the mdat: it is being walked")
        let nearEnd = counting.seekOffsets.contains { $0 > fileSize - 64 * 1024 }
        XCTAssertTrue(nearEnd, "no seek to the trailing moov; seeks were \(counting.seekOffsets)")
        print("MOOV-LAST BANDWIDTH: \(counting.bytesRead) of \(fileSize) bytes "
            + "(\(String(format: "%.1f", Double(counting.bytesRead) * 100 / Double(fileSize)))%), "
            + "\(counting.seekOffsets.count) seeks, \(afterOpen) of them in open()")
    }

    // MARK: - The bandwidth traps a real long MP3 has

    /// **A no-Xing CBR MP3 must cost a window to open and a window to seek in, not the file.**
    ///
    /// Most long spoken-word MP3s are exactly this: constant bitrate, no Xing/Info header, and so no
    /// table of contents. libavformat's generic seek has nothing to place a timestamp with, so it
    /// DECODES FORWARD FROM THE START until the timestamps reach the target — measured here before
    /// the fix at 12 MB for one seek to 25 minutes, on a file whose whole open cost 32 KiB.
    /// `stream_decode.c` now caps what a seek may read and falls back to the byte estimate, which
    /// on a constant bitrate is exact.
    func testLargeCBRMP3CostsAWindowToOpenAndToSeek() throws {
        try skipUnlessAvailable()
        let url = try GeneratedFixture.largeCBRMP3()
        let size = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        XCTAssertGreaterThan(size, 8 * 1024 * 1024, "the fixture is meant to be big enough to matter")

        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        XCTAssertEqual(try XCTUnwrap(format.duration), 1800, accuracy: 5, "a CBR MP3's duration comes from its size and bitrate")

        var frames = 0
        while frames < Int(format.sampleRate), let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        XCTAssertGreaterThanOrEqual(frames, Int(format.sampleRate))
        let openCost = counting.bytesRead
        XCTAssertLessThan(openCost, 512 * 1024, "open plus one second of audio read \(openCost) bytes")

        let landed = try decoder.seek(toSeconds: 1500)
        let seekCost = counting.bytesRead - openCost
        XCTAssertLessThan(seekCost, 512 * 1024, "the seek read \(seekCost) bytes — it is walking the file")
        XCTAssertEqual(landed, 1500, accuracy: 2, "landed \(landed)")

        /* And the audio after the seek has to be the audio, not a resync into noise. */
        var after: [Float] = []
        while after.count < Int(format.sampleRate) * format.channelCount, let chunk = decoder.nextChunk() {
            after.append(contentsOf: chunk)
        }
        XCTAssertGreaterThan(after.count, 0, "nothing decoded after the seek")
        let peak = after.dropFirst(Int(format.sampleRate) / 2).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "the post-seek audio is silence, not the tone")
    }

    /// **A VBR MP3 seek is exact as far as a seek's byte budget reaches, and bounded beyond it.**
    ///
    /// A Xing TOC places a time to 1/256 of the file and mp3dec labels the frame it finds with the
    /// time asked for (issue #3). Near a frame of known time the decoder counts frames instead, so
    /// the landing is the requested sample; far from one, the count would walk the file, so the
    /// TOC's landing stands and the seek still costs a window.
    func testXingVBRMP3SeeksExactlyNearAndCheaplyFar() throws {
        try skipUnlessAvailable()
        let url = try GeneratedFixture.xingVBRMP3()
        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        XCTAssertEqual(try XCTUnwrap(format.duration), 300, accuracy: 1)

        /* The audio after the near seek must be the continuous decode's at the same sample. The
         * landed time alone proves nothing: a TOC landing is labelled with the time asked for. At
         * 7 s the TOC lands on its third entry, an estimate; the first frame is within reach. */
        let channels = format.channelCount
        let seconds = 7, at = seconds * Int(format.sampleRate), window = 4096
        var continuous: [Float] = []
        let reference = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try reference.open()
        while continuous.count < (at + window) * channels, let chunk = reference.nextChunk() {
            continuous.append(contentsOf: chunk)
        }
        let near = try decoder.seek(toSeconds: Double(seconds))
        XCTAssertEqual(near, Double(seconds), accuracy: 0.5 / format.sampleRate)
        var afterNear: [Float] = []
        while afterNear.count < window * channels, let chunk = decoder.nextChunk() { afterNear.append(contentsOf: chunk) }
        XCTAssertGreaterThanOrEqual(afterNear.count, window * channels)
        let expected = continuous[(at * channels)..<((at + window) * channels)]
        let worst = zip(afterNear, expected).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4, "the near seek's audio is not the continuous decode's at \(seconds) s")

        let before = counting.bytesRead
        let far = try decoder.seek(toSeconds: 250)
        let seekCost = counting.bytesRead - before
        XCTAssertLessThan(seekCost, 512 * 1024, "the seek read \(seekCost) bytes — it is walking the file")
        XCTAssertEqual(far, 250, accuracy: 5, "landed \(far)")
        XCTAssertNotNil(decoder.nextChunk(), "nothing decoded after the far seek")
    }

    /// **A megabyte-sized ID3v2 tag must be stepped over, not downloaded.**
    ///
    /// `mp3_read_header` parses every APIC frame, so a tag carrying cover art is READ in full
    /// before the demuxer has looked at a single audio frame — and `probesize` does not bound it,
    /// because the tag is consumed before probing starts. Measured on a published 108 MB MP3: a
    /// 13 782 278-byte tag holding a 3000x3000 PNG, and `open()` cost 13.8 MB of cellular data
    /// before a note was heard.
    func testAHugeID3TagIsSteppedOverNotRead() throws {
        try skipUnlessAvailable()
        let tagBytes = 4 * 1024 * 1024
        let url = try GeneratedFixture.mp3BehindID3Tag(bytes: tagBytes)

        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        XCTAssertEqual(format.sampleRate, 44100)
        XCTAssertEqual(try XCTUnwrap(format.duration), 20, accuracy: 0.5, "the duration is the AUDIO's, not the file's")

        var frames = 0
        while frames < Int(format.sampleRate), let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        XCTAssertGreaterThanOrEqual(frames, Int(format.sampleRate))
        XCTAssertLessThan(counting.bytesRead, 256 * 1024,
                          "read \(counting.bytesRead) bytes past a \(tagBytes)-byte tag: the tag is being downloaded")
        XCTAssertTrue(counting.seekOffsets.contains { $0 >= Int64(tagBytes) },
                      "no seek past the tag; seeks were \(counting.seekOffsets)")
    }

    // MARK: - Cancel

    func testCancelUnblocksAStalledRead() throws {
        try skipUnlessAvailable()
        let reader = BlockingByteReader()
        let decoder = FFmpegStreamDecoder(reader: reader)
        let finished = expectation(description: "the decoder returned")

        /* `open()` is the blocking call here — probing needs bytes — so this covers the case that
         * actually strands a listener: tapping play on a dead connection and then tapping back. */
        DispatchQueue.global().async {
            do {
                _ = try decoder.open()
                XCTFail("open() returned on a reader that never delivered a byte")
            } catch {
                XCTAssertNil(decoder.nextChunk())
            }
            finished.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { decoder.cancel() }
        wait(for: [finished], timeout: 2.0)
        XCTAssertEqual(decoder.endReason, .cancelled)
    }

    // MARK: - Interrupt

    /// The seek race, at the decoder. A read parked on a stalled body must come back when the
    /// caller interrupts it, and — the whole difference from a cancel — the decoder must still be
    /// usable: the seek that the interrupt was for runs on it and audio keeps coming.
    func testInterruptEndsTheReadButNotTheDecoder() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let reader = try StallingFileByteReader(url: url, stallAfterBytes: 64 * 1024)
        let decoder = FFmpegStreamDecoder(reader: reader)
        _ = try decoder.open()

        let blocked = expectation(description: "the pull loop returned nil")
        DispatchQueue.global().async {
            while decoder.nextChunk() != nil {}
            blocked.fulfill()
        }
        /* Interrupt only once a read is actually parked in the stall: interrupting before that
         * would prove nothing about a blocked call coming back. */
        let deadline = Date().addingTimeInterval(5)
        while !reader.isStalled, Date() < deadline { usleep(2000) }
        XCTAssertTrue(reader.isStalled, "the reader never reached the stall")
        decoder.interrupt()
        wait(for: [blocked], timeout: 5.0)

        XCTAssertEqual(decoder.endReason, .interrupted, "an interrupt must not read as EOF or a cancel")
        let landed = try decoder.seek(toSeconds: 5)
        XCTAssertEqual(landed, 5, accuracy: 1.0)
        XCTAssertEqual(decoder.endReason, .running, "the seek did not clear the interruption")
        XCTAssertNotNil(decoder.nextChunk(), "the decoder produced nothing after an interrupted read")
    }

    /// A seek that arrives while the stream is still opening interrupts the open. That has to
    /// throw `.interrupted`, never `.failed`: a caller answers `.failed` with its fallback
    /// player, as if the format were unsupported. Stalls in the ID3 probe (0), in libavformat's
    /// first read (10, past the ID3 header) and, where the open reads that far, deeper in its probe.
    func testInterruptDuringOpenThrowsInterruptedNotFailed() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            for stallAfter: Int64 in [0, 10, 40 * 1024] {
                let reader = try StallingFileByteReader(url: try Fixture.url(name), stallAfterBytes: stallAfter)
                let decoder = FFmpegStreamDecoder(reader: reader)
                var thrown: Error?
                var opened = false
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    do { _ = try decoder.open(); opened = true } catch { thrown = error }
                    done.signal()
                }
                let deadline = Date().addingTimeInterval(5)
                var finished = false
                while !reader.isStalled, !finished, Date() < deadline {
                    finished = done.wait(timeout: .now() + 0.002) == .success
                }
                guard !finished, reader.isStalled else {
                    if !finished { _ = done.wait(timeout: .now() + 5) }
                    /* The open needed fewer bytes than the stall point: nothing to interrupt. */
                    XCTAssertTrue(opened, "\(name) @\(stallAfter): open neither stalled nor succeeded")
                    XCTAssertGreaterThan(stallAfter, 10, "\(name): every open reads past its first 10 bytes")
                    continue
                }
                decoder.interrupt()
                XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "\(name) @\(stallAfter): open never returned")
                XCTAssertFalse(opened, "\(name) @\(stallAfter): an interrupted open reported success")
                XCTAssertEqual(thrown as? StreamDecoderError, .interrupted, "\(name) @\(stallAfter): got \(String(describing: thrown))")
                XCTAssertEqual(decoder.endReason, .interrupted, "\(name) @\(stallAfter)")
            }
        }
    }

    // MARK: - No Content-Length

    /// A seek into a chunked body whose connection broke is NOT the end of the stream: libavformat
    /// reports the broken read as end of file, and only the reader knows otherwise. (A seek past
    /// the real end of a length-less source is end of stream; the conformance suite's seek to the
    /// end under `unknownLength` holds that.)
    func testUnknownLengthSeekIntoATruncatedBodyIsNotEOF() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let size = try XCTUnwrap(try FileByteReader(url: url).totalLength)
        let decoder = FFmpegStreamDecoder(reader: try TruncatedFileByteReader(url: url, cutoff: size / 2))
        _ = try decoder.open()
        do {
            _ = try decoder.seek(toSeconds: 25)
            XCTFail("a seek into a broken body succeeded with endReason \(decoder.endReason)")
        } catch {
            XCTAssertEqual(error as? StreamDecoderError, .failed(status: Int32(STREAM_DECODE_ERR_SEEK.rawValue)))
        }
        XCTAssertNotEqual(decoder.endReason, .eof, "a truncated body read as the end of the stream")
    }

    func testUnknownLengthStillDecodesMP3() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        /* A chunked response with no `Content-Length`: `AVSEEK_SIZE` must answer "unknown", and
         * MP3 must not care — its duration comes from the Xing header, not from the file size. */
        let reader = try FileByteReader(url: url, reportsTotalLength: false)
        XCTAssertNil(reader.totalLength)
        let decoder = FFmpegStreamDecoder(reader: reader)
        let format = try decoder.open()
        XCTAssertEqual(format.sampleRate, 44100)
        /* The Xing duration survives a length-less source: stock n7.1 mp3dec discarded the tag
         * when `avio_size()` could not answer, which scripts/ffmpeg-patches/0001 fixes (issue #1). */
        XCTAssertEqual(try XCTUnwrap(format.duration), 20, accuracy: 0.1, "the Xing frame count gives the duration")
        let pcm = decodeAll(decoder)
        XCTAssertEqual(Double(pcm.count / format.channelCount), 44100 * 20, accuracy: 4096)
        XCTAssertEqual(decoder.endReason, .eof)
    }

    // MARK: - Refusals

    func testGarbageInputFailsRatherThanHangs() throws {
        try skipUnlessAvailable()
        var bytes = Data(count: 96 * 1024)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            var seed: UInt64 = 0x5EED
            for i in 0..<raw.count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                p[i] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        let decoder = FFmpegStreamDecoder(reader: DataByteReader(bytes))
        XCTAssertThrowsError(try decoder.open()) { error in
            guard case StreamDecoderError.failed = error else {
                return XCTFail("expected a decode failure, got \(error)")
            }
        }
        XCTAssertEqual(decoder.endReason, .failure)
        XCTAssertNil(decoder.nextChunk())
    }

    // MARK: - Probe budget

    /// The Swift default and the C fallback (used when a field is zero, or by `stream_decoder_open`)
    /// are two spellings of one number. If they drift, a caller passing `.default` probes
    /// differently from one that passes nothing.
    func testDefaultProbeBudgetMatchesTheCFallback() {
        XCTAssertEqual(StreamProbeBudget.default.bytes, 64 * 1024)
        XCTAssertEqual(StreamProbeBudget.default.analyzeDuration, 1)
        #if canImport(CStreamDecode)
            XCTAssertEqual(StreamProbeBudget.default.bytes, Int64(STREAM_DECODE_DEFAULT_PROBE_BYTES))
            XCTAssertEqual(
                Int64(StreamProbeBudget.default.analyzeDuration * 1_000_000),
                Int64(STREAM_DECODE_DEFAULT_MAX_ANALYZE_US)
            )
        #endif
    }

    /// A caller-chosen budget reaches the decoder: a generous one still opens every fixture, and
    /// the result matches the default's.
    func testCustomProbeBudgetOpens() throws {
        try skipUnlessAvailable()
        let budget = StreamProbeBudget(bytes: 1024 * 1024, analyzeDuration: 5)
        for name in Fixture.all {
            let url = try Fixture.url(name)
            let custom = try FFmpegStreamDecoder(reader: try FileByteReader(url: url), probeBudget: budget).open()
            let standard = try FFmpegStreamDecoder(reader: try FileByteReader(url: url)).open()
            XCTAssertEqual(custom.sampleRate, standard.sampleRate, "\(name)")
            XCTAssertEqual(custom.channelCount, standard.channelCount, "\(name)")
            XCTAssertEqual(try XCTUnwrap(custom.duration), try XCTUnwrap(standard.duration), accuracy: 0.01, "\(name)")
        }
    }

    // MARK: - Helpers

    /// Top-level MP4 atom types, in file order.
    private func atomOrder(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var order: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            order.append(type)
            guard size >= 8 else { break }
            offset += Int(size)
        }
        return order
    }
}
