@testable import PlaybackRender
import XCTest

/// The position cases of media3 `DefaultAudioSinkTest`, adapted: dropped frames count when they would
/// have played, and speed is the output's rate. Then the edge cases of the #93 plan, driven through
/// the fake output.
final class MediaPositionMapTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 44100, channelCount: 1)

    /// Output time of `frames` at 44.1 kHz.
    private func at(_ frames: Int64) -> TimeInterval { Double(frames) / 44100 }

    private func tag(_ item: Int, _ mediaStartFrame: Int64, _ frameCount: Int64) -> SegmentTag {
        SegmentTag(item: item, mediaStartFrame: mediaStartFrame, frameCount: frameCount)
    }

    private func ramp(from: Int64, count: Int64) -> [Float] {
        (from..<(from + count)).map(Float.init)
    }

    // MARK: Ported from the spike

    func testPositionStartsAtTheFirstTagsMediaFrame() {
        var map = MediaPositionMap()
        map.append(tag(0, 220500, 44100), sampleRate: 44100)
        XCTAssertEqual(map.position(at: 0), .init(item: 0, mediaFrame: 220500))

        map.reset(at: 3)
        map.append(tag(0, 352800, 44100), sampleRate: 44100)
        XCTAssertEqual(map.position(at: 3), .init(item: 0, mediaFrame: 352800))
    }

    func testNothingWrittenHasNoPosition() {
        XCTAssertNil(MediaPositionMap().position(at: 0))
    }

    // media3 credits the 441 dropped frames as soon as they are processed.
    func testDroppedFramesCountOnlyOnceThePlayheadReachesThem() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 22050), sampleRate: 44100)
        map.append(tag(0, 22491, 22050), sampleRate: 44100)

        XCTAssertEqual(map.position(at: at(11025))?.mediaFrame, 11025, "no early jump while the drop is queued")
        XCTAssertEqual(map.position(at: at(22049))?.mediaFrame, 22049)
        XCTAssertEqual(map.position(at: at(22050))?.mediaFrame, 22491)
        XCTAssertEqual(map.position(at: at(44100))?.mediaFrame, 44541)
    }

    func testPlayheadBeyondWhatWasWrittenHoldsAtTheEnd() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 1000), sampleRate: 44100)
        XCTAssertEqual(map.position(at: at(5000))?.mediaFrame, 1000, "a starved output must not run the position on")
    }

    func testAGaplessBoundaryIsReportedWhenThePlayheadCrossesIt() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), sampleRate: 44100)
        map.append(tag(1, 0, 44100), sampleRate: 44100)

        XCTAssertEqual(map.advance(to: 0), [0])
        XCTAssertEqual(map.advance(to: at(44099)), [], "written is not played")
        XCTAssertEqual(map.position(at: at(44099)), .init(item: 0, mediaFrame: 44099))
        XCTAssertEqual(map.advance(to: at(44100)), [1])
        XCTAssertEqual(map.advance(to: at(50000)), [])
        XCTAssertEqual(map.position(at: at(50000)), .init(item: 1, mediaFrame: 5900))
    }

    func testAZeroFrameItemStillEnds() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 100), sampleRate: 44100)
        map.append(tag(1, 0, 0), sampleRate: 44100)
        map.append(tag(2, 0, 100), sampleRate: 44100)
        map.append(tag(3, 0, 0), sampleRate: 44100)

        XCTAssertEqual(map.advance(to: at(50)), [0])
        XCTAssertEqual(map.advance(to: at(150)), [1, 2], "item 1 is entered and left in one step")
        XCTAssertEqual(map.advance(to: at(200)), [3], "a zero-frame last item is still reached")
        XCTAssertEqual(map.position(at: at(200)), .init(item: 3, mediaFrame: 0))
    }

    func testAdvancingKeepsLaterPositionsExact() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 1000), sampleRate: 44100)
        map.append(tag(0, 1500, 1000), sampleRate: 44100)
        _ = map.advance(to: at(1500))
        XCTAssertEqual(map.position(at: at(1500))?.mediaFrame, 2000)
        XCTAssertEqual(map.position(at: at(2000))?.mediaFrame, 2500)
    }

    // MARK: The #93 edge cases

    func testATimestampJumpOver200msMovesThePositionOnlyWhenPlayed() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), sampleRate: 44100)
        map.append(tag(0, 57330, 44100), sampleRate: 44100)

        XCTAssertEqual(map.writtenEnd, 2, "the output stays contiguous across the 300 ms jump")
        XCTAssertEqual(map.advance(to: at(22050)), [0])
        XCTAssertEqual(map.position(at: at(22050))?.mediaFrame, 22050)
        XCTAssertEqual(map.advance(to: at(44100)), [], "a jump is not an item boundary")
        XCTAssertEqual(map.position(at: at(44100))?.mediaFrame, 57330)
        XCTAssertEqual(map.position(at: at(66150))?.mediaFrame, 79380)
    }

    func testAFormatChangeAtAJoinMapsEachItemAtItsOwnRate() throws {
        let output = FakeAudioOutput()
        let stereo48 = PCMFormat(sampleRate: 48000, channelCount: 2)
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), sampleRate: 44100)
        try output.enqueue(ramp(from: 0, count: 44100), format: mono, at: 0)
        let join = map.writtenEnd
        map.append(tag(1, 0, 48000), sampleRate: 48000)
        try output.enqueue([Float](repeating: 1, count: 96000), format: stereo48, at: join)

        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: output.currentTime()), [0])
        XCTAssertEqual(map.position(at: output.currentTime()), .init(item: 0, mediaFrame: 22050))
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: output.currentTime()), [1])
        XCTAssertEqual(map.position(at: output.currentTime()), .init(item: 1, mediaFrame: 0))
        output.advance(by: 0.5)
        XCTAssertEqual(map.position(at: output.currentTime()), .init(item: 1, mediaFrame: 24000))

        XCTAssertEqual(join, 1)
        XCTAssertEqual(output.played.count, 2, "the join has no silence")
        XCTAssertEqual(output.played.last, .audio(start: 1, format: stereo48, samples: [Float](repeating: 1, count: 48000)))
    }

    // Speed is the output rate, so the map has no speed checkpoint for the position to jump at.
    func testARateChangeLeavesTheMediaPositionContinuous() throws {
        let output = FakeAudioOutput()
        var map = MediaPositionMap()
        map.append(tag(0, 0, 176400), sampleRate: 44100)
        try output.enqueue(ramp(from: 0, count: 176400), format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 1)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 44100)

        output.setRate(2, at: nil)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 44100)
        output.advance(by: 0.5)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 88200)
        output.setRate(1, at: nil)
        output.advance(by: 0.5)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 110250)
    }

    func testASeekWhilePausedLeavesNoStalePosition() throws {
        let output = FakeAudioOutput()
        output.outputLatency = 0.25
        var map = MediaPositionMap()
        var heard: TimeInterval { map.playhead(currentTime: output.currentTime(), outputLatency: output.outputLatency) }
        map.append(tag(0, 0, 88200), sampleRate: 44100)
        try output.enqueue([Float](repeating: 1, count: 88200), format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        output.setRate(0, at: nil)
        XCTAssertEqual(map.advance(to: heard), [0])
        XCTAssertEqual(map.position(at: heard)?.mediaFrame, 11025, "a quarter second is still in the hardware")

        output.flush()
        output.setRate(0, at: 10)
        map.reset(at: 10)
        XCTAssertNil(map.position(at: heard), "nothing of the new epoch is written yet")
        map.append(tag(0, 441000, 44100), sampleRate: 44100)
        try output.enqueue([Float](repeating: 2, count: 44100), format: mono, at: 10)
        XCTAssertEqual(heard, 10, "the clock reads the anchor; the latency must not reach back into the old epoch")
        XCTAssertEqual(map.position(at: heard), .init(item: 0, mediaFrame: 441000))

        output.setRate(1, at: nil)
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: heard), [], "a seek inside the item crosses no boundary")
        XCTAssertEqual(map.position(at: heard)?.mediaFrame, 452025)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [Float](repeating: 1, count: 22050)),
            .audio(start: 10, format: mono, samples: [Float](repeating: 2, count: 22050)),
        ])
    }

    func testAnAutoFlushReAnchorsAtTheFlushTime() throws {
        let output = FakeAudioOutput()
        var map = MediaPositionMap()
        map.append(tag(0, 0, 88200), sampleRate: 44100)
        try output.enqueue(ramp(from: 0, count: 88200), format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: output.currentTime()), [0])
        output.injectAutoFlush()
        output.advance(by: 0.25)

        guard case let .autoFlushed(flushTime)? = output.events.last else { return XCTFail("no auto-flush") }
        let resume = try XCTUnwrap(map.position(at: flushTime))
        XCTAssertEqual(resume, .init(item: 0, mediaFrame: 22050))
        map.reset(at: flushTime)
        map.append(tag(0, resume.mediaFrame, 66150), sampleRate: 44100)
        try output.enqueue(ramp(from: resume.mediaFrame, count: 66150), format: mono, at: flushTime)

        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 33075, "the clock ran on while the event was handled")
        output.advance(by: 0.25)
        XCTAssertEqual(map.advance(to: output.currentTime()), [])
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 44100)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: ramp(from: 0, count: 22050)),
            .silence(start: 0.5, duration: 0.25),
            .audio(start: 0.75, format: mono, samples: ramp(from: 33075, count: 11025)),
        ], "the re-fed audio is heard at the media frame the map reports")
    }

    func testThePlayheadIsTheClockLessLatencyAndNeverBeforeTheEpoch() {
        let map = MediaPositionMap(epochStart: 10)
        XCTAssertEqual(map.playhead(currentTime: 10.5, outputLatency: 0.25), 10.25)
        XCTAssertEqual(map.playhead(currentTime: 10.5, outputLatency: 0), 10.5, "a clock that includes latency reports 0")
        XCTAssertEqual(map.playhead(currentTime: 10.125, outputLatency: 0.25), 10)
    }
}
