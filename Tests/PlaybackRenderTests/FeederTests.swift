@testable import PlaybackRender
import XCTest

/// The feeder against the fake output's manual clock: no test sleeps, and every pump is explicit.
/// Four frames a second keeps every time exact in binary; the default 2 s target is 8 frames.
final class FeederTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 4, channelCount: 1)
    private let stereo = PCMFormat(sampleRate: 8, channelCount: 2)

    private var output: FakeAudioOutput!
    private var upstream: FakeUpstream!
    private var events: [FeederEvent] = []
    private var feeder: Feeder!

    private func makeFeeder(_ items: [FakeUpstream.Item], chunkFrames: Int64 = 2) {
        output = FakeAudioOutput()
        upstream = FakeUpstream(items, chunkFrames: chunkFrames)
        events = []
        feeder = Feeder(output: output, upstream: upstream) { [unowned self] in events.append($0) }
    }

    private func item(_ id: Int, _ frames: Int64, _ format: PCMFormat? = nil) -> FakeUpstream.Item {
        .init(id: id, frames: frames, format: format ?? mono)
    }

    /// Plays on in quarter-second steps, pumping after each.
    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            feeder.pump()
        }
    }

    /// The first channel of everything heard, silence skipped.
    private var heard: [Float] {
        output.played.flatMap { span -> [Float] in
            guard case let .audio(_, format, samples) = span else { return [] }
            return stride(from: 0, to: samples.count, by: format.channelCount).map { samples[$0] }
        }
    }

    private func ramp(_ item: Int, _ frames: Range<Int64>) -> [Float] {
        frames.map { FakeUpstream.sample(item, $0) }
    }

    private var statuses: [FeederStatus] {
        events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var positions: [MediaPositionMap.Position] {
        events.compactMap { if case let .position(position) = $0 { position } else { nil } }
    }

    private var crossed: [Int] {
        events.compactMap { if case let .crossed(item) = $0 { item } else { nil } }
    }

    private var failures: [any Error] {
        events.compactMap { if case let .failed(error) = $0 { error } else { nil } }
    }

    private func pos(_ item: Int, _ frame: Int64) -> MediaPositionMap.Position {
        .init(item: item, mediaFrame: frame)
    }

    func testStampsAreContiguousAcrossChunksAndAFormatChange() {
        makeFeeder([item(0, 4), item(1, 8, stereo)])
        feeder.pump()

        XCTAssertEqual(output.enqueues.map(\.time), [0, 0.5, 1, 1.25, 1.5, 1.75])
        XCTAssertEqual(output.enqueues.map(\.format), [mono, mono, stereo, stereo, stereo, stereo])
    }

    func testDepthIsHeldAtTheTargetAsTheClockAdvances() {
        makeFeeder([item(0, 80)], chunkFrames: 1)
        feeder.play()

        for _ in 0..<8 {
            output.advance(by: 0.25)
            feeder.pump()
            let last = output.enqueues.last!
            XCTAssertEqual(last.time + 0.25 - output.currentTime(), 2)
        }
        XCTAssertEqual(statuses, [.buffering, .playing])
    }

    func testAnUnderrunPausesAtTheWrittenEndAndResumesWithoutLosingFrames() {
        makeFeeder([item(0, 16)])
        upstream.available = 2
        feeder.play()
        output.advance(by: 1.5)
        feeder.pump()

        XCTAssertEqual(output.currentTime(), 1, "re-anchored at the written end")
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering])

        upstream.available = nil
        feeder.pump()
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .playing])
        run(for: 4)
        XCTAssertEqual(heard, ramp(0, 0..<16))
        XCTAssertEqual(statuses.last, .ended)
    }

    func testEndOfStreamReportsEndedNotBuffering() {
        makeFeeder([item(0, 4), item(1, 0)])
        feeder.play()
        run(for: 1.5)

        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions.last, pos(1, 0))
        XCTAssertEqual(crossed, [0, 1])
        XCTAssertEqual(heard, ramp(0, 0..<4))
        XCTAssertEqual(output.rate, 0)
    }

    func testAnAutoFlushMidItemResuppliesFromTheFlushPosition() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectAutoFlush()
        feeder.pump()

        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
    }

    func testAStallTakesTheSameRecoveryPath() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectStall()
        output.advance(by: 0.5)
        feeder.pump()

        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        XCTAssertEqual(output.flushes, [1.5])
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
    }

    // Podcasts #396: the engine played the pre-seek audio still queued when resumed after a paused seek.
    func testASeekWhilePausedLeavesNoStaleAudioOrPosition() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        feeder.pause()
        feeder.seek(to: pos(0, 20))

        XCTAssertEqual(positions.last, pos(0, 20))
        XCTAssertEqual(statuses.last, .paused)
        feeder.play()
        run(for: 0.5)
        XCTAssertEqual(heard, ramp(0, 0..<4) + ramp(0, 20..<22))
        XCTAssertEqual(positions.last, pos(0, 22))
    }

    func testASpeedChangeWithOldSpeedAudioQueuedKeepsThePositionContinuous() {
        makeFeeder([item(0, 40)])
        feeder.play()
        output.advance(by: 0.5)
        feeder.pump()
        feeder.setRate(2)
        output.advance(by: 0.5)
        feeder.pump()

        XCTAssertEqual(positions, [pos(0, 0), pos(0, 2), pos(0, 6)])
        XCTAssertEqual(heard, ramp(0, 0..<6))
        XCTAssertEqual(output.rate, 2)
    }

    func testAZeroFrameItemIsStillReportedCrossed() {
        makeFeeder([item(0, 2), item(1, 0), item(2, 2)])
        feeder.play()
        XCTAssertEqual(crossed, [0])
        run(for: 0.5)
        XCTAssertEqual(crossed, [0, 1, 2])
    }

    func testARejectedFormatSurfacesAnErrorAndDoesNotSpin() {
        makeFeeder([item(0, 4), item(1, 8, stereo)])
        output.reject(stereo)
        feeder.play()
        let pulls = upstream.pulls
        run(for: 2)

        XCTAssertEqual(failures.map { $0 as? AudioOutputError }, [.formatRejected(stereo)])
        XCTAssertEqual(upstream.pulls, pulls)
        XCTAssertEqual(heard, [])
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(statuses, [.buffering, .paused])
    }
}
