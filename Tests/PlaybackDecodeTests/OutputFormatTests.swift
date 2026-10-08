import Foundation
import XCTest

@testable import PlaybackDecode

/// A fixed output format (`setOutputFormat`) and the buffer-filling `read(into:maxFrames:)` (#20).
///
/// What a player running one graph at one format across tracks relies on: the audio comes out at
/// the asked rate with its length and pitch intact, remixed to the asked channel count, a seek still
/// lands where it says, and the buffer read hands out exactly what `nextChunk` does.
final class OutputFormatTests: XCTestCase {

    private func skipUnlessAvailable() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    /// 8 kHz mono MPEG 2.5, from the conformance fixtures (read by path, as the conformance suite
    /// reads them). The only mono source the tests have.
    private func monoFixture() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/mpeg25_8k_mono.mp3")
    }

    private func decoder(_ url: URL, rate: Double? = nil, channels: Int? = nil) throws -> (FFmpegStreamDecoder, StreamAudioFormat) {
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try decoder.open()
        if rate != nil || channels != nil {
            try decoder.setOutputFormat(sampleRate: rate ?? format.sampleRate, channelCount: channels ?? format.channelCount)
        }
        return (decoder, format)
    }

    private func decodeAll(_ decoder: FFmpegStreamDecoder) -> [Float] {
        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm.append(contentsOf: chunk) }
        return pcm
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

    // MARK: - Resample

    /// 44.1 kHz out at 48 kHz: as many frames as the native decode times 48/44.1, to a frame, and the
    /// tones at their own pitch (a resampler that merely relabelled the rate would play them sharp).
    func testResamplingTo48kKeepsLengthAndPitch() throws {
        try skipUnlessAvailable()
        for name in [Fixture.mp3, Fixture.moovFirst] {
            let url = try Fixture.url(name)
            let (native, format) = try decoder(url)
            let nativeFrames = decodeAll(native).count / format.channelCount

            let (resampled, _) = try decoder(url, rate: 48000)
            let pcm = decodeAll(resampled)
            XCTAssertEqual(resampled.endReason, .eof, name)
            let frames = pcm.count / format.channelCount
            XCTAssertEqual(Double(frames), Double(nativeFrames) * 48000 / format.sampleRate, accuracy: 1,
                           "\(name): output length")
            XCTAssertEqual(resampled.mediaFramesRead, Int64(frames), name)

            let range = 48000..<(3 * 48000)
            XCTAssertEqual(pitch(pcm, channels: 2, channel: 0, range: range, rate: 48000), 440, accuracy: 1,
                           "\(name): left pitch")
            XCTAssertEqual(pitch(pcm, channels: 2, channel: 1, range: range, rate: 48000), 660, accuracy: 1,
                           "\(name): right pitch")
        }
    }

    // MARK: - Remix

    /// Stereo to mono is swresample's default downmix: both sides at -3 dB, summed (float output is
    /// not renormalised).
    func testStereoToMonoIsTheDefaultDownmix() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let (stereo, _) = try decoder(url)
        let reference = decodeAll(stereo)
        let (mono, _) = try decoder(url, channels: 1)
        let pcm = decodeAll(mono)
        XCTAssertEqual(pcm.count, reference.count / 2)
        var worst: Float = 0
        for i in 0..<min(pcm.count, reference.count / 2) {
            let expected = (reference[2 * i] + reference[2 * i + 1]) * Float(0.5.squareRoot())
            worst = max(worst, abs(pcm[i] - expected))
        }
        XCTAssertLessThan(worst, 1e-5, "mono differs from (L+R)/sqrt(2) by \(worst)")
    }

    /// Mono to stereo duplicates the one channel to both sides at full level, at the source rate and
    /// through a resample.
    func testMonoToStereoDuplicatesAtFullLevel() throws {
        try skipUnlessAvailable()
        let url = monoFixture()
        let (native, format) = try decoder(url)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.sampleRate, 8000)
        let mono = decodeAll(native)
        XCTAssertFalse(mono.isEmpty)

        let (spread, _) = try decoder(url, channels: 2)
        let stereo = decodeAll(spread)
        XCTAssertEqual(stereo.count, mono.count * 2)
        var worst: Float = 0
        for i in 0..<min(mono.count, stereo.count / 2) {
            worst = max(worst, abs(stereo[2 * i] - mono[i]), abs(stereo[2 * i + 1] - mono[i]))
        }
        XCTAssertLessThan(worst, 1e-6, "stereo sides differ from the mono channel by \(worst)")

        let (resampled, _) = try decoder(url, rate: 48000, channels: 2)
        let up = decodeAll(resampled)
        XCTAssertEqual(Double(up.count / 2), Double(mono.count) * 6, accuracy: 1, "output length")
        XCTAssertTrue(stride(from: 0, to: up.count, by: 2).allSatisfy { up[$0] == up[$0 + 1] },
                      "both sides identical")
    }

    /// A stream opened as stereo that turns mono mid-way (`stitch_stereo_mono_64k.mp3`, see the
    /// fixtures README) comes out of the explicit mono matrix at full level on both channels: the
    /// mono half is as loud on each side as the stereo half's left channel, not 3 dB down as
    /// swresample's default mono matrix would have it. Default output format, no `setOutputFormat`.
    func testStereoToMonoSwitchMidStreamComesOutAtFullLevelOnBothChannels() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url("stitch_stereo_mono_64k.mp3")
        let (decoder, format) = try decoder(url)
        XCTAssertEqual(format.channelCount, 2)
        let pcm = decodeAll(decoder)
        let frames = pcm.count / 2
        XCTAssertEqual(Double(frames), 8 * format.sampleRate, accuracy: 4 * 1152, "output length")

        func rms(_ channel: Int, _ range: Range<Int>) -> Double {
            (range.reduce(0.0) { $0 + Double(pcm[$1 * 2 + channel]) * Double(pcm[$1 * 2 + channel]) }
                / Double(range.count)).squareRoot()
        }
        let rate = Int(format.sampleRate)
        let stereoLeft = rms(0, rate..<(3 * rate))
        let monoLeft = rms(0, (5 * rate)..<(7 * rate))
        let monoRight = rms(1, (5 * rate)..<(7 * rate))
        XCTAssertEqual(stereoLeft, 0.5 / 2.0.squareRoot(), accuracy: 0.03, "stereo half level")
        XCTAssertEqual(monoLeft, stereoLeft, accuracy: 0.01, "mono half, left: \(monoLeft) vs \(stereoLeft)")
        XCTAssertEqual(monoRight, stereoLeft, accuracy: 0.01, "mono half, right: \(monoRight) vs \(stereoLeft)")
        XCTAssertTrue((5 * rate..<(7 * rate)).allSatisfy { abs(pcm[$0 * 2] - pcm[$0 * 2 + 1]) < 1e-6 },
                      "both sides of the mono half are identical")
    }

    // MARK: - Seek

    /// A seek at a non-native output rate lands where it says: the landed time is the media time it
    /// is at the source rate, the frame count follows it at the output rate, and the audio after it
    /// is the clean decode's at that frame once the resampler, started cold at the landing, has
    /// warmed up. Both decodes are at 48 kHz.
    ///
    /// Within a frame, not bit for bit: the resampler's output grid after a seek starts at the
    /// landing frame, not at the start of the stream, so it can sit up to half an output frame off
    /// the clean decode's. On these tones (0.7 peak, 660 Hz at most) that is an RMS difference of
    /// at most 2π · 660 · (0.5 / 48000) · 0.7 / √2 ≈ 0.02.
    func testSeekAtANonNativeRateLandsWhereItSays() throws {
        try skipUnlessAvailable()
        let rate = 48000.0
        for name in [Fixture.mp3, Fixture.moovFirst] {
            let url = try Fixture.url(name)
            let (clean, format) = try decoder(url, rate: rate)
            let reference = decodeAll(clean)
            let channels = format.channelCount

            for target in [1.0, 7.3, 12.77] {
                let (seeking, _) = try decoder(url, rate: rate)
                let landed = try seeking.seek(toSeconds: target)
                XCTAssertEqual(landed, target, accuracy: 1 / format.sampleRate, "\(name): seek to \(target)s")
                let landedFrame = Int((landed * rate).rounded())
                XCTAssertEqual(seeking.mediaFramesRead, Int64(landedFrame), "\(name): seek to \(target)s")

                var after: [Float] = []
                while after.count < 8192 * channels, let chunk = seeking.nextChunk() {
                    after.append(contentsOf: chunk)
                }
                guard after.count >= 8192 * channels else {
                    XCTFail("\(name): seek to \(target)s: only \(after.count / channels) frames after it")
                    continue
                }
                let warmup = Int(0.005 * rate)
                let span = 4096
                var best = (lag: 0, error: Double.infinity)
                for lag in -16...16 {
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
                XCTAssertLessThan(best.error, 0.02, "\(name): seek to \(target)s: RMS error \(best.error)")
            }
        }
    }

    /// The MP4 edit list's end clip (#13) holds at a non-native output rate: `aac_edit_list.m4a`
    /// (from the conformance fixtures) at 48 kHz has the clipped duration × 48000 frames, to a
    /// frame, and a seek past its end lands on that clipped end with nothing left to read.
    func testEditListEndClipHoldsAtANonNativeRate() throws {
        try skipUnlessAvailable()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/aac_edit_list.m4a")
        let rate = 48000.0
        let (native, format) = try decoder(url)
        let nativeFrames = decodeAll(native).count / format.channelCount
        XCTAssertNotEqual(format.sampleRate, rate)
        let clipped = Double(nativeFrames) / format.sampleRate
        let expected = clipped * rate

        let (resampled, _) = try decoder(url, rate: rate)
        let frames = decodeAll(resampled).count / format.channelCount
        XCTAssertEqual(resampled.endReason, .eof)
        XCTAssertEqual(Double(frames), expected, accuracy: 1, "total frames at 48 kHz")

        for target in [clipped + 0.5, 1e6] {
            let (seeking, _) = try decoder(url, rate: rate)
            let landed = try seeking.seek(toSeconds: target)
            XCTAssertEqual(landed, clipped, accuracy: 1 / rate, "seek to \(target)s landed \(landed)s")
            XCTAssertEqual(Double(seeking.mediaFramesRead), expected, accuracy: 1, "seek to \(target)s: frames read")
            XCTAssertTrue(decodeAll(seeking).isEmpty, "PCM after a seek to \(target)s")
        }
    }

    // MARK: - read(into:maxFrames:)

    /// The buffer read hands out exactly the samples `nextChunk` does, at any `maxFrames` (one
    /// frame, odd sizes that split the codec's frames, more than a chunk), at the source's format and
    /// at a fixed one, and after a seek.
    func testReadIntoMatchesNextChunk() throws {
        try skipUnlessAvailable()
        let sizes = [1, 7, 333, 1152, 4096, 5000]
        let url = try Fixture.url(Fixture.mp3)
        for (rate, channels) in [(nil, nil), (48000.0, 2), (22050.0, 1)] as [(Double?, Int?)] {
            for seekTo in [nil, 3.3] as [Double?] {
                let label = "rate \(rate.map { "\($0)" } ?? "native"), channels \(channels.map { "\($0)" } ?? "native"), seek \(seekTo.map { "\($0)" } ?? "none")"
                let (chunked, format) = try decoder(url, rate: rate, channels: channels)
                if let seekTo { try chunked.seek(toSeconds: seekTo) }
                let expected = decodeAll(chunked)
                XCTAssertEqual(chunked.endReason, .eof, label)

                let (reading, _) = try decoder(url, rate: rate, channels: channels)
                if let seekTo { try reading.seek(toSeconds: seekTo) }
                let outChannels = channels ?? format.channelCount
                var buffer = [Float](repeating: .nan, count: 5000 * outChannels)
                var got: [Float] = []
                var call = 0
                while true {
                    let maxFrames = sizes[call % sizes.count]
                    call += 1
                    let frames = buffer.withUnsafeMutableBufferPointer {
                        reading.read(into: $0.baseAddress!, maxFrames: maxFrames)
                    }
                    XCTAssertLessThanOrEqual(frames, maxFrames, label)
                    if frames == 0 { break }
                    got.append(contentsOf: buffer[0..<(frames * outChannels)])
                }
                XCTAssertEqual(reading.endReason, .eof, label)
                XCTAssertEqual(got.count, expected.count, label)
                XCTAssertTrue(got == expected, "\(label): samples differ")
                XCTAssertEqual(reading.mediaFramesRead, chunked.mediaFramesRead, label)
            }
        }
    }

    // MARK: - 5.1 downmix (#47)

    /// RMS of one channel of stereo `pcm` over `range` (frames).
    private func rms(_ pcm: [Float], range: Range<Int>, channel: Int) -> Double {
        let sum = range.reduce(0.0) { $0 + Double(pcm[$1 * 2 + channel]) * Double(pcm[$1 * 2 + channel]) }
        return (sum / Double(range.count)).squareRoot()
    }

    /// Magnitude of `channel` at `frequency` over `range` (frames): a single-bin DFT, the sine's amplitude.
    private func amplitude(_ pcm: [Float], channels: Int, channel: Int, frequency: Double, range: Range<Int>, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for i in range {
            let phase = 2 * Double.pi * frequency * Double(i) / rate
            let sample = Double(pcm[i * channels + channel])
            re += sample * cos(phase)
            im -= sample * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(range.count)
    }

    /// `flac_51_48k.flac`: FL 220, FR 330, FC 440, LFE 550, BL 660, BR 770 Hz, each 0.15. Decoded to
    /// stereo, it is swresample's default 5.1 matrix: the front channel at 1, the centre and the back
    /// channel on its side at 1/sqrt(2) (-3 dB; `center_mix_level` and `surround_mix_level`), the LFE not
    /// at all (`lfe_mix_level` 0). With Float32 output swresample does not scale the matrix down to keep
    /// a full-scale sum under 1.0 (`rematrix_maxval` is unbounded), so a tone's amplitude in the output
    /// is 0.15 for the front channel and 0.15 / sqrt(2) = 0.106 for the centre and the back channel,
    /// and the other side's and the LFE's tones are absent. (Full scale on every channel sums to 2.414.)
    func testFiveOneDownmixesToStereoWithSwresamplesDefaultMatrix() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url("flac_51_48k.flac")
        let (native, format) = try decoder(url)
        XCTAssertEqual(format.channelCount, 6)
        XCTAssertEqual(decodeAll(native).count, 6 * 48000, "six channels at the source rate, untouched")

        let front = 0.15
        let side = front / 2.0.squareRoot()
        let tones: [(hz: Double, left: Double, right: Double)] = [
            (220, front, 0), (330, 0, front), (440, side, side), (550, 0, 0), (660, side, 0), (770, 0, side),
        ]
        for rate in [48000.0, 44100.0] {
            let (stereo, _) = try decoder(url, rate: rate, channels: 2)
            let pcm = decodeAll(stereo)
            XCTAssertEqual(stereo.endReason, .eof)
            XCTAssertEqual(Double(pcm.count / 2), rate, accuracy: 1, "\(rate): one second")
            /* Half a second from a quarter in: a whole number of periods of every tone, clear of the
             * resampler's edges. */
            let range = Int(rate / 4)..<Int(rate * 3 / 4)
            for tone in tones {
                for (channel, expected) in [(0, tone.left), (1, tone.right)] {
                    XCTAssertEqual(amplitude(pcm, channels: 2, channel: channel, frequency: tone.hz, range: range, rate: rate),
                                   expected, accuracy: 0.003, "\(rate): \(tone.hz) Hz in channel \(channel)")
                }
            }
        }
    }

    // MARK: - 192 kHz / 24-bit (#47)

    /// `flac_192k_24bit.flac`, 0.5 s: decoded at its own rate, at 48 kHz, and sought. FLAC is lossless
    /// and the seek finds a frame by its headers, so the source-rate seek is bit-exact.
    func testHighSampleRateDecodesAtTheSourceRateAndAt48k() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url("flac_192k_24bit.flac")
        let (native, format) = try decoder(url)
        XCTAssertEqual(format.sampleRate, 192000)
        XCTAssertEqual(format.channelCount, 2)
        let reference = decodeAll(native)
        XCTAssertEqual(native.endReason, .eof)
        XCTAssertEqual(reference.count, 2 * 96000, "0.5 s at 192 kHz")
        XCTAssertEqual(pitch(reference, channels: 2, channel: 0, range: 9600..<86400, rate: 192000), 440, accuracy: 4)
        XCTAssertEqual(pitch(reference, channels: 2, channel: 1, range: 9600..<86400, rate: 192000), 660, accuracy: 4)

        let (down, _) = try decoder(url, rate: 48000)
        let pcm = decodeAll(down)
        XCTAssertEqual(down.endReason, .eof)
        XCTAssertEqual(pcm.count / 2, 24000, "0.5 s at 48 kHz")
        XCTAssertEqual(down.mediaFramesRead, 24000)
        let range = 2400..<21600
        XCTAssertEqual(pitch(pcm, channels: 2, channel: 0, range: range, rate: 48000), 440, accuracy: 4)
        XCTAssertEqual(pitch(pcm, channels: 2, channel: 1, range: range, rate: 48000), 660, accuracy: 4)
        XCTAssertEqual(rms(pcm, range: range, channel: 0), rms(reference, range: 9600..<86400, channel: 0), accuracy: 0.01,
                       "the level survives the resample")
    }

    func testHighSampleRateSeeksExactly() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url("flac_192k_24bit.flac")
        let (clean, _) = try decoder(url)
        let reference = decodeAll(clean)

        for target in [0.1, 0.25, 0.4] {
            let (seeker, _) = try decoder(url)
            let landed = try seeker.seek(toSeconds: target)
            XCTAssertEqual(landed, target, accuracy: 1 / 192000, "seek to \(target)s")
            let after = decodeAll(seeker)
            let start = Int((landed * 192000).rounded())
            XCTAssertEqual(after.count, reference.count - 2 * start, "seek to \(target)s: frames after it")
            XCTAssertTrue(after.elementsEqual(reference[(2 * start)...]), "seek to \(target)s: the clean decode's audio from there")
        }

        /* At 48 kHz the landing is on the 48 kHz grid and the audio from it is the clean 48 kHz decode's. */
        let (down, _) = try decoder(url, rate: 48000)
        let downReference = decodeAll(down)
        let (seeker, _) = try decoder(url, rate: 48000)
        let landed = try seeker.seek(toSeconds: 0.25)
        XCTAssertEqual(landed, 0.25, accuracy: 1 / 48000)
        let after = decodeAll(seeker)
        XCTAssertEqual(Double(after.count / 2), 12000, accuracy: 2)
        XCTAssertEqual(rms(after, range: 200..<2000, channel: 0), rms(downReference, range: 12200..<14000, channel: 0), accuracy: 0.01)
    }

    // MARK: - When it may be called

    func testOutputFormatIsFixedOnceAudioHasBeenReadOrSought() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)

        let unopened = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        XCTAssertThrowsError(try unopened.setOutputFormat(sampleRate: 48000, channelCount: 2))

        let (bad, _) = try decoder(url)
        XCTAssertThrowsError(try bad.setOutputFormat(sampleRate: 48000, channelCount: 0))
        XCTAssertThrowsError(try bad.setOutputFormat(sampleRate: 0, channelCount: 2))
        XCTAssertThrowsError(try bad.setOutputFormat(sampleRate: .infinity, channelCount: 2))

        /* Set twice before the first read: the last one wins. */
        let (twice, _) = try decoder(url, rate: 22050, channels: 1)
        try twice.setOutputFormat(sampleRate: 48000, channelCount: 2)
        let chunk = try XCTUnwrap(twice.nextChunk())
        XCTAssertEqual(chunk.count, FFmpegStreamDecoder.framesPerChunk * 2)
        XCTAssertThrowsError(try twice.setOutputFormat(sampleRate: 44100, channelCount: 2)) { error in
            guard case StreamDecoderError.invalidState = error else { return XCTFail("\(error)") }
        }
        XCTAssertNotNil(twice.nextChunk(), "a refused change leaves the decoder decoding")

        let (sought, _) = try decoder(url)
        try sought.seek(toSeconds: 2)
        XCTAssertThrowsError(try sought.setOutputFormat(sampleRate: 48000, channelCount: 2))
    }
}
