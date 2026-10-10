import Accelerate
import Foundation
import XCTest

@testable import PlaybackDecode

/// Where each decoded frame came from, for the lossy codecs whose encoders add frames: AAC in MP4,
/// MP3 and Opus. Each fixture is 2 s of a mono linear chirp (see `make-fixtures.sh`):
///
///     x(n) = 0.5 sin(2π (300 t + 675 t²)),  t = n / rate
///
/// Its phase is different at every sample, so cross-correlating a window of decoded audio with the
/// formula finds the source frame the window starts at, to the sample, whatever the codec did to
/// the waveform and with no reference decoder. That pins:
///
/// - **priming** (encoder delay) trimmed at the start, and again after a seek back to 0;
/// - **end padding** trimmed: exactly 2 s of frames;
/// - **seeks** landing on exactly the frame asked for.
final class ChirpPrimingTests: XCTestCase {

    private struct Fixture {
        let name: String
        let rate: Double
        var frames: Int { Int(2 * rate) }
    }

    private let aac = Fixture(name: "chirp-44k-aac.m4a", rate: 44_100)
    private let mp3 = Fixture(name: "chirp-44k.mp3", rate: 44_100)
    private let opus = Fixture(name: "chirp-48k.opus", rate: 48_000)

    func testAACStartTrimsPriming() throws { try assertStartsAtFrameZero(aac) }
    func testMP3StartTrimsPriming() throws { try assertStartsAtFrameZero(mp3) }
    func testOpusStartTrimsPreSkip() throws { try assertStartsAtFrameZero(opus) }

    func testAACTrimsEndPadding() throws { try assertFrameCount(aac) }
    func testMP3TrimsEndPadding() throws { try assertFrameCount(mp3) }
    func testOpusTrimsEndPadding() throws { try assertFrameCount(opus) }

    func testAACSeekIsSampleExact() throws { try assertSeeksExactly(aac) }
    func testMP3SeekIsSampleExact() throws { try assertSeeksExactly(mp3) }
    func testOpusSeekIsSampleExact() throws { try assertSeeksExactly(opus) }

    func testAACSeekBackToStartTrimsPriming() throws { try assertSeekBackToStart(aac) }
    func testMP3SeekBackToStartTrimsPriming() throws { try assertSeekBackToStart(mp3) }
    func testOpusSeekBackToStartTrimsPreSkip() throws { try assertSeekBackToStart(opus) }

    // MARK: -

    private func assertStartsAtFrameZero(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoder = try open(fixture)
        let pcm = read(decoder, frames: 8192)
        // The first few hundred frames of a lossy decode are the codec settling; from 1024 on is signal.
        XCTAssertEqual(sourceFrame(of: pcm, at: 1024, fixture), 1024, "first frame is source frame 0",
                       file: file, line: line)
    }

    private func assertFrameCount(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoder = try open(fixture)
        let pcm = read(decoder, frames: .max)
        XCTAssertEqual(pcm.count, fixture.frames, "every source frame, and nothing after", file: file, line: line)
        XCTAssertEqual(sourceFrame(of: pcm, at: fixture.frames - 4096, fixture), fixture.frames - 4096,
                       "the tail is the source's tail", file: file, line: line)
    }

    private func assertSeeksExactly(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoder = try open(fixture)
        _ = read(decoder, frames: 4096)
        // Forward and back, across the packet boundaries of every codec here (1024, 1152 and 960).
        for target in [61_234, 4_410, 30_001, 1_152, 77_777] {
            let landed = try decoder.seek(toSeconds: Double(target) / fixture.rate)
            let pcm = read(decoder, frames: 4096)
            // The decoder's own report is checked too: a seek that lands elsewhere than it says is
            // a wrong position, whichever of the two matches the audio.
            XCTAssertEqual((landed * fixture.rate).rounded(), Double(target), "seek to \(target) reported \(landed) s",
                           file: file, line: line)
            XCTAssertEqual(sourceFrame(of: pcm, at: 0, near: target, fixture), target, "seek to \(target) landed elsewhere",
                           file: file, line: line)
        }
    }

    private func assertSeekBackToStart(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoder = try open(fixture)
        _ = read(decoder, frames: 20_000)
        try decoder.seek(toSeconds: 0)
        let pcm = read(decoder, frames: .max)
        XCTAssertEqual(sourceFrame(of: pcm, at: 1024, fixture), 1024, "after a seek to 0, frame 0 is source frame 0",
                       file: file, line: line)
        XCTAssertEqual(pcm.count, fixture.frames, "every frame again, and no priming", file: file, line: line)
    }

    private func open(_ fixture: Fixture) throws -> FFmpegStreamDecoder {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable)
        let url = GoldenStore.root.appendingPathComponent("SeekFixtures/\(fixture.name)")
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try decoder.open()
        XCTAssertEqual(format.sampleRate, fixture.rate)
        XCTAssertEqual(format.channelCount, 1)
        return decoder
    }

    /// Up to `frames` mono frames.
    private func read(_ decoder: FFmpegStreamDecoder, frames: Int) -> [Float] {
        var out: [Float] = []
        while out.count < frames, let chunk = decoder.nextChunk() { out += chunk }
        return Array(out.prefix(frames))
    }

    /// The source frame decoded frame `index` is, found within 3000 frames of `near` (default
    /// `index`): the lag at which a 2048-frame window best matches the chirp, refined by the parabola
    /// through the peak and its neighbours, then rounded.
    private func sourceFrame(of pcm: [Float], at index: Int, near: Int? = nil, _ fixture: Fixture) -> Int {
        let search = 3000
        let window = 2048
        guard index + window <= pcm.count else {
            XCTFail("only \(pcm.count) frames decoded; wanted \(index + window)")
            return -1
        }
        let decoded = Array(pcm[index..<(index + window)])
        let center = near ?? index
        let lowest = max(0, center - search)
        let highest = center + search
        let reference = (lowest..<(highest + window)).map { n -> Float in
            let t = Double(n) / fixture.rate
            return Float(0.5 * sin(2 * .pi * (300 * t + 675 * t * t)))
        }
        let scores = reference.withUnsafeBufferPointer { ref in
            (0...(highest - lowest)).map { lag -> Float in
                var dot: Float = 0
                vDSP_dotpr(decoded, 1, ref.baseAddress! + lag, 1, &dot, vDSP_Length(window))
                return dot
            }
        }
        let peak = scores.indices.max { scores[$0] < scores[$1] }!
        var offset = 0.0
        if peak > 0, peak < scores.count - 1 {
            let (a, b, c) = (Double(scores[peak - 1]), Double(scores[peak]), Double(scores[peak + 1]))
            let denominator = a - 2 * b + c
            if denominator != 0 { offset = 0.5 * (a - c) / denominator }
        }
        return lowest + peak + Int(offset.rounded())
    }
}
