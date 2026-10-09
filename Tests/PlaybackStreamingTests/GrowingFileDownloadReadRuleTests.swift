import XCTest
@testable import PlaybackStreaming


/// **The seek-wait rule**: what a read at a position of a growing file
/// does, pinned with literals.
final class GrowingFileDownloadReadRuleTests: XCTestCase {

    /// The file covers `[0, 1000)` and a transaction from 0 is at 1000, unless told otherwise.
    private func action(
        _ position: Int64,
        covered: Bool? = nil,
        frontier: Int64? = 1000,
        total: Int64? = 10_000,
        probing: Bool = false,
        rangeIgnored: Bool = false,
        rate: Double? = 100,
        latency: TimeInterval? = 3
    ) -> GrowingFileDownload.ReadRule.Action {
        GrowingFileDownload.ReadRule.action(
            position: position, isCovered: covered ?? (position < (frontier ?? 0)), frontier: frontier,
            totalLength: total, isProbing: probing, rangeIgnored: rangeIgnored, downloadBytesPerSecond: rate,
            responseLatency: latency
        )
    }

    func testCoveredIsServed() {
        XCTAssertEqual(action(0), .serve)
        XCTAssertEqual(action(999), .serve)
        XCTAssertEqual(action(5000, covered: true, frontier: nil), .serve, "another transaction's bytes")
    }

    func testAtTheFrontierWaitsAndEndsAtTheTotal() {
        XCTAssertEqual(action(1000), .wait)
        XCTAssertEqual(action(1000, frontier: 1000, total: 1000), .endOfStream)
        XCTAssertEqual(action(12_000), .endOfStream, "past the known end there is nothing to fetch")
    }

    func testAHoleNoTransactionIsBringingRestarts() {
        XCTAssertEqual(action(1000, covered: false, frontier: nil), .restart)
        XCTAssertEqual(action(1000, covered: false, frontier: nil, rangeIgnored: true), .restart)
    }

    func testUnknownLengthWaitsAtTheFrontierUntilComplete() {
        XCTAssertEqual(action(1000, total: nil), .wait)
        XCTAssertEqual(action(1200, total: nil, rate: 1000), .wait)
    }

    func testAheadWaitsOnlyWhileTheDownloadBeatsANewRequest() {
        // 100 B/s against a 3 s response: 299 bytes ahead is 2.99 s, 300 is 3 s.
        XCTAssertEqual(action(1299), .wait)
        XCTAssertEqual(action(1300), .restart)
        // The same gap against a 0.3 s response restarts; 29 bytes (0.29 s) still waits.
        XCTAssertEqual(action(1029, latency: 0.3), .wait)
        XCTAssertEqual(action(1030, latency: 0.3), .restart)
        XCTAssertEqual(action(1001, latency: nil), .restart, "no response measured yet restarts")
        XCTAssertEqual(action(1001, rate: nil), .restart, "no throughput sample yet restarts")
        XCTAssertEqual(action(1001, rate: 0), .restart, "a stopped download restarts")
    }


    func testFooterLookIsEndOfStreamOnlyDuringTheProbe() {
        XCTAssertEqual(action(9872, probing: true), .endOfStream)
        XCTAssertEqual(action(9999, probing: true), .endOfStream)
        XCTAssertEqual(action(9871, probing: true), .restart, "below the footer the probe's read is a seek")
        XCTAssertEqual(action(9872), .restart, "outside the probe the footer is real audio")
        XCTAssertEqual(action(9872, frontier: 9900, probing: true), .serve, "a footer already on disk is served")
        XCTAssertEqual(action(9872, frontier: 9872, probing: true), .wait, "a transaction at the read brings the footer next")
    }

    func testRangeIgnoredHostIsWaitedForNeverRestarted() {
        XCTAssertEqual(action(9000, rangeIgnored: true, rate: nil), .wait)
    }
}
