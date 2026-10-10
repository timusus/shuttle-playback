@testable import PlaybackRender
import XCTest

/// The fake's own rules, so a core test that fails is the core's fault. Four frames a second keeps
/// every time exact in binary.
final class FakeAudioOutputTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 4, channelCount: 1)

    func testPlaysQueuedAudioAtTheRateAndFreezesWhilePaused() throws {
        let output = FakeAudioOutput()
        try output.enqueue([1, 2, 3, 4, 5, 6, 7, 8], format: mono, at: 0)
        output.advance(by: 1)
        XCTAssertEqual(output.currentTime(), 0, "a new output is paused")

        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        output.setRate(2, at: nil)
        output.advance(by: 0.25)
        XCTAssertEqual(output.currentTime(), 1)
        output.setRate(0, at: nil)
        output.advance(by: 5)
        XCTAssertEqual(output.currentTime(), 1)
        XCTAssertEqual(output.played, [.audio(start: 0, format: mono, samples: [1, 2, 3, 4])])
    }

    func testATimestampHolePlaysAsSilence() throws {
        let output = FakeAudioOutput()
        try output.enqueue([1, 2], format: mono, at: 0)
        try output.enqueue([3, 4], format: mono, at: 1)
        output.setRate(1, at: 0)
        output.advance(by: 1.5)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [1, 2]),
            .silence(start: 0.5, duration: 0.5),
            .audio(start: 1, format: mono, samples: [3, 4]),
        ])
    }

    func testAnOverlapIsTrimmedToTheTimeline() throws {
        let output = FakeAudioOutput()
        try output.enqueue([1, 2, 3, 4], format: mono, at: 0)
        try output.enqueue([5, 6, 7, 8], format: mono, at: 0.5)
        output.setRate(1, at: 0)
        output.advance(by: 2)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [1, 2, 3, 4, 7, 8]),
            .silence(start: 1.5, duration: 0.5),
        ])
    }

    func testTheClockRunsThroughAnUnderrunWithNoEventAndLateAudioNeverPlays() throws {
        let output = FakeAudioOutput()
        try output.enqueue([1, 2], format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 1)
        try output.enqueue([3, 4, 5, 6], format: mono, at: 0.5)
        output.advance(by: 0.5)

        XCTAssertEqual(output.currentTime(), 1.5)
        XCTAssertEqual(output.events, [])
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [1, 2]),
            .silence(start: 0.5, duration: 0.5),
            .audio(start: 1, format: mono, samples: [5, 6]),
        ])
    }

    func testAnAutoFlushDropsTheQueueAndReportsTheFlushTime() throws {
        let output = FakeAudioOutput()
        let handled = expectation(description: "the handler hears the auto-flush")
        output.setEventHandler { XCTAssertEqual($0, .autoFlushed(at: 0.5)); handled.fulfill() }
        try output.enqueue([1, 2, 3, 4], format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        output.injectAutoFlush()
        output.advance(by: 0.5)

        wait(for: [handled], timeout: 0)
        XCTAssertEqual(output.events, [.autoFlushed(at: 0.5)])
        XCTAssertEqual(output.flushes, [0.5])
        XCTAssertEqual(output.currentTime(), 1, "the renderer resumes itself")
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [1, 2]),
            .silence(start: 0.5, duration: 0.5),
        ])
    }

    func testAStallPlaysSilenceUntilFlushed() throws {
        let output = FakeAudioOutput()
        try output.enqueue([1, 2, 3, 4], format: mono, at: 0)
        output.setRate(1, at: 0)
        output.injectStall()
        output.advance(by: 0.5)
        output.flush()
        try output.enqueue([5, 6], format: mono, at: 0.5)
        output.advance(by: 0.5)

        XCTAssertEqual(output.events, [.stalled])
        XCTAssertEqual(output.played, [
            .silence(start: 0, duration: 0.5),
            .audio(start: 0.5, format: mono, samples: [5, 6]),
        ])
    }

    func testARejectedFormatThrowsAndQueuesNothing() throws {
        let output = FakeAudioOutput()
        let surround = PCMFormat(sampleRate: 4, channelCount: 6)
        output.reject(surround)
        XCTAssertThrowsError(try output.enqueue([Float](repeating: 0, count: 6), format: surround, at: 0)) {
            XCTAssertEqual($0 as? AudioOutputError, .formatRejected(surround))
        }
        XCTAssertEqual(output.enqueues, [])
        XCTAssertTrue(output.isReadyForMoreData)
    }

    func testReadyForMoreWhileLessThanTheDepthIsQueuedAhead() throws {
        let output = FakeAudioOutput(readyAhead: 1)
        try output.enqueue([1, 2, 3, 4, 5, 6], format: mono, at: 0)
        XCTAssertFalse(output.isReadyForMoreData)
        output.setRate(1, at: 0)
        output.advance(by: 0.75)
        XCTAssertTrue(output.isReadyForMoreData)
    }

    func testAFormatChangeBetweenEnqueuesJoinsWithoutAGap() throws {
        let output = FakeAudioOutput()
        let stereo8 = PCMFormat(sampleRate: 8, channelCount: 2)
        try output.enqueue([1, 2], format: mono, at: 0)
        try output.enqueue([3, 3, 4, 4, 5, 5, 6, 6], format: stereo8, at: 0.5)
        output.setRate(1, at: 0)
        output.advance(by: 1)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [1, 2]),
            .audio(start: 0.5, format: stereo8, samples: [3, 3, 4, 4, 5, 5, 6, 6]),
        ])
    }
}
