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
        let parked = try parkAtAHeldFrontier()
        parked.server.releaseHeldBody(forRangeStartingAt: 0)
        XCTAssertTrue(parked.read.finished(within: 20), "the held bytes arrived")
        XCTAssertEqual(try parked.read.result.get(), parked.body[1000..<1001])
        XCTAssertNil(parked.source.snapshot.readWaitingSince)
    }

    func testAnInterruptEndsTheWait() throws {
        let parked = try parkAtAHeldFrontier()
        parked.source.interrupt()
        XCTAssertTrue(parked.read.finished(within: 20))
        guard case .interrupted? = readerError(parked.read.result) else { return XCTFail("\(parked.read.result)") }
        XCTAssertNil(parked.source.snapshot.readWaitingSince)
    }

    func testAFailureEndsTheWaitAndItsRetriesKeepItsStart() throws {
        let parked = try parkAtAHeldFrontier()
        let parkedAt = parked.clock.now
        parked.server.refuseRequests(for: 3600)
        XCTAssertTrue(parked.server.dropHeldBody(forRangeStartingAt: 0))
        XCTAssertTrue(parked.clock.drive {
            if let since = parked.source.snapshot.readWaitingSince { XCTAssertEqual(since, parkedAt, "a retry restarted the wait") }
            return parked.read.finished(within: 0)
        }, "the link window never closed")
        assertTransport(parked.read.result)
        XCTAssertNil(parked.source.snapshot.readWaitingSince)
    }

    /// The player may move the decoder while its read is parked: the read wakes at the new
    /// position, is served there, and its wait ends.
    func testASeekWhileParkedEndsTheWaitOnceTheReadIsServed() throws {
        let parked = try parkAtAHeldFrontier()
        try parked.source.seek(to: 0)
        parked.clock.advance(by: GrowingFileByteSource.recheckSeconds)
        XCTAssertTrue(parked.read.finished(within: 20))
        XCTAssertEqual(try parked.read.result.get(), parked.body.prefix(1))
        XCTAssertNil(parked.source.snapshot.readWaitingSince)
    }

    struct ParkedRead {
        let body: Data
        let server: LoopbackMediaServer
        let clock: ManualGrowingFileClock
        let source: GrowingFileByteSource
        /// A read of one byte, parked at the frontier since `clock.now`.
        let read: PendingRead
    }

    /// A source that has read the first 1000 bytes of a body held there, with a read parked at that frontier.
    private func parkAtAHeldFrontier() throws -> ParkedRead {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.heldBodyAfterBytesForRangeStartingAt = [0: 1000]
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))
        XCTAssertNil(source.snapshot.readWaitingSince)

        let parks = source.parkCount
        let pending = readAsync(source, 1)
        XCTAssertTrue(waitUntil { source.parkCount > parks }, "parked at the frontier")
        XCTAssertEqual(source.snapshot.readWaitingSince, clock.now, "the parked read is in the snapshot")
        return ParkedRead(body: body, server: server, clock: clock, source: source, read: pending)
    }
}
