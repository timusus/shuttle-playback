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
        XCTAssertTrue(parked.clock.drive(parked.source) {
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

    private var readEvents: [GrowingFileEvent] {
        events.events.filter {
            switch $0 {
            case .readWaiting, .readResumed: return true
            default: return false
            }
        }
    }

    /// The stall after `parkAtAHeldFrontier`'s opening read, whose own wait (the first byte) is the first pair.
    private var heldStallEvents: [GrowingFileEvent] { Array(readEvents.dropFirst(2)) }

    func testAStallReportsWaitingOnceThroughRechecksAndResumedOnceWhenBytesArrive() throws {
        let parked = try parkAtAHeldFrontier()
        let parkedAt = parked.clock.now
        XCTAssertTrue(waitUntil { self.heldStallEvents.count == 1 }, "reported when the read parked")
        XCTAssertEqual(heldStallEvents, [.readWaiting(since: parkedAt)])

        let parks = parked.source.parkCount
        parked.clock.advance(by: GrowingFileByteSource.recheckSeconds)
        XCTAssertTrue(waitUntil { parked.source.parkCount > parks }, "the recheck parked it again")
        XCTAssertEqual(heldStallEvents, [.readWaiting(since: parkedAt)], "a recheck is the same stall")

        parked.server.releaseHeldBody(forRangeStartingAt: 0)
        XCTAssertTrue(parked.read.finished(within: 20))
        XCTAssertEqual(heldStallEvents, [.readWaiting(since: parkedAt), .readResumed])
    }

    func testAReadServedFromTheFileReportsNoWait() throws {
        let body = makeBody(64 * 1024)
        let source = makeSource(try startServer(body: body).url, clock: ManualGrowingFileClock())
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))
        let opening = readEvents
        try source.seek(to: 0)
        XCTAssertEqual(try read(source, 10), body.prefix(10), "served from the file on disk")
        XCTAssertEqual(readEvents, opening)
    }

    func testACancelledStallStillReportsResumed() throws {
        let parked = try parkAtAHeldFrontier()
        XCTAssertTrue(waitUntil { self.heldStallEvents.count == 1 })
        parked.source.cancel()
        XCTAssertTrue(parked.read.finished(within: 20))
        XCTAssertEqual(heldStallEvents.last, .readResumed)
        XCTAssertEqual(heldStallEvents.count, 2)
    }

    func testAHandlerMayReadTheSnapshotFromTheReadingThread() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.heldBodyAfterBytesForRangeStartingAt = [0: 1000]
        let seen = EventRecorder()
        let box = SourceBox()
        let source = GrowingFileByteSource(
            url: server.url, authHeaders: [:], cacheKey: nil, connectionPolicy: nil, readAhead: nil,
            store: makeStore(), session: GrowingFileByteSourceTests.testSession, clock: ManualGrowingFileClock(),
            pathMonitor: GrowingFilePathMonitor(), unknownLengthWindow: GrowingFileDownload.unknownLengthWindowBytes,
            onEvent: { event in
                _ = box.source?.snapshot
                seen.append(event)
            }
        )
        box.source = source
        sources.append(source)
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))
        let pending = readAsync(source, 1)
        XCTAssertTrue(waitUntil { seen.events.filter { $0 == .readWaiting(since: 1000) }.count == 2 }, "the handler returned after reading the snapshot")
        server.releaseHeldBody(forRangeStartingAt: 0)
        XCTAssertTrue(pending.finished(within: 20))
    }

    private final class SourceBox: @unchecked Sendable {
        var source: GrowingFileByteSource?
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
