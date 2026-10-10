@testable import PlaybackRender
import XCTest

/// The sequencer's rules over in-memory sources, every decode job run by hand.
final class SequencerTests: XCTestCase {
    private let mono44 = PCMFormat(sampleRate: 44100, channelCount: 1)
    private let stereo48 = PCMFormat(sampleRate: 48000, channelCount: 2)
    private let executor = ManualExecutor()
    private lazy var sequencer = Sequencer(executor: executor)

    private func tag(_ item: Int, _ mediaStartFrame: Int64, _ frameCount: Int64) -> SegmentTag {
        SegmentTag(item: item, mediaStartFrame: mediaStartFrame, frameCount: frameCount)
    }

    func testNextFollowsCurrentWithNoGapOrOverlapAndKeepsItsOwnFormat() {
        let a = FakeItemSource(format: mono44, frames: 250)
        let b = FakeItemSource(format: stereo48, frames: 130, base: 10000)
        sequencer.setCurrent(item: 1, source: a)
        sequencer.setNext(item: 2, source: b)

        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(1, 0, 100), tag(1, 100, 100), tag(1, 200, 50), tag(2, 0, 100), tag(2, 100, 30)])
        XCTAssertEqual(drained.chunks.map(\.format), [mono44, mono44, mono44, stereo48, stereo48])
        XCTAssertEqual(drained.samples, a.samples(from: 0, to: 250) + b.samples(from: 0, to: 130))
    }

    func testAZeroFrameItemStillSendsOneZeroFrameTag() {
        sequencer.setCurrent(item: 1, source: FakeItemSource(format: mono44, frames: 50))
        sequencer.setNext(item: 2, source: FakeItemSource(format: stereo48, frames: 0))

        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(1, 0, 50), tag(2, 0, 0)])
        XCTAssertEqual(drained.chunks.last?.frameCount, 0)
    }

    func testClearingNextBeforeTheJoinEndsAtCurrentsEnd() {
        let a = FakeItemSource(format: mono44, frames: 150)
        sequencer.setCurrent(item: 1, source: a)
        sequencer.setNext(item: 2, source: FakeItemSource(format: mono44, frames: 100))
        sequencer.clearNext()

        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(1, 0, 100), tag(1, 100, 50)])
        XCTAssertEqual(executor.queued, 0)
    }

    func testNextSetAfterCurrentHasDrainedStillJoins() {
        let a = FakeItemSource(format: mono44, frames: 150)
        let b = FakeItemSource(format: mono44, frames: 120, base: 5000)
        sequencer.setCurrent(item: 1, source: a)
        XCTAssertTrue(drain(sequencer, executor).ended)

        sequencer.setNext(item: 2, source: b)
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(2, 0, 100), tag(2, 100, 20)])
        XCTAssertEqual(drained.samples, b.samples(from: 0, to: 120))
    }

    func testDecodeStopsAtTheBufferCapacityAndPullNeverDecodes() {
        sequencer.setCurrent(item: 1, source: FakeItemSource(format: mono44, frames: 10000))
        XCTAssertEqual(sequencer.pullIsPending, true)
        executor.runUntilIdle()

        for frame in stride(from: Int64(0), to: Int64(Sequencer.bufferCapacity) * 100, by: 100) {
            guard case let .chunk(chunk) = sequencer.pull() else { return XCTFail("no chunk at \(frame)") }
            XCTAssertEqual(chunk.tags, [tag(1, frame, 100)])
        }
        XCTAssertEqual(sequencer.pullIsPending, true)
        XCTAssertGreaterThan(executor.queued, 0)
    }

    func testASeekDropsWhatWasBufferedAndLandsOnItsFrame() {
        let a = FakeItemSource(format: mono44, frames: 1000)
        sequencer.setCurrent(item: 1, source: a)
        executor.runUntilIdle()
        _ = sequencer.pull()

        sequencer.seek(item: 1, mediaFrame: 555)
        XCTAssertEqual(sequencer.pullIsPending, true)
        let drained = drain(sequencer, executor)

        XCTAssertEqual(drained.tags.first, tag(1, 555, 100))
        XCTAssertEqual(drained.samples, a.samples(from: 555, to: 1000))
        XCTAssertEqual(a.interrupts, 1)
    }

    func testAChunkDecodedAcrossASeekIsDroppedAndTheSourceInterrupted() {
        let a = FakeItemSource(format: mono44, frames: 1000)
        sequencer.setCurrent(item: 1, source: a)
        a.duringRead = { [sequencer] in sequencer.seek(item: 1, mediaFrame: 700) }

        let drained = drain(sequencer, executor)

        XCTAssertEqual(a.interrupts, 1)
        XCTAssertEqual(drained.tags.first, tag(1, 700, 100))
        XCTAssertEqual(drained.samples, a.samples(from: 700, to: 1000))
    }

    func testSetCurrentInterruptsTheOldSourceAndForgetsNext() {
        let a = FakeItemSource(format: mono44, frames: 1000)
        let c = FakeItemSource(format: stereo48, frames: 150, base: 9000)
        sequencer.setCurrent(item: 1, source: a)
        sequencer.setNext(item: 2, source: FakeItemSource(format: mono44, frames: 100))
        executor.runUntilIdle()

        sequencer.setCurrent(item: 3, source: c, startFrame: 40)
        let drained = drain(sequencer, executor)

        XCTAssertEqual(a.interrupts, 1)
        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(3, 40, 100), tag(3, 140, 10)])
        XCTAssertEqual(drained.samples, c.samples(from: 40, to: 150))
    }

    /// An auto-flush while the joined-from item's tail is still playing resupplies from inside it.
    func testASeekBackIntoTheItemJustJoinedFromRejoinsFromTheStart() {
        let a = FakeItemSource(format: mono44, frames: 150)
        let b = FakeItemSource(format: stereo48, frames: 250, base: 7000)
        sequencer.setCurrent(item: 1, source: a)
        sequencer.setNext(item: 2, source: b)
        let head = drain(sequencer, executor, limit: 3)
        XCTAssertEqual(head.tags.last, tag(2, 0, 100))

        sequencer.seek(item: 1, mediaFrame: 120)
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(1, 120, 30), tag(2, 0, 100), tag(2, 100, 100), tag(2, 200, 50)])
        XCTAssertEqual(drained.samples, a.samples(from: 120, to: 150) + b.samples(from: 0, to: 250))
    }

    func testASeekBackAcrossAJoinReplaysEveryItemAfterIt() {
        let a = FakeItemSource(format: mono44, frames: 150)
        let b = FakeItemSource(format: stereo48, frames: 250, base: 7000)
        let c = FakeItemSource(format: mono44, frames: 120, base: 20000)
        sequencer.setCurrent(item: 1, source: a)
        sequencer.setNext(item: 2, source: b)
        let head = drain(sequencer, executor, limit: 3)
        XCTAssertEqual(head.tags.last, tag(2, 0, 100))
        sequencer.setNext(item: 3, source: c)

        sequencer.seek(item: 1, mediaFrame: 120)
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(1, 120, 30), tag(2, 0, 100), tag(2, 100, 100), tag(2, 200, 50),
                                      tag(3, 0, 100), tag(3, 100, 20)])
        XCTAssertEqual(drained.samples, a.samples(from: 120, to: 150) + b.samples(from: 0, to: 250) + c.samples(from: 0, to: 120))
    }

    /// The decode-ahead crosses several short items while the feeder still holds the first's audio,
    /// so its resupply lands two joins back.
    func testASeekIntoTheFirstOfThreeShortItemsReplaysAllThree() {
        let a = FakeItemSource(format: mono44, frames: 30)
        let c = FakeItemSource(format: stereo48, frames: 20, base: 3000)
        sequencer.setCurrent(item: 1, source: a)
        sequencer.setNext(item: 2, source: FakeItemSource(format: mono44, frames: 0))
        executor.runUntilIdle()
        sequencer.setNext(item: 3, source: c)
        let head = drain(sequencer, executor)
        XCTAssertEqual(head.tags, [tag(1, 0, 30), tag(2, 0, 0), tag(3, 0, 20)])

        sequencer.seek(item: 1, mediaFrame: 10)
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(1, 10, 20), tag(2, 0, 0), tag(3, 0, 20)])
        XCTAssertEqual(drained.samples, a.samples(from: 10, to: 30) + c.samples(from: 0, to: 20))
    }

    func testAnEndedItemIsNotTaggedAgainWhenItsNextIsClearedBeforeTheJobRuns() {
        sequencer.setCurrent(item: 1, source: FakeItemSource(format: mono44, frames: 0))
        XCTAssertEqual(drain(sequencer, executor).tags, [tag(1, 0, 0)])

        sequencer.setNext(item: 2, source: FakeItemSource(format: mono44, frames: 100))
        sequencer.clearNext()
        XCTAssertEqual(executor.queued, 1)
        executor.runUntilIdle()
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [])
    }

    func testReleaseDropsTheItemsBeforeAndSeeksStillLandInTheRest() {
        weak var released: FakeItemSource?
        let b = FakeItemSource(format: stereo48, frames: 250, base: 7000)
        do {
            let a = FakeItemSource(format: mono44, frames: 150)
            released = a
            sequencer.setCurrent(item: 1, source: a)
        }
        sequencer.setNext(item: 2, source: b)
        XCTAssertEqual(drain(sequencer, executor, limit: 3).tags.last, tag(2, 0, 100))

        sequencer.release(before: 2)
        XCTAssertNil(released)
        sequencer.seek(item: 2, mediaFrame: 50)
        let drained = drain(sequencer, executor)

        XCTAssertTrue(drained.ended)
        XCTAssertEqual(drained.tags, [tag(2, 50, 100), tag(2, 150, 100)])
        XCTAssertEqual(drained.samples, b.samples(from: 50, to: 250))
    }

    func testAFailedSourceIsReportedNotEnded() {
        sequencer.setCurrent(item: 1, source: FailingItemSource())
        sequencer.setNext(item: 2, source: FakeItemSource(format: mono44, frames: 100))
        executor.runUntilIdle()

        guard case let .failed(item, _) = sequencer.pull() else { return XCTFail("not failed") }
        XCTAssertEqual(item, 1)
    }
}

private final class FailingItemSource: ItemSource, @unchecked Sendable {
    struct Failure: Error {}
    func open() throws -> PCMFormat { throw Failure() }
    func seek(toFrame frame: Int64) throws -> Int64 { throw Failure() }
    func nextChunk() throws -> [Float]? { throw Failure() }
    func begin(epoch: UInt64) {}
    func interrupt(through epoch: UInt64) {}
}

private extension Sequencer {
    var pullIsPending: Bool {
        if case .pending = pull() { return true }
        return false
    }
}
