import PlaybackDecode
@testable import PlaybackRender
import XCTest

/// media3 `EndToEndGaplessTest`, ported: each fixture decoded alone, then joined through the
/// sequencer, must be their concatenation sample for sample. The decoder trims encoder delay and
/// padding, so the frame counts are the goldens'. Fixtures are read by path from the conformance suite.
final class SequencerGaplessTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures")

    private let executor = ManualExecutor()
    private lazy var sequencer = Sequencer(executor: executor)

    override func setUpWithError() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    private func source(_ fixture: String) throws -> FFmpegItemSource {
        FFmpegItemSource(reader: try FileByteReader(url: Self.fixtures.appendingPathComponent(fixture)))
    }

    /// The fixture decoded on its own, start to end.
    private func decode(_ fixture: String) throws -> (samples: [Float], format: PCMFormat) {
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: Self.fixtures.appendingPathComponent(fixture)))
        let format = try decoder.open()
        var samples: [Float] = []
        while let chunk = decoder.nextChunk() { samples += chunk }
        XCTAssertEqual(decoder.endReason, .eof)
        return (samples, PCMFormat(sampleRate: format.sampleRate, channelCount: format.channelCount))
    }

    /// The tags of one item merged into (media start, frames) runs, each contiguous with the last.
    private func span(of item: Int, in drained: Drained) -> (start: Int64, frames: Int64)? {
        let tags = drained.tags.filter { $0.item == item }
        guard let first = tags.first else { return nil }
        var end = first.mediaStartFrame
        for tag in tags {
            XCTAssertEqual(tag.mediaStartFrame, end, "item \(item) has a hole or overlap")
            end += tag.frameCount
        }
        return (first.mediaStartFrame, end - first.mediaStartFrame)
    }

    func testTwoCopiesOfACBRMP3JoinSampleForSample() throws {
        let reference = try decode("test-cbr-info-header.mp3")
        sequencer.setCurrent(item: 1, source: try source("test-cbr-info-header.mp3"))
        sequencer.setNext(item: 2, source: try source("test-cbr-info-header.mp3"))

        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.samples, reference.samples + reference.samples)
        XCTAssertEqual(span(of: 1, in: drained)?.frames, 44100)
        XCTAssertEqual(span(of: 2, in: drained)?.start, 0)
        XCTAssertEqual(span(of: 2, in: drained)?.frames, 44100)
        XCTAssertEqual(drained.tags.map(\.item), drained.tags.map(\.item).sorted(), "the items interleave")
        XCTAssertTrue(drained.chunks.allSatisfy { $0.format == reference.format })
    }

    /// Mono into stereo into 8 kHz, through a 1152-frame item, the last set only after the
    /// sequencer had ended.
    func testJoinsAcrossChannelCountAndRateChangesThroughATrimmedItem() throws {
        let a = try decode("test-cbr-info-header.mp3")
        let trimmed = try decode("play-trimmed.mp3")
        let c = try decode("mpeg25_8k_mono.mp3")
        XCTAssertEqual(trimmed.format, PCMFormat(sampleRate: 44100, channelCount: 2))
        XCTAssertEqual(c.format, PCMFormat(sampleRate: 8000, channelCount: 1))

        sequencer.setCurrent(item: 1, source: try source("test-cbr-info-header.mp3"))
        sequencer.setNext(item: 2, source: try source("play-trimmed.mp3"))
        let first = drain(sequencer, executor)
        XCTAssertTrue(first.ended)
        sequencer.setNext(item: 3, source: try source("mpeg25_8k_mono.mp3"))
        let second = drain(sequencer, executor)

        XCTAssertTrue(second.ended)
        XCTAssertEqual(first.samples(of: 1), a.samples)
        XCTAssertEqual(first.samples(of: 2), trimmed.samples)
        XCTAssertEqual(second.samples, c.samples)
        XCTAssertEqual(span(of: 2, in: first)?.start, 0)
        XCTAssertEqual(span(of: 2, in: first)?.frames, 1152)
        XCTAssertEqual(span(of: 3, in: second)?.frames, 193_536)
        for chunk in first.chunks + second.chunks {
            XCTAssertEqual(Set(chunk.tags.map(\.item)).count, 1, "a chunk spans a join")
        }
    }

    func testASeekMidItemIsSampleAccurateAndNothingFromBeforeItArrives() throws {
        let reference = try decode("test-cbr-info-header.mp3")
        sequencer.setCurrent(item: 1, source: try source("test-cbr-info-header.mp3"))
        executor.runUntilIdle()
        _ = sequencer.pull()

        sequencer.seek(item: 1, mediaFrame: 22050)
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags.first?.mediaStartFrame, 22050)
        XCTAssertEqual(span(of: 1, in: drained)?.frames, 22050)
        XCTAssertEqual(drained.samples, Array(reference.samples[22050...]))
    }

    func testAStartFrameIsSampleAccurate() throws {
        let reference = try decode("test-cbr-info-header.mp3")
        sequencer.setCurrent(item: 1, source: try source("test-cbr-info-header.mp3"), startFrame: 10000)

        let drained = drain(sequencer, executor)

        XCTAssertEqual(drained.tags.first?.mediaStartFrame, 10000)
        XCTAssertEqual(drained.samples, Array(reference.samples[10000...]))
    }
}
