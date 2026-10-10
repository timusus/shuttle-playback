import XCTest
@testable import PlaybackRender

/// Ported from media3 `AudioProcessingPipelineTest` (Float32 samples, tagged chunks), plus tag rewriting.
final class AudioProcessingPipelineTests: XCTestCase {
    private let format = PCMFormat(sampleRate: 44100, channelCount: 2)
    private let mono = PCMFormat(sampleRate: 1000, channelCount: 1)

    private func chunk(_ samples: [Float], format: PCMFormat? = nil, tags: [SegmentTag]) -> TaggedChunk {
        TaggedChunk(samples: samples, format: format ?? self.format, tags: tags)
    }

    private func oneSecondOfSilence() -> TaggedChunk {
        let frames = Int64(format.sampleRate)
        return chunk([Float](repeating: 0, count: Int(frames) * format.channelCount),
                     tags: [SegmentTag(item: 0, mediaStartFrame: 0, frameCount: frames)])
    }

    private func tag(_ item: Int, _ start: Int64, _ count: Int64) -> SegmentTag {
        SegmentTag(item: item, mediaStartFrame: start, frameCount: count)
    }

    private func started(_ processors: [AudioProcessor], format: PCMFormat? = nil) throws -> AudioProcessingPipeline {
        let pipeline = AudioProcessingPipeline(processors)
        try pipeline.configure(format ?? self.format)
        pipeline.flush()
        return pipeline
    }

    // MARK: media3 cases

    func testNoProcessorsIsNotOperational() throws {
        XCTAssertFalse(try started([]).isOperational)
    }

    func testConfiguringGivesFormat() throws {
        let pipeline = AudioProcessingPipeline([MonoProcessor()])
        XCTAssertEqual(try pipeline.configure(format), PCMFormat(sampleRate: 44100, channelCount: 1))
    }

    func testConfiguringAndFlushingIsOperational() throws {
        let pipeline = AudioProcessingPipeline([MonoProcessor()])
        XCTAssertFalse(pipeline.isOperational)
        try pipeline.configure(format)
        XCTAssertFalse(pipeline.isOperational, "configure alone must not apply")
        pipeline.flush()
        XCTAssertTrue(pipeline.isOperational)
    }

    func testReconfigureDoesNotChangeOperationalUntilFlush() throws {
        let processor = TestProcessor()
        let pipeline = try started([processor])
        XCTAssertTrue(pipeline.isOperational)
        processor.enabled = false
        try pipeline.configure(format)
        XCTAssertTrue(pipeline.isOperational)
        pipeline.flush()
        XCTAssertFalse(pipeline.isOperational)
    }

    func testReconfiguredFormatTakesEffectAtFlush() throws {
        let pipeline = try started([TestProcessor()])
        try pipeline.configure(mono)
        pipeline.queueInput(chunk([1, 2], tags: [tag(0, 0, 1)]))
        XCTAssertEqual(pipeline.getOutput()?.format, format, "audio queued before the flush keeps the old format")
        pipeline.flush()
        pipeline.queueInput(chunk([1, 2], format: mono, tags: [tag(0, 0, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.format, mono)
    }

    func testInactiveProcessorIsIgnoredInConfiguration() throws {
        let processor = MonoProcessor()
        processor.enabled = false
        let pipeline = AudioProcessingPipeline([processor])
        let output = try pipeline.configure(format)
        pipeline.flush()
        XCTAssertEqual(output, format)
        XCTAssertFalse(pipeline.isOperational)
    }

    func testInactiveProcessorInTheMiddleIsSkipped() throws {
        let middle = DuplicatingProcessor()
        middle.enabled = false
        let pipeline = try started([TestProcessor(), middle, MonoProcessor()])
        pipeline.queueInput(chunk([1, 3, 5, 7], tags: [tag(0, 0, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.samples, [2, 6])
    }

    func testQueueInputProducesOutput() throws {
        let pipeline = try started([TestProcessor()])
        let input = oneSecondOfSilence()
        pipeline.queueInput(input)
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples.count, input.samples.count)
        XCTAssertEqual(output.tags, input.tags)
        XCTAssertNil(pipeline.getOutput(), "output is handed over once")
    }

    func testIsEndedNeedsOutputDrained() throws {
        let processor = TestProcessor()
        processor.maxOutputSamples = 10
        let pipeline = try started([processor])
        pipeline.queueInput(oneSecondOfSilence())
        pipeline.queueEndOfStream()
        var pulls = 0
        while !pipeline.isEnded {
            XCTAssertNotNil(pipeline.getOutput())
            pulls += 1
            XCTAssertLessThan(pulls, 100_000)
        }
        XCTAssertEqual(pulls, 44100 * 2 / 10, "ended only with the last held sample handed over")
    }

    func testFlushClearsBufferedAudioAndEnd() throws {
        let processor = TestProcessor()
        processor.maxOutputSamples = 2
        let pipeline = try started([processor])
        pipeline.queueInput(chunk([1, 2, 3, 4], tags: [tag(0, 0, 2)]))
        pipeline.queueEndOfStream()
        _ = pipeline.getOutput()
        pipeline.flush()
        XCTAssertFalse(pipeline.isEnded)
        XCTAssertNil(pipeline.getOutput())
    }

    func testStagesWithSmallOutputLimitsDrainAndFeedCorrectly() throws {
        let first = DuplicatingProcessor()
        first.maxOutputSamples = 8
        let second = TestProcessor()
        let third = DuplicatingProcessor()
        third.maxOutputSamples = 12
        let fourth = TestProcessor()
        fourth.maxOutputSamples = 160
        let pipeline = try started([first, second, third, fourth])
        var samples = [Float](repeating: 0, count: 1000 * format.channelCount)
        samples[0] = 24
        samples[1] = 36
        samples[2] = 6
        pipeline.queueInput(chunk(samples, tags: [tag(0, 0, 1000)]))
        pipeline.queueEndOfStream()
        var output: [Float] = []
        var tagged: Int64 = 0
        while !pipeline.isEnded {
            if let out = pipeline.getOutput() {
                output += out.samples
                tagged += out.tags.reduce(0) { $0 + $1.frameCount }
                XCTAssertEqual(out.tags.reduce(0) { $0 + $1.frameCount }, out.frameCount)
            }
        }
        XCTAssertEqual(output.count, 4 * samples.count)
        XCTAssertEqual(Array(output[0..<13]), [24, 24, 24, 24, 36, 36, 36, 36, 6, 6, 6, 6, 0])
        XCTAssertEqual(tagged, Int64(output.count / 2))
    }

    func testResetMakesPipelineNotOperational() throws {
        let pipeline = try started([TestProcessor()])
        pipeline.reset()
        XCTAssertFalse(pipeline.isOperational)
        XCTAssertNil(pipeline.getOutput())
    }

    // MARK: tag rewriting

    func testDroppingAMiddleRunPutsTheJumpWhereItWasDropped() throws {
        let pipeline = try started([DropRangesProcessor([3..<6])], format: mono)
        pipeline.queueInput(chunk((0..<10).map(Float.init), format: mono, tags: [tag(0, 100, 10)]))
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples, [0, 1, 2, 6, 7, 8, 9])
        XCTAssertEqual(output.tags, [tag(0, 100, 3), tag(0, 106, 4)])
    }

    func testDroppingAWholeChunkLeavesAZeroFrameTagForItsItem() throws {
        let pipeline = try started([DropRangesProcessor([4..<8])], format: mono)
        pipeline.queueInput(chunk([0, 1, 2, 3], format: mono, tags: [tag(0, 0, 4)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 0, 4)])
        pipeline.queueInput(chunk([4, 5, 6, 7], format: mono, tags: [tag(1, 20, 4)]))
        let dropped = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(dropped.samples, [])
        XCTAssertEqual(dropped.tags, [tag(1, 24, 0)])
        pipeline.queueInput(chunk([8, 9], format: mono, tags: [tag(1, 24, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(1, 24, 2)])
    }

    func testDroppingAcrossAnItemJoinKeepsBothItems() throws {
        let pipeline = try started([DropRangesProcessor([4..<8])], format: mono)
        pipeline.queueInput(chunk((0..<12).map(Float.init), format: mono, tags: [tag(0, 50, 6), tag(1, 0, 6)]))
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples, [0, 1, 2, 3, 8, 9, 10, 11])
        XCTAssertEqual(output.tags, [tag(0, 50, 4), tag(1, 2, 4)])
    }

    func testDroppingAWholeItemInsideAChunkStillReportsIt() throws {
        let pipeline = try started([DropRangesProcessor([2..<6])], format: mono)
        pipeline.queueInput(chunk((0..<8).map(Float.init), format: mono, tags: [tag(0, 0, 2), tag(1, 0, 4), tag(2, 0, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 0, 2), tag(1, 4, 0), tag(2, 0, 2)])
    }

    func testZeroFrameTagPassesThrough() throws {
        let pipeline = try started([TestProcessor()], format: mono)
        pipeline.queueInput(chunk([], format: mono, tags: [tag(3, 0, 0)]))
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples, [])
        XCTAssertEqual(output.tags, [tag(3, 0, 0)])
    }

    func testZeroFrameTagKeepsItsPlaceAmongDrops() throws {
        let pipeline = try started([DropRangesProcessor([2..<4])], format: mono)
        pipeline.queueInput(chunk([0, 1, 2, 3, 4, 5], format: mono, tags: [tag(0, 0, 2), tag(1, 0, 0), tag(2, 0, 4)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 0, 2), tag(1, 0, 0), tag(2, 2, 2)])
    }

    func testDropsInTwoStagesAddUp() throws {
        let pipeline = try started([DropRangesProcessor([1..<3]), DropRangesProcessor([1..<2])], format: mono)
        pipeline.queueInput(chunk((0..<8).map(Float.init), format: mono, tags: [tag(0, 0, 8)]))
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples, [0, 4, 5, 6, 7])
        XCTAssertEqual(output.tags, [tag(0, 0, 1), tag(0, 4, 4)])
    }

    func testPartiallyConsumedAcrossChunksKeepsRunning() throws {
        let pipeline = try started([DropRangesProcessor([3..<5])], format: mono)
        pipeline.queueInput(chunk([0, 1, 2, 3], format: mono, tags: [tag(0, 0, 4)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 0, 3)])
        pipeline.queueInput(chunk([4, 5, 6], format: mono, tags: [tag(0, 4, 3)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 5, 2)])
    }

    func testAddedFramesAreCreditedToWhereTheInputEnded() throws {
        let pipeline = try started([DuplicatingProcessor()], format: mono)
        pipeline.queueInput(chunk([1, 2], format: mono, tags: [tag(0, 10, 2)]))
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples.count, 4)
        XCTAssertEqual(output.tags, [tag(0, 10, 4)])
    }

    func testChannelMappingChangesFormatAndKeepsMediaFrames() throws {
        let pipeline = try started([MonoProcessor()])
        pipeline.queueInput(chunk([1, 3, 5, 7], tags: [tag(0, 40, 1), tag(1, 7, 1)]))
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.format, PCMFormat(sampleRate: 44100, channelCount: 1))
        XCTAssertEqual(output.samples, [2, 6])
        XCTAssertEqual(output.tags, [tag(0, 40, 1), tag(1, 7, 1)])
    }

    func testStageThatResamplesIsRejected() {
        let pipeline = AudioProcessingPipeline([RateDoublingProcessor()])
        XCTAssertThrowsError(try pipeline.configure(format)) {
            XCTAssertEqual($0 as? AudioProcessingError,
                           .sampleRateChanged(from: format, to: PCMFormat(sampleRate: 88200, channelCount: 2)))
        }
    }
}
