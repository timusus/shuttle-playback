import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
    // MARK: - Recovery

    /// A read that failed past the link window takes its transaction with it, but not the total
    /// length, and the failure sticks: a read without a seek throws it again and asks nothing.
    /// The read after a seek to where it stopped (Play on the player's error) asks again there,
    /// with a fresh budget, and that request is no seek's.
    func testAFailedReadIsStickyUntilASeekWhoseReadAsksAgainAtItsPosition() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.closesAfterBodyBytes = 20_000
        server.outageAfterClose = 3600
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))

        source.willSeek(generation: 5)
        source.willSeek(generation: nil)
        let failed = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source, timeout: 60) { failed.finished(within: 0) }, "the window never closed")
        assertTransport(failed.result)
        XCTAssertEqual(source.totalLength, Int64(body.count), "the failure forgot the length")
        XCTAssertEqual(source.snapshot.totalLength, source.totalLength, "the snapshot and the reader disagree")

        server.refuseRequests(for: 0)
        let requests = server.requestHeads.count
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(try source.read(into: &buffer, maxLength: buffer.count), "a read after the failure, no seek")
        XCTAssertEqual(server.requestHeads.count, requests, "a read without a seek opened a transaction")

        let at = Int(source.position)
        source.willSeek(generation: nil)
        try source.seek(to: Int64(at))
        let rest = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source) { rest.finished(within: 0) }, "the read after the failure never came back")
        XCTAssertEqual(try rest.result.get(), body.suffix(from: at))
        XCTAssertEqual(server.requestedRanges.last, Int64(at), "the next read did not ask at its position")
        XCTAssertNil(events.transactions.last?.seekGenerationForTest)
    }

    /// A download that has finished is never asked for again, however long the listener
    /// sits on it: no retry, no idle timeout, no new transaction, and no seek generation spent.
    func testAFinishedDownloadNeverAsksAgainOrSeeks() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })

        // Well past the idle timeout and the link window on the source's clock.
        clock.advance(by: GrowingFileDownload.Retry.linkWindowSeconds * 2)
        XCTAssertEqual(source.requestsSentForTest, 1)
        XCTAssertEqual(try readToEnd(source), body.suffix(from: 1000))
        XCTAssertEqual(server.requestedRanges, [0])
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
        XCTAssertNil(source.snapshot.seekGeneration)
        XCTAssertEqual(events.transactions.count, 1)
    }

    func testAWaitForAGapEndsInARestartWhenTheDownloadStops() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 64 * 1024
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        _ = try read(source, 1)
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 64 * 1024 })

        // A short gap at a high rate is waited for; the rate then decays to nothing, and only the
        // read looking again on its own turns that wait into a restart.
        try source.seek(to: 74 * 1024)
        let pending = readAsync(source, 100)
        XCTAssertTrue(waitUntil { source.parkCount > 0 }, "the gap was not waited for")
        XCTAssertTrue(clock.drive(nil) { pending.finished(within: 0) }, "the wait never looked again")
        XCTAssertEqual(try pending.result.get(), body.subdata(in: 74 * 1024..<74 * 1024 + 100))
        XCTAssertEqual(source.snapshot.base, 74 * 1024)
    }

    func testAnExpiredRedirectEndFallsBackToTheChain() throws {
        let body = makeBody(128 * 1024)
        let server = try startServer(body: body)
        server.redirectsToAlternateHost = true
        let source = makeSource(server.redirectingURL(hops: 1))
        try source.seek(to: 100_000)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100_000..<100_100))

        // The signed hop expires and the chain now ends somewhere else.
        server.reject(host: "localhost:\(server.port)", status: 403)
        server.redirectsToAlternateHost = false
        try source.seek(to: 0)
        XCTAssertEqual(try read(source, 100), body.prefix(100))
        let heads = server.requestHeads
        XCTAssertEqual(heads.filter { $0.contains("Host: localhost:") && $0.hasPrefix("GET \(LoopbackMediaServer.fixturePath)") }.count, 2,
                       "the first transaction, then the expired end once: \(heads)")
        XCTAssertEqual(heads.filter { $0.hasPrefix("GET /redirect/1/") }.count, 2, "the chain is walked again")
    }

    /// A long redirect chain that is alive but slower than a retry's header wait, ending at a host
    /// that answers at once: the resume after a mid-body drop goes straight to the end instead of
    /// walking the chain again, so the slow chain never fails the read.
    func testAResumeAfterADropGoesStraightToTheChainsEndPastASlowChain() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.closesAfterBodyBytes = 20_000
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.redirectingURL(hops: 2), clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 20_000 })
        server.delayForRedirectHops = 60

        let rest = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source) { rest.finished(within: 0) }, "the read never came back")
        XCTAssertEqual(try rest.result.get(), body.suffix(from: 10_000))
        XCTAssertEqual(server.requestedRanges, [0, 20_000], "the retry did not resume from the frontier")
        XCTAssertEqual(server.requestHeads.filter { $0.hasPrefix("GET /redirect/") }.count, 2, "the resume walked the chain again")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    /// The chain's end refuses the resume (its signature expired): the next request walks the
    /// chain from the requested URL, once, with the generous header wait however slow the chain,
    /// and resumes the same file from wherever the chain ends now.
    func testAResumeTheChainsEndRefusesFallsBackToTheChainWithTheGenerousWait() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.redirectsToAlternateHost = true
        server.closesAfterBodyBytes = 20_000
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.redirectingURL(hops: 1), clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 20_000 })
        server.reject(host: "localhost:\(server.port)", status: 403)
        server.redirectsToAlternateHost = false
        server.delayForRedirectHops = 1

        let rest = readAsync(source, Int.max)
        let chainWalks = { server.requestHeads.filter { $0.hasPrefix("GET /redirect/1/") }.count }
        XCTAssertTrue(clock.drive(source, step: 0.05) { chainWalks() == 2 }, "the refused end never fell back to the chain")
        XCTAssertEqual(server.requestedRanges, [0, 20_000], "the resume went to the end first")
        // Longer than a retry's wait, shorter than the generous one: the slow hop is waited for.
        clock.advance(by: GrowingFileByteSource.retryRequestTimeoutSeconds + 2)
        XCTAssertTrue(rest.finished(within: 10), "the walk back through the chain was given up on")
        XCTAssertEqual(try rest.result.get(), body.suffix(from: 10_000))
        XCTAssertEqual(server.requestedRanges, [0, 20_000, 20_000], "the fallback resumes from the frontier")
        XCTAssertEqual(chainWalks(), 2, "the chain is walked again once")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    func testAMismatchedContentRangeAndRefusedStatusesFailTheReadAfterTheRetries() throws {
        let body = makeBody(32 * 1024)
        // Past the end, the loopback answers the last byte: a 206 that does not start where asked.
        let mismatched = try startServer(body: body)
        let source = makeSource(mismatched.url)
        try source.seek(to: Int64(body.count) + 10)
        let pending = readAsync(source, 1)
        XCTAssertTrue(pending.finished(within: 20))
        assertTransport(pending.result)
        XCTAssertEqual(mismatched.requestedRanges.count, 1 + GrowingFileDownload.Retry.maxAttempts)

        for status in [404, 416] {
            let server = try startServer(body: body)
            server.reject(host: "127.0.0.1:\(server.port)", status: status)
            let pending = readAsync(makeSource(server.url), 1)
            XCTAssertTrue(pending.finished(within: 20), "\(status)")
            assertTransport(pending.result)
            XCTAssertEqual(server.requestHeads.count, 1 + GrowingFileDownload.Retry.maxAttempts, "\(status)")
        }
    }

    // MARK: - Network path changes

    static let wifi = GrowingFilePathMonitor.Path(satisfied: true, interface: "en0")
    static let cellular = GrowingFilePathMonitor.Path(satisfied: true, interface: "pdp_ip0")
    static let offline = GrowingFilePathMonitor.Path(satisfied: false, interface: nil)

    /// Wi-Fi drops to cellular while the body is stalled on the old path: the transaction is
    /// reopened from the frontier a backoff after the change, long before the idle timeout, and the
    /// bytes are the file's. The path the monitor starts with, the same path again and a path that
    /// cannot be used change nothing.
    func testANewNetworkPathReopensAStalledBodyFromTheFrontierAtOnce() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 20_000
        let clock = ManualGrowingFileClock()
        let monitor = GrowingFilePathMonitor()
        let source = makeSource(server.url, clock: clock, pathMonitor: monitor)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 20_000 })

        monitor.update(Self.wifi)
        monitor.update(Self.wifi)
        monitor.update(Self.offline)
        clock.advance(by: 1)
        XCTAssertEqual(source.requestsSentForTest, 1, "a path that was no change reopened the transaction")

        server.stallsAfterBodyBytes = nil
        monitor.update(Self.cellular)
        clock.advance(by: GrowingFileDownload.Retry.firstBackoffSeconds + 0.01)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 2 }, "the new path did not reopen the transaction")
        XCTAssertLessThan(clock.now - 1_000, GrowingFileByteSource.idleTimeoutSeconds / 2)
        XCTAssertEqual(try readToEnd(source), body.suffix(from: 10_000))
        XCTAssertEqual(server.requestedRanges, [0, 20_000], "the reopen resumes from the frontier")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    /// A reopen for a path change is a failure the host answered like any other: it spends one of
    /// ``GrowingFileDownload/Retry/maxAttempts``, the budget a refused resume spends too. With every resume
    /// after it refused, the read fails one resume sooner than on refusals alone: no second budget.
    func testAPathChangeReopenSpendsTheSameRetryBudget() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 20_000
        let clock = ManualGrowingFileClock()
        let monitor = GrowingFilePathMonitor()
        let source = makeSource(server.url, clock: clock, pathMonitor: monitor)
        XCTAssertEqual(try read(source, 20_000), body.prefix(20_000))
        let rest = readAsync(source, Int.max)
        XCTAssertTrue(waitUntil { source.parkCount > 0 })

        server.reject(host: "127.0.0.1:\(server.url.port!)", status: 503)
        monitor.update(Self.wifi)
        monitor.update(Self.cellular)
        // The backoffs only: a body silent past the idle timeout would be ended by the idle check.
        XCTAssertTrue(clock.drive(source, step: 0.1) { rest.finished(within: 0) }, "the read never failed")
        assertTransport(rest.result)
        XCTAssertEqual(
            server.requestedRanges, [0] + Array(repeating: 20_000, count: GrowingFileDownload.Retry.maxAttempts),
            "the path change did not spend an attempt: one resume too many, or too few (a second budget)"
        )
        XCTAssertLessThan(clock.now - 1_000, GrowingFileByteSource.idleTimeoutSeconds)
    }

    /// What counts as a change, with literal paths.
    func testOnlyAUsablePathThatReplacesAnotherIsAChange() {
        typealias Monitor = GrowingFilePathMonitor
        XCTAssertFalse(Monitor.isChange(from: nil, to: Self.wifi), "the path the monitor starts with")
        XCTAssertFalse(Monitor.isChange(from: Self.wifi, to: Self.wifi), "the same path again")
        XCTAssertFalse(Monitor.isChange(from: Self.wifi, to: Self.offline), "a path that cannot be used")
        XCTAssertTrue(Monitor.isChange(from: Self.wifi, to: Self.cellular), "Wi-Fi to cellular")
        XCTAssertTrue(Monitor.isChange(from: Self.offline, to: Self.wifi), "back after none")
        XCTAssertFalse(Monitor.isChange(from: Self.wifi, to: Self.hotspot), "a change in cost alone")
        XCTAssertFalse(Monitor.isChange(from: Self.wifi, to: Self.lowDataWifi), "Low Data Mode toggled")
        XCTAssertTrue(Monitor.isChange(from: Self.hotspot, to: Self.expensiveCellular))
    }

}
