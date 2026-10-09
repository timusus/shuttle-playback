import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

extension StreamDecodeTests {
    // MARK: - Mid-stream format change

    /// A stitched fixture: 4 s of 440 Hz left / 660 Hz right at one rate glued to 4 s of the same
    /// tone at another, each half `frames` MP3 frames of 1,152 samples (no Xing tag, so nothing is
    /// trimmed).
    struct Stitch {
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

    // MARK: - Chained Ogg

    /// Two Ogg streams concatenated byte for byte, 3 s each (`make-fixtures.sh`, last section): a
    /// chain boundary brings new headers and, here, a new rate or channel count. The output stays at
    /// the first stream's format, so the second stream is resampled or remixed to it.
    struct Chain {
        let name: String
        let rates: (Double, Double)
        let channels: (Int, Int)
        /// Where the second stream starts, in seconds of output.
        let switchSeconds = 3.0
        /// Encoder priming and padding at the boundary and the end, in output frames. The ffmpeg
        /// Vorbis encoder pads each stream by up to ~1,000 frames; Opus is trimmed by its pre-skip.
        let slack: Double
        /// The second stream's RMS over the first's at the open format. Stereo to mono is swresample's
        /// default downmix, (L + R) / sqrt(2): two unrelated tones at the mono tone's amplitude come
        /// out at its level (not the Opus codec's own 0.5 x (L + R), #49).
        let secondLevel: Double
    }


    func testChainedOggDecodesBothStreamsAtTheOpenFormat() throws {
        try skipUnlessAvailable()
        for chain in chains {
            let name = chain.name
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(name)))
            let format = try decoder.open()
            XCTAssertEqual(format.sampleRate, chain.rates.0, name)
            XCTAssertEqual(format.channelCount, chain.channels.0, name)
            let pcm = decodeAll(decoder)
            XCTAssertEqual(decoder.endReason, .eof, name)
            XCTAssertEqual(pcm.count % format.channelCount, 0, "\(name): whole frames only")

            let frames = pcm.count / format.channelCount
            XCTAssertEqual(Double(frames), 6 * format.sampleRate, accuracy: chain.slack, "\(name): both streams, 3 s each")
            XCTAssertEqual(decoder.mediaFramesRead, Int64(frames), name)

            /* Both halves carry sound at the open rate: the second is not silent, dropped, or played
             * at the wrong speed (the Vorbis pair's left channel is 440 Hz throughout). */
            let rate = format.sampleRate
            let channels = format.channelCount
            let first = Int(0.5 * rate)..<Int(2.5 * rate)
            let second = Int(3.5 * rate)..<Int(5.5 * rate)
            let expected = rms(pcm, channels: channels, range: first)
            XCTAssertGreaterThan(expected, 0.1, "\(name): first half is audible")
            XCTAssertEqual(rms(pcm, channels: channels, range: second), expected * chain.secondLevel,
                           accuracy: 0.05 * expected, "\(name): second half's level")
            if chain.channels.0 == 2 {
                /* The right channel's crossings are counted looser: at 48 kbps the Vorbis encoder
                 * leaves a few extra ones on the 660 Hz tone. */
                for range in [first, second] {
                    XCTAssertEqual(pitch(pcm, channels: 2, channel: 0, range: range, rate: rate), 440, accuracy: 2, name)
                    XCTAssertEqual(pitch(pcm, channels: 2, channel: 1, range: range, rate: rate), 660, accuracy: 8, name)
                }
            }
        }
    }

    /// The Opus chain's boundary: no packet dropped or repeated, no pre-skip left in or cut
    /// twice. Each link is 3 s of 48 kHz input; libopus writes its pre-skip (312 samples) in the
    /// header and the Ogg end granule says where the audio ends, so FFmpeg trims the pre-skip off
    /// the start and the padding off the end and each link decodes to exactly 144,000 frames.
    /// A lost or repeated 20 ms packet (960 frames) or an untrimmed pre-skip would change that.
    /// The first link is mono, so the output is mono; the second link is 440 Hz left and 660 Hz
    /// right, downmixed by (L + R) / sqrt(2), and is compared against that sum from its first frame.
    func testChainedOpusBoundaryHasNoDroppedOrRepeatedAudio() throws {
        try skipUnlessAvailable()
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url("chained_opus_mono_stereo.opus")))
        let format = try decoder.open()
        XCTAssertEqual(format.channelCount, 1)
        let pcm = decodeAll(decoder)
        XCTAssertEqual(pcm.count, 288_000, "two links of exactly 3 s")

        /* No silent gap at the boundary: the longest run of near-zero samples in 2.9 to 3.1 s is
         * only a tone's zero crossing (a few samples), not a lost packet or a pre-skip of silence. */
        var longest = 0, run = 0
        for i in 139_200..<148_800 {
            if abs(pcm[i]) < 0.005 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        XCTAssertLessThan(longest, 48, "gap of \(longest) near-silent frames at the boundary")

        /* The second link, from its first frame, matches the two tones it was made from; the same
         * comparison shifted by a packet or the pre-skip does not. */
        func error(shift: Int) -> Double {
            var sum = 0.0
            let count = 9_600
            for i in 0..<count {
                let t = Double(i) / 48_000
                let want = 0.7 * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 660 * t)) / 2.0.squareRoot()
                let d = Double(pcm[144_000 + shift + i]) - want
                sum += d * d
            }
            return (sum / Double(count)).squareRoot()
        }
        XCTAssertLessThan(error(shift: 0), 0.05, "second link's tones are phase-continuous from its start")
        XCTAssertGreaterThan(error(shift: 312), 0.2, "(control) a pre-skip's shift is visible to this check")
    }

    /// A fixed output format at a rate and channel count neither stream has still gets both streams
    /// at that format, at the length they have.
    func testChainedOggUnderASetOutputFormat() throws {
        try skipUnlessAvailable()
        for chain in chains {
            let name = chain.name
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(name)))
            _ = try decoder.open()
            try decoder.setOutputFormat(sampleRate: 32000, channelCount: 2)
            let pcm = decodeAll(decoder)
            XCTAssertEqual(decoder.endReason, .eof, name)
            XCTAssertEqual(pcm.count % 2, 0, name)
            XCTAssertEqual(Double(pcm.count / 2), 6 * 32000, accuracy: chain.slack * 32000 / 44100, "\(name): output length")

            /* The second stream is stereo, 440 Hz left / 660 Hz right, whatever the first was (#49: not
             * its mono downmix on both channels after a mono stream). */
            XCTAssertEqual(pitch(pcm, channels: 2, channel: 0, range: 112_000..<176_000, rate: 32000), 440,
                           accuracy: 2, "\(name): the second stream's left pitch")
            XCTAssertEqual(pitch(pcm, channels: 2, channel: 1, range: 112_000..<176_000, rate: 32000), 660,
                           accuracy: 8, "\(name): the second stream's right pitch")
        }
    }

    /// A seek into either half lands where it says: the audio after it is the clean decode's at the
    /// reported time, once the resampler, started cold at the landing, has warmed up.
    func testSeekIntoEitherHalfOfAChainedOggLandsWhereItSays() throws {
        try skipUnlessAvailable()
        for chain in chains {
            let name = chain.name
            let url = try Fixture.url(name)
            let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            let format = try clean.open()
            let reference = decodeAll(clean)
            let channels = format.channelCount
            let rate = format.sampleRate

            func check(_ target: Double, framesBroken: Bool, landingBroken: Bool = false) throws {
                let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
                _ = try decoder.open()
                let landed = try decoder.seek(toSeconds: target)
                let landing = {
                    XCTAssertEqual(landed, target, accuracy: 1 / rate, "\(name): seek to \(target)s")
                }
                if landingBroken {
                    XCTExpectFailure("#48: a seek in a chained Ogg lands at the first stream's end", failingBlock: landing)
                } else {
                    landing()
                }
                let after = decodeAll(decoder)
                /* Reading on from the landing reaches the end of the second stream, not the first's.
                 * #48: after a seek past the first stream's end it does not. */
                let frames = {
                    XCTAssertEqual(Double(after.count / channels), (6 - landed) * rate, accuracy: chain.slack,
                                   "\(name): seek to \(target)s: frames after it")
                }
                if framesBroken {
                    XCTExpectFailure("#48: a seek in a chained Ogg never reaches the second stream", failingBlock: frames)
                } else {
                    frames()
                }
                guard after.count >= 8192 * channels else { return }
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
                XCTAssertLessThanOrEqual(abs(best.lag), 1, "\(name): seek to \(target)s: audio is \(best.lag) frames off")
                XCTAssertLessThan(best.error, 0.05, "\(name): seek to \(target)s: RMS error \(best.error)")
            }

            for target in [0.5, 1.5] { try check(target, framesBroken: false) }
            /* #48: a seek in the first stream's later part or the second stream never gets past the
             * first stream's end. */
            for target in [2.5, 3.4, 4.5, 5.5] {
                try check(target, framesBroken: true, landingBroken: target > 3)
            }
        }
    }

}
