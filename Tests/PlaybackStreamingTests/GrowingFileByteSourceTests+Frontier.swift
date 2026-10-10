import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
    // MARK: - The frontier

    /// On a clock that never moves: the 1.5 s body is real time, and on the system clock a stall
    /// of the test process (a loaded machine) is a response or a body gone silent past its
    /// timeout, which the source rightly ends and retries. Those timeouts have tests of their own.
    func testAReadAtTheFrontierBlocksThenResumesAndEndsOnlyAtTheEnd() throws {
        let body = makeBody(96 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        let source = makeSource(server.url, clock: ManualGrowingFileClock())

        let pending = readAsync(source, Int.max)
        XCTAssertTrue(waitUntil { source.parkCount > 0 }, "the read waits for the body")
        XCTAssertTrue(pending.finished(within: 20))

        XCTAssertEqual(try pending.result.get(), body)
        XCTAssertEqual(server.requestedRanges, [0])
        XCTAssertEqual(source.totalLength, Int64(body.count))
        // The last byte can reach the reader before the task's completion does.
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
        XCTAssertNotNil(source.snapshot.downloadBytesPerSecond)
        // The read events come on the decoder's thread and the download's on the delegate queue,
        // unordered between the two: the last read's `.readResumed` may follow the completion.
        let downloads = { self.events.events.filter { if case .download = $0 { return true } else { return false } } }
        XCTAssertTrue(downloads().contains { if case .download(_, _, false) = $0 { return true } else { return false } })
        XCTAssertTrue(waitUntil {
            if case .download(Int64(body.count), _, true) = downloads().last { return true } else { return false }
        }, "the last download event is the completion")
        let reads = events.events.filter {
            switch $0 { case .readWaiting, .readResumed: return true; default: return false }
        }
        XCTAssertEqual(reads.last, .readResumed, "every wait the read announced ended")
    }

    /// A drop mid-body keeps the file: the retry asks for the frontier and appends to it, so
    /// nothing the download already had ahead of the decoder comes over the network twice.
    func testAMidBodyDropResumesFromTheFrontierIntoTheSameFile() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        let head = try read(source, 4096)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 2 })
        XCTAssertEqual(server.requestedRanges, [0, 100_000], "the retry asks for the frontier, not the decoder's position")
        XCTAssertTrue(server.requestHeads.last?.lowercased().contains("range: bytes=100000-") ?? false)
        let rest = try readToEnd(source)
        XCTAssertEqual(head + rest, body)
        XCTAssertEqual(server.servedBytes, Int64(body.count), "a byte already on disk was fetched again")
        XCTAssertEqual(source.snapshot.base, 0)
        XCTAssertEqual(source.snapshot.transactionGeneration, 1, "a resume is the same file")
        XCTAssertEqual(events.transactions.count, 1, "a resume opens no transaction")
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))
        XCTAssertEqual(try Data(contentsOf: cached), body)
    }

    /// The host answers the resume with the whole body: the range is ignored, so the retry
    /// restarts at the decoder's position as it always did, and the read waits for that position.
    func testAResumeAnsweredWithTheWholeBodyRestartsAtTheReadPosition() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        server.respondsWholeBodyIgnoringRange = true
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        let head = try read(source, 4096)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertEqual(server.requestedRanges, [0, 100_000, 4096])
        XCTAssertEqual(head + (try readToEnd(source)), body)
        XCTAssertEqual(source.snapshot.base, 0)
        XCTAssertEqual(source.snapshot.transactionGeneration, 3, "the restart, then its base moved to 0")
    }

    /// The host spliced different content in between the drop and the resume (the total moved): its bytes are not
    /// this file's end, so the retry is a restart at the decoder's position into a new file.
    func testAResumeIntoADifferentSpliceRestartsIntoANewFile() throws {
        let first = makeBody(160_000)
        let second = makeBody(200_000, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), first.prefix(4096))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertEqual(server.requestedRanges, [0, 100_000, 4096])
        XCTAssertEqual(try readToEnd(source), second.suffix(from: 4096), "the new splice was spliced onto the old")
        XCTAssertEqual(source.snapshot.base, 4096)
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
        XCTAssertEqual(source.totalLength, 200_000)
        XCTAssertNil(events.transactions.last?.seekGenerationForTest)
    }

    /// The restart after a refused resume is a retry: it waits a retry's header time, not a first
    /// request's, so a link that dies under it is asked again inside the window.
    func testTheRestartAfterARefusedResumeWaitsARetrysHeaderTime() throws {
        let first = makeBody(64 * 1024)
        let second = makeBody(48 * 1024, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        server.closesAfterBodyBytes = 20_000
        server.delayForRangeStartingAt = (offset: 10_000, seconds: 3600)
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 10_000), first.prefix(10_000))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 20_000 })

        // The drop's close lands a moment after its last byte: step until the restart goes out.
        XCTAssertTrue(clock.drive(source, step: 0.01) { server.requestedRanges.count == 3 }, "no restart after the refused resume")
        XCTAssertEqual(server.requestedRanges, [0, 20_000, 10_000])
        clock.advance(by: GrowingFileByteSource.retryRequestTimeoutSeconds - 0.5)
        XCTAssertEqual(source.requestsSentForTest, 3, "the restart was given up on before a retry's wait")
        clock.advance(by: 0.5 + GrowingFileDownload.Retry.firstBackoffSeconds * 2 + 0.1)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 4 }, "the restart waited longer than a retry's wait")
        XCTAssertEqual(server.requestedRanges.last, 10_000)
    }

    func testASeekNearTheFrontierWaitsAndAFarOneIsANewTransaction() throws {
        let body = makeBody(512 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        server.delayForEveryRange = 1
        let source = makeSource(server.url)

        _ = try read(source, 1)
        XCTAssertTrue(waitUntil { source.snapshot.frontier >= 32 * 1024 })
        let near = source.snapshot.frontier + 24 * 1024
        try source.seek(to: near)
        XCTAssertEqual(try read(source, 1000), body.subdata(in: Int(near)..<Int(near) + 1000))
        XCTAssertEqual(source.snapshot.transactionGeneration, 1, "about 0.4 s away, a request 1 s: the read waited")

        source.willSeek(generation: 7)
        try source.seek(to: 400_000)
        XCTAssertEqual(source.snapshot.transactionGeneration, 1, "the decision is the read's, not the seek's")
        XCTAssertEqual(try read(source, 1000), body.subdata(in: 400_000..<401_000))
        let snapshot = source.snapshot
        XCTAssertEqual(snapshot.transactionGeneration, 2)
        XCTAssertEqual(snapshot.base, 400_000)
        XCTAssertEqual(snapshot.seekGeneration, 7)
        XCTAssertEqual(server.requestedRanges, [0, 400_000])
        XCTAssertEqual(events.transactions, [
            .transaction(base: 0, generation: 1, seekGeneration: nil, httpStatus: 206),
            .transaction(base: 400_000, generation: 2, seekGeneration: 7, httpStatus: 206),
        ])

        try source.seek(to: 100)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100..<200), "before the base is read from the file")
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
        XCTAssertEqual(server.requestedRanges, [0, 400_000])
    }

    /// Issue #68: a far seek the download would close in a couple of seconds is still a new
    /// request when a request answers sooner, as media3's `seekToUs` resets the loader at the target.
    /// On a throttled link with a 0.3 s response latency, the first byte at the target arrives
    /// well before the 2.5 s the running download would take (the rule itself is pinned with a
    /// manual clock in `GrowingFileDownloadTests`; this bound is coarse on purpose).
    func testAFarSeekThatARequestAnswersSoonerThanTheDownloadIsANewRequest() throws {
        let rate = 128 * 1024
        let latency = 0.3
        let body = makeBody(2 * 1024 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = rate
        server.delayForEveryRange = latency
        let source = makeSource(server.url)

        _ = try read(source, 1)
        XCTAssertTrue(waitUntil { source.snapshot.frontier >= 128 * 1024 })
        let target = source.snapshot.frontier + Int64(rate) * 5 / 2
        try source.seek(to: target)
        let started = Date()
        XCTAssertEqual(try read(source, 1000), body.subdata(in: Int(target)..<Int(target) + 1000))
        let waited = Date().timeIntervalSince(started)
        XCTAssertLessThan(waited, 2, "the seek waited for the running download, which needs 2.5 s")
        XCTAssertEqual(server.requestedRanges, [0, target])
    }

    func testTheProbesFooterLookIsEndOfStreamAndLeavesTheHeadDownloading() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 32 * 1024
        let source = makeSource(server.url)

        source.isProbing = true
        _ = try read(source, 100)
        try source.seek(to: Int64(body.count) - 100)
        XCTAssertEqual(try read(source, 100), Data(), "an ID3v1 look at the tail")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
        source.isProbing = false

        try source.seek(to: 100)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100..<200))
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
        XCTAssertEqual(server.requestedRanges, [0])

        try source.seek(to: Int64(body.count) - 100)
        XCTAssertEqual(try read(source, 100), body.suffix(100), "outside the probe the tail is fetched")
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
    }

    func testAHostThatIgnoresTheRangeIsAFileFromByteZeroAndTheReadWaitsForItsPosition() throws {
        let body = makeBody(128 * 1024)
        let server = try startServer(body: body)
        server.respondsWholeBodyIgnoringRange = true
        let source = makeSource(server.url)

        try source.seek(to: 50_000)
        XCTAssertEqual(try readToEnd(source), body.suffix(from: 50_000))
        XCTAssertEqual(source.snapshot.base, 0)
        XCTAssertEqual(source.snapshot.transactionGeneration, 2, "a base moved from 50 000 to 0 is a new generation")
        XCTAssertEqual(events.transactions, [.transaction(base: 0, generation: 2, seekGeneration: nil, httpStatus: 200)])
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        XCTAssertNotNil(GrowingFileStore(directory: directory).completedFile(for: server.url))
    }

    func testAHostThatIgnoresTheRangeAndDropsBeforeTheReadPositionFailsTheRead() throws {
        let body = makeBody(128 * 1024)
        let server = try startServer(body: body)
        server.respondsWholeBodyIgnoringRange = true
        server.contentLengthLie = 50_000
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)

        try source.seek(to: 100_000)
        let pending = readAsync(source, 100)
        XCTAssertTrue(clock.drive(source) { pending.finished(within: 0) }, "every restart is from byte 0 and ends before 100 000")
        assertTransport(pending.result)
        XCTAssertEqual(server.requestedRanges.count, 1 + GrowingFileDownload.Retry.maxAttempts)
    }

    func testAuthHeadersRideEveryRequestAndRedirectHopAndRestartsGoStraightToTheEnd() throws {
        let body = makeBody(128 * 1024)
        let server = try startServer(body: body)
        let source = makeSource(server.redirectingURL(hops: 2), authHeaders: ["Authorization": "Basic c2VjcmV0"])

        try source.seek(to: 100_000)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100_000..<100_100))
        try source.seek(to: 0)
        XCTAssertEqual(try read(source, 100), body.prefix(100))

        let heads = server.requestHeads
        XCTAssertEqual(heads.count, 4, "two hops, the first transaction, then the restart without hops")
        for head in heads {
            XCTAssertTrue(head.lowercased().contains("authorization: basic c2vjcmv0"), head)
        }
        XCTAssertTrue(heads[3].hasPrefix("GET \(LoopbackMediaServer.fixturePath)"), heads[3])
        XCTAssertEqual(server.requestedRanges, [100_000, 0])
    }

    // MARK: - Connection policy

    private func headsFrom(_ server: LoopbackMediaServer, hostPrefix: String) -> [String] {
        server.requestHeads.filter { $0.lowercased().contains("host: \(hostPrefix)") }
    }

    func testServerHeadersAreDroppedOnARedirectToAnotherHostAndKeptOnTheSameHost() throws {
        let body = makeBody(64 * 1024)
        let headers = ["Authorization": "Basic c2VjcmV0", "X-Server-Token": "abc"]
        let policy = GrowingFileConnectionPolicy(headers: ["X-Policy": "yes"])

        let crossing = try startServer(body: body)
        crossing.redirectsToAlternateHost = true
        let crossingSource = makeSource(crossing.redirectingURL(hops: 1), authHeaders: headers, connectionPolicy: policy)
        XCTAssertEqual(try read(crossingSource, 100), body.prefix(100))
        let first = headsFrom(crossing, hostPrefix: "127.0.0.1").map { $0.lowercased() }
        let landed = headsFrom(crossing, hostPrefix: "localhost").map { $0.lowercased() }
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].contains("x-server-token: abc") && first[0].contains("x-policy: yes") && first[0].contains("authorization:"))
        XCTAssertEqual(landed.count, 1, "the hop landed on localhost")
        for field in ["authorization", "x-server-token", "x-policy"] {
            XCTAssertFalse(landed[0].contains("\(field):"), "\(field) leaked to another origin: \(landed[0])")
        }
        XCTAssertTrue(landed[0].contains("range: bytes=0-"), "the range still rides the hop")

        // A restart goes straight to the remembered end, another origin, and sends none either.
        try crossingSource.seek(to: 40_000)
        XCTAssertEqual(try read(crossingSource, 100), body.subdata(in: 40_000..<40_100))
        let restart = try XCTUnwrap(headsFrom(crossing, hostPrefix: "localhost").last).lowercased()
        XCTAssertFalse(restart.contains("authorization:") || restart.contains("x-policy:"), restart)

        let staying = try startServer(body: body)
        let stayingSource = makeSource(staying.redirectingURL(hops: 2), authHeaders: headers, connectionPolicy: policy)
        XCTAssertEqual(try read(stayingSource, 100), body.prefix(100))
        XCTAssertEqual(staying.requestHeads.count, 3)
        for head in staying.requestHeads.map({ $0.lowercased() }) {
            XCTAssertTrue(head.contains("x-server-token: abc") && head.contains("x-policy: yes") && head.contains("authorization:"), head)
        }
    }

    func testAnUntrustedCertificateFailsTheReadAtOnceAndIsNotRetried() throws {
        // The loopback server speaks no TLS, so the challenge itself cannot be driven end to end: the
        // trust decision is tested in GrowingFileConnectionPolicyTests, and the rejection it makes is
        // applied to a request in flight here.
        let server = try startServer(body: makeBody(64 * 1024))
        server.delayForEveryRange = 30
        let policy = GrowingFileConnectionPolicy(trustedLeafSHA256: [String(repeating: "AB", count: 32)])
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, connectionPolicy: policy, clock: clock)
        let pending = readAsync(source, 100)
        XCTAssertTrue(waitUntil { server.requestHeads.count == 1 && source.currentTask != nil })
        source.certificateRejected(task: try XCTUnwrap(source.currentTask))

        XCTAssertTrue(pending.finished(within: 5), "a refused certificate fails the read without waiting out a retry")
        guard case .transport(let reason)? = readerError(pending.result) else { return XCTFail("\(pending.result)") }
        XCTAssertEqual(reason, GrowingFileConnectionPolicy.untrustedCertificateReason)
        clock.advance(by: GrowingFileDownload.Retry.linkWindowSeconds)
        XCTAssertEqual(source.requestsSentForTest, 1, "no retry")
    }

    // MARK: - Network cost

    /// The whole file is fetched on every network, and Low Data Mode is treated like
    /// cellular, with no special case. A session that refused expensive or constrained paths
    /// would stop playback on cellular or in Low Data Mode instead.
    func testThePlaybackSessionFetchesOnCellularAndInLowDataModeAlike() {
        let configuration = GrowingFileByteSource.sharedSession.configuration
        XCTAssertTrue(configuration.allowsCellularAccess)
        XCTAssertTrue(configuration.allowsExpensiveNetworkAccess)
        XCTAssertTrue(configuration.allowsConstrainedNetworkAccess)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, GrowingFileByteSource.requestTimeoutSeconds)
        XCTAssertGreaterThan(
            GrowingFileByteSource.requestTimeoutSeconds, GrowingFileByteSource.idleTimeoutSeconds * 2,
            "the headers' wait is the generous one"
        )
    }

}
