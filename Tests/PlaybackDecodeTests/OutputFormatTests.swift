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
