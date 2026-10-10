import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
    // MARK: - Failure

    func testInterruptAndCancelEndAReadParkedAtTheFrontierAndCancelDeletesThePartial() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 1000
        let source = makeSource(server.url)
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))

        var parks = source.parkCount
        var pending = readAsync(source, 1)
        XCTAssertTrue(waitUntil { source.parkCount > parks }, "parked at the frontier")
        source.interrupt()
        XCTAssertTrue(pending.finished(within: 20))
        guard case .interrupted? = readerError(pending.result) else { return XCTFail("\(pending.result)") }

        source.clearInterrupt()
        XCTAssertEqual(partials().count, 1)
        parks = source.parkCount
        pending = readAsync(source, 1)
        XCTAssertTrue(waitUntil { source.parkCount > parks }, "parked at the frontier")
        source.cancel()
        XCTAssertTrue(pending.finished(within: 20))
        guard case .cancelled? = readerError(pending.result) else { return XCTFail("\(pending.result)") }
        XCTAssertEqual(partials(), [], "stop deletes the partial")
        let snapshot = source.snapshot
        XCTAssertNil(snapshot.fileURL, "the snapshot names no deleted file")
        XCTAssertEqual(snapshot.frontier, snapshot.base)
    }

    func testABodyThatAlwaysEndsShortFailsTheReadInsteadOfEndingIt() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.contentLengthLie = 1000
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)

        let pending = PendingRead {
            var got = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            do {
                while true {
                    let n = try buffer.withUnsafeMutableBytes { try source.read(into: $0.baseAddress!, maxLength: $0.count) }
                    XCTAssertGreaterThan(n, 0, "a short body is never the end of the stream")
                    if n == 0 { break }
                    got.append(contentsOf: buffer[0..<n])
                }
            } catch StreamByteReaderError.transport {
                // The retries are spent.
            }
            return got
        }
        XCTAssertTrue(clock.drive(source) { pending.finished(within: 0) }, "the read hung")
        let got = try pending.result.get()
        XCTAssertEqual(got, body.prefix(got.count))
        XCTAssertEqual(got.count, body.count - 1000)
        XCTAssertGreaterThan(server.requestedRanges.count, 1, "it retried")
    }

    func testNoNetworkForAMomentIsRetriedAndForLongerThanTheWindowFailsTheRead() throws {
        let body = makeBody(32 * 1024)
        let server = try startServer(body: body)
        server.refuseRequests(for: 0.15)
        XCTAssertEqual(try readToEnd(makeSource(server.url)), body)

        let longer = try startServer(body: body)
        longer.refuseRequests(for: 3600)
        let clock = ManualGrowingFileClock()
        let source = makeSource(longer.url, clock: clock)
        let pending = readAsync(source, 1)
        XCTAssertTrue(clock.drive(source) { pending.finished(within: 0) }, "the window never closed")
        assertTransport(pending.result)
        // It stops asking once the next attempt would start past the window: at most one backoff early.
        XCTAssertGreaterThanOrEqual(
            clock.now - 1_000, GrowingFileDownload.Retry.linkWindowSeconds - GrowingFileDownload.Retry.maxBackoffSeconds,
            "the read failed before the window closed"
        )
        XCTAssertLessThanOrEqual(clock.now - 1_000, GrowingFileDownload.Retry.linkWindowSeconds + 1, "the window ran long")
    }

    /// A link that swallows every request (a captive portal, a dead Wi-Fi that still connects):
    /// the first request gets the generous header wait, each retry the short one, and none runs
    /// past the window's end, so the read fails 30 s after the first request went out, not after
    /// three 20 s waits.
    func testABlackHoleLinkFailsTheReadWhenTheWindowEnds() throws {
        let server = try startServer(body: makeBody(32 * 1024))
        server.delayForEveryRange = 3600
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        let pending = readAsync(source, 1)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 1 })

        clock.advance(by: GrowingFileByteSource.requestTimeoutSeconds - 0.5)
        XCTAssertEqual(source.requestsSentForTest, 1, "the first request was given up on before its header wait")

        // +20 s: the first wait ends; 0.1 s later the retry goes out with the short wait.
        clock.advance(by: 0.5 + GrowingFileDownload.Retry.firstBackoffSeconds + 0.01)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 2 }, "no retry after the first wait")
        // +28.1 s: the retry's wait ends; 0.2 s later the last one goes out with what is left of the window.
        clock.advance(by: GrowingFileByteSource.retryRequestTimeoutSeconds + GrowingFileDownload.Retry.firstBackoffSeconds * 2)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 }, "no retry inside the window")
        XCTAssertFalse(pending.finished(within: 0.1), "the read failed inside the window")

        clock.advance(by: 1.7 + 0.01)
        XCTAssertTrue(pending.finished(within: 10), "an attempt ran past the window's end")
        assertTransport(pending.result)
        XCTAssertEqual(clock.now - 1_000, GrowingFileDownload.Retry.linkWindowSeconds, accuracy: 0.05)
        XCTAssertEqual(server.requestedRanges, [0, 0, 0])
    }

    /// On the clock:the body falls silent and every request after it is swallowed.
    /// The window runs from the body's last byte, so the read fails 30 s after the link went quiet.
    /// Behind a redirect chain too, where the walk back through the chain after its end went
    /// unanswered gets the generous header wait: still cut at the window's end.
    func testASilentLinkMidBodyFailsTheReadThirtySecondsAfterItsLastByte() throws {
        for redirected in [false, true] {
            let body = makeBody(64 * 1024)
            let server = try startServer(body: body)
            server.stallsAfterBodyBytes = 20_000
            let clock = ManualGrowingFileClock()
            let source = makeSource(redirected ? server.redirectingURL(hops: 2) : server.url, clock: clock)
            XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
            XCTAssertTrue(waitUntil { source.snapshot.frontier == 20_000 })
            server.delayForEveryRange = 3600

            let rest = readAsync(source, Int.max)
            XCTAssertTrue(clock.drive(nil, timeout: 30) { rest.finished(within: 0) }, "the read never failed")
            assertTransport(rest.result)
            let quietFor = clock.now - 1_000
            XCTAssertGreaterThanOrEqual(quietFor, GrowingFileDownload.Retry.linkWindowSeconds - GrowingFileDownload.Retry.maxBackoffSeconds, "\(redirected)")
            XCTAssertLessThanOrEqual(quietFor, GrowingFileDownload.Retry.linkWindowSeconds + 1.5, "the window ran long: \(redirected)")
            XCTAssertEqual(server.requestedRanges.first, 0)
            XCTAssertTrue(server.requestedRanges.dropFirst().allSatisfy { $0 == 20_000 }, "a retry did not resume")
        }
    }

    /// The link drops mid-body and nothing answers for seconds (airplane mode). The three
    /// attempts must not run out in 0.7 s and fail the read, which the player takes for the end of
    /// the file. A connect nothing answered spends no attempt: the read waits out the outage, and the
    /// first request after it resumes the file from its frontier.
    func testAnOutageLongerThanTheRetriesIsWaitedOutAndResumesFromTheFrontier() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.closesAfterBodyBytes = 20_000
        server.outageAfterClose = 3600
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))

        let rest = readAsync(source, Int.max)
        // Twenty seconds of outage on the source's clock: well past the attempts a host's refusal
        // gets, well inside the link window.
        _ = clock.drive(source) { clock.now - 1_000 >= 20 }
        XCTAssertFalse(rest.finished(within: 0), "the outage failed the read")
        XCTAssertGreaterThan(
            server.requestHeads.count - server.requestedRanges.count, GrowingFileDownload.Retry.maxAttempts,
            "the outage was asked about more often than the attempts a host's refusal gets"
        )

        server.refuseRequests(for: 0)
        XCTAssertTrue(clock.drive(source) { rest.finished(within: 0) }, "the read never came back")
        XCTAssertEqual(try rest.result.get(), body.suffix(from: 10_000), "the outage failed the read")
        XCTAssertEqual(server.requestedRanges, [0, 20_000], "the retry did not resume from the frontier")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    /// The connection falls silent mid-body, open but sending nothing (a dead Wi-Fi, a host
    /// that stopped). The source's idle check ends it like a drop once the body has been silent for
    /// the idle timeout on its clock, and not before; the retry is the source's, not a reconnect
    /// from the player.
    func testASilentBodyIsEndedAfterTheIdleTimeoutAndRetried() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 20_000
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 20_000 })

        clock.advance(by: GrowingFileByteSource.idleTimeoutSeconds - 0.5)
        XCTAssertEqual(source.requestsSentForTest, 1, "a body silent for less than the idle timeout was ended")

        server.stallsAfterBodyBytes = nil
        clock.advance(by: 1)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 2 }, "the silence was never ended")
        XCTAssertEqual(try readToEnd(source), body.suffix(from: 10_000))
        XCTAssertEqual(server.requestedRanges, [0, 20_000], "the retry resumes from the frontier")
    }

    /// A chunk whose write is still on its way to disk when the idle check ends its task and the
    /// resume goes out is the old task's: it must not move the frontier the resume appends after,
    /// or every byte of the resumed body lands that many bytes late.
    func testAWriteStillInFlightAcrossAResumeIsDiscarded() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 256 * 1024
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var blockedAt: Int64?
        let store = makeStore(write: { fd, bytes, count, offset in
            lock.lock()
            let blocks = blockedAt == nil && offset >= 20_000
            if blocks { blockedAt = Int64(offset) }
            lock.unlock()
            if blocks {
                entered.signal()
                release.wait()
            }
            return Foundation.pwrite(fd, bytes, count, offset)
        })
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, store: store, clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
        XCTAssertEqual(entered.wait(timeout: .now() + 20), .success, "no write past 20 000 bytes")
        let frontier = try XCTUnwrap(lock.withLock { blockedAt })
        XCTAssertEqual(source.snapshot.frontier, frontier)

        // The body has been silent for the idle timeout on the clock (its chunk is stuck in the
        // write): the task is ended, and a backoff later the resume asks for the frontier.
        clock.advance(by: GrowingFileByteSource.idleTimeoutSeconds + GrowingFileDownload.Retry.firstBackoffSeconds + 0.01)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 2 }, "no resume")
        XCTAssertEqual(server.requestedRanges, [0, frontier])

        release.signal()
        XCTAssertEqual(try readToEnd(source), body.suffix(from: 10_000), "the old task's chunk moved the frontier")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    /// The idle check is on the body's silence, not its age: every chunk puts it off, so a slow
    /// body that keeps arriving is never ended however long it runs on the source's clock.
    func testEveryBodyChunkPutsOffTheIdleCheck() throws {
        let body = makeBody(1024 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 1), body.prefix(1))

        // Twice the idle timeout on the clock, a second at a time, with chunks arriving in between.
        for _ in 0..<Int(GrowingFileByteSource.idleTimeoutSeconds * 2) {
            let frontier = source.snapshot.frontier
            clock.advance(by: 1)
            XCTAssertTrue(waitUntil { source.snapshot.frontier > frontier }, "no chunk arrived")
        }
        XCTAssertEqual(server.requestedRanges, [0], "a body still arriving was ended")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    func testAFullDiskFailsTheReadAndDeletesThePartial() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 512 * 1024
        let lock = NSLock()
        var written = 0
        let store = makeStore(write: { fd, bytes, count, offset in
            lock.lock(); defer { lock.unlock() }
            guard written < 64 * 1024 else { errno = ENOSPC; return -1 }
            let n = Foundation.pwrite(fd, bytes, count, offset)
            if n > 0 { written += n }
            return n
        })
        let source = makeSource(server.url, store: store)

        let pending = readAsync(source, Int.max)
        XCTAssertTrue(pending.finished(within: 10))
        assertTransport(pending.result)
        XCTAssertEqual(partials(), [])
        XCTAssertNil(source.snapshot.fileURL)
        XCTAssertEqual(server.requestedRanges, [0], "a full disk is not retried")
    }
}
