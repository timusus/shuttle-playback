import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
    // MARK: - A read waiting for bytes

    /// Issue #70: the host polls the snapshot to tell a stall from a slow read.
    func testAParkedReadIsInTheSnapshotWithItsExactWaitUntilCancelled() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 1000
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))
        XCTAssertNil(source.snapshot.readWaitingSince)

        let parks = source.parkCount
        let parkedAt = clock.now
        let pending = readAsync(source, 1)
        XCTAssertTrue(waitUntil { source.parkCount > parks }, "parked at the frontier")
        XCTAssertEqual(source.snapshot.readWaitingSince, parkedAt)

        clock.advance(by: 3)
        XCTAssertTrue(waitUntil { source.parkCount > parks + 1 }, "the recheck woke it and it parked again")
        let since = try XCTUnwrap(source.snapshot.readWaitingSince)
        XCTAssertEqual(clock.now - since, 3)

        source.cancel()
        XCTAssertTrue(pending.finished(within: 20))
        guard case .cancelled? = readerError(pending.result) else { return XCTFail("\(pending.result)") }
        XCTAssertNil(source.snapshot.readWaitingSince)
    }

    func testArrivingBytesEndTheWait() throws {
        let body = makeBody(512 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)

        let pending = readAsync(source, 1000)
        XCTAssertTrue(pending.finished(within: 20), "the first bytes arrived")
        XCTAssertEqual(try pending.result.get(), body.prefix(1000))
        XCTAssertNil(source.snapshot.readWaitingSince)
    }
}
