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
        let middle = DropRangesProcessor([0..<2])
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
        let first = GainProcessor()
        first.maxOutputSamples = 8
        let second = TestProcessor()
        let third = GainProcessor()
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
        XCTAssertEqual(output.count, 2000)
        XCTAssertEqual(Array(output[0..<4]), [96, 144, 24, 0])
        XCTAssertEqual(tagged, 1000)
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

    func testDroppedTagLeavesNoZeroFrameTagWhenItsItemPlaysLaterInTheChunk() throws {
        let pipeline = try started([DropRangesProcessor([0..<2])], format: mono)
        pipeline.queueInput(chunk([0, 1, 2, 3], format: mono, tags: [tag(1, 0, 2), tag(1, 10, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(1, 10, 2)])
    }

    func testDroppedTagLeavesNoZeroFrameTagWhenItsItemPlayedEarlierInTheChunk() throws {
        let pipeline = try started([DropRangesProcessor([2..<4])], format: mono)
        pipeline.queueInput(chunk((0..<6).map(Float.init), format: mono, tags: [tag(0, 0, 2), tag(0, 10, 2), tag(0, 20, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 0, 2), tag(0, 20, 2)])
    }

    func testDropStartingInOneChunkEndsInTheNext() throws {
        let pipeline = try started([DropRangesProcessor([2..<5])], format: mono)
        pipeline.queueInput(chunk([0, 1, 2, 3], format: mono, tags: [tag(0, 0, 4)]))
        let first = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(first.samples, [0, 1])
        XCTAssertEqual(first.tags, [tag(0, 0, 2)])
        pipeline.queueInput(chunk([4, 5, 6], format: mono, tags: [tag(1, 0, 3)]))
        let second = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(second.samples, [5, 6])
        XCTAssertEqual(second.tags, [tag(1, 1, 2)])
    }

    func testDelayedStageMapsItsTailAtDrain() throws {
        let pipeline = try started([DelayProcessor(frames: 2), DropRangesProcessor([3..<4])], format: mono)
        var played: [[Int64]] = []
        func pull() throws {
            let output = try XCTUnwrap(pipeline.getOutput())
            var frame = 0
            for tag in output.tags {
                for offset in 0..<tag.frameCount {
                    played.append([Int64(output.samples[frame]), Int64(tag.item), tag.mediaStartFrame + offset])
                    frame += 1
                }
            }
            XCTAssertEqual(frame, output.samples.count)
        }
        pipeline.queueInput(chunk([10, 11, 12], format: mono, tags: [tag(0, 100, 3)]))
        try pull()
        pipeline.queueInput(chunk([13, 14], format: mono, tags: [tag(1, 0, 2)]))
        try pull()
        XCTAssertEqual(played, [[10, 0, 100], [11, 0, 101], [12, 0, 102]])
        pipeline.queueEndOfStream()
        try pull()
        XCTAssertTrue(pipeline.isEnded)
        // Sample, item, media frame: 13 was dropped after the delay.
        XCTAssertEqual(played, [[10, 0, 100], [11, 0, 101], [12, 0, 102], [14, 1, 1]])
    }

    func testEndOfStreamWithNoActiveStageEndsOnceInputIsReadOut() throws {
        let pipeline = try started([], format: mono)
        let input = chunk([1, 2], format: mono, tags: [tag(0, 0, 2)])
        pipeline.queueInput(input)
        pipeline.queueEndOfStream()
        XCTAssertFalse(pipeline.isEnded)
        let output = try XCTUnwrap(pipeline.getOutput())
        XCTAssertEqual(output.samples, [1, 2])
        XCTAssertEqual(output.tags, [tag(0, 0, 2)])
        XCTAssertTrue(pipeline.isEnded)
    }

    func testFailedConfigureLeavesEveryStageOnItsOldConfiguration() throws {
        let first = TestProcessor()
        let pipeline = try started([first, FixedRateProcessor(sampleRate: 1000)], format: mono)
        let higher = PCMFormat(sampleRate: 2000, channelCount: 1)
        XCTAssertThrowsError(try pipeline.configure(higher)) { XCTAssertTrue($0 is UnsupportedRate) }
        XCTAssertEqual(first.stagedInput, mono)
        pipeline.flush()
        XCTAssertEqual(first.appliedInput, mono)
        pipeline.queueInput(chunk([1, 2], format: mono, tags: [tag(0, 0, 2)]))
        XCTAssertEqual(pipeline.getOutput()?.tags, [tag(0, 0, 2)])
    }

    func testResamplingStageLeavesEveryStageOnItsOldConfiguration() throws {
        let first = TestProcessor()
        let resampler = RateDoublingProcessor()
        resampler.enabled = false
        let pipeline = try started([first, resampler], format: mono)
        resampler.enabled = true
        XCTAssertThrowsError(try pipeline.configure(PCMFormat(sampleRate: 2000, channelCount: 1)))
        XCTAssertEqual(first.stagedInput, mono)
        XCTAssertEqual(resampler.stagedInput, mono)
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
