import XCTest
@testable import PlaybackStreaming


/// **The seek-wait rule**: what a read at a position of a growing file
/// does, pinned with literals.
final class GrowingFileReadRuleTests: XCTestCase {

    private func action(
        _ position: Int64,
        base: Int64 = 0,
        frontier: Int64 = 1000,
        total: Int64? = 10_000,
        complete: Bool = false,
        probing: Bool = false,
        rangeIgnored: Bool = false,
        rate: Double? = 100
    ) -> GrowingFileReadRule.Action {
        GrowingFileReadRule.action(
            position: position, base: base, frontier: frontier, totalLength: total,
            isComplete: complete, isProbing: probing, rangeIgnored: rangeIgnored, downloadBytesPerSecond: rate
        )
    }

    func testInsideTheFileIsServed() {
        XCTAssertEqual(action(0), .serve)
        XCTAssertEqual(action(999), .serve)
        XCTAssertEqual(action(600, base: 500), .serve)
    }

    func testAtTheFrontierWaitsAndEndsOnlyWhenComplete() {
        XCTAssertEqual(action(1000), .wait)
        XCTAssertEqual(action(1000, frontier: 1000, total: nil, complete: true), .endOfStream)
        XCTAssertEqual(action(10_000, frontier: 10_000, complete: true), .endOfStream)
        XCTAssertEqual(action(12_000), .endOfStream, "past the known end there is nothing to fetch")
    }

    func testUnknownLengthWaitsAtTheFrontierUntilComplete() {
        XCTAssertEqual(action(1000, total: nil), .wait)
        XCTAssertEqual(action(1200, total: nil, rate: 1000), .wait)
    }

    func testAheadWaitsWhenTheGapClosesInUnderWaitSecondsElseRestarts() {
        // 100 B/s: 299 bytes ahead is 2.99 s, 300 is 3 s.
        XCTAssertEqual(action(1299), .wait)
        XCTAssertEqual(action(1300), .restart)
        XCTAssertEqual(action(1001, rate: nil), .restart, "no throughput sample yet restarts")
        XCTAssertEqual(action(1001, rate: 0), .restart, "a stopped download restarts")
    }

    func testBeforeTheBaseRestarts() {
        XCTAssertEqual(action(100, base: 500, frontier: 900), .restart)
        XCTAssertEqual(action(100, base: 500, frontier: 900, complete: true), .restart)
    }

    func testFooterLookIsEndOfStreamOnlyDuringTheProbe() {
        XCTAssertEqual(action(9872, probing: true), .endOfStream)
        XCTAssertEqual(action(9999, probing: true), .endOfStream)
        XCTAssertEqual(action(9871, probing: true), .restart, "below the footer the probe's read is a seek")
        XCTAssertEqual(action(9872), .restart, "outside the probe the footer is real audio")
        XCTAssertEqual(action(9872, frontier: 9900, probing: true), .serve, "a footer already on disk is served")
    }

    func testRangeIgnoredHostIsWaitedForNeverRestarted() {
        XCTAssertEqual(action(9000, rangeIgnored: true, rate: nil), .wait)
    }
}
