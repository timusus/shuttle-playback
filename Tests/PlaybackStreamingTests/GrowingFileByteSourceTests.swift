import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

/// The growing-file byte source against a loopback origin and its fault knobs. Every read here is the decoder's: it blocks, and a 0 is the end.
final class GrowingFileByteSourceTests: XCTestCase {

    static let testSession = GrowingFileByteSource.makeSession(configuration: .ephemeral)

    private var directory: URL!
    private var servers: [LoopbackMediaServer] = []
    private var sources: [GrowingFileByteSource] = []
    private let events = EventRecorder()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("growing-source-\(UUID().uuidString)")
    }

    override func tearDown() {
        // A running task retains its delegate, so a source that is never cancelled outlives the test.
        sources.forEach { $0.cancel() }
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Helpers

    final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [GrowingFileEvent] = []
        var events: [GrowingFileEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        func append(_ event: GrowingFileEvent) { lock.lock(); _events.append(event); lock.unlock() }
        var transactions: [GrowingFileEvent] {
            events.filter { if case .transaction = $0 { return true } else { return false } }
        }
    }

    /// Deterministic pseudo-random bytes behind an ID3 tag, so the body passes the media sniff.
    private func makeBody(_ count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> Data {
        var state = seed
        var bytes = [UInt8](Data("ID3\u{04}\u{00}\u{00}\u{00}\u{00}\u{00}\u{00}".utf8))
        bytes.reserveCapacity(count)
        while bytes.count < count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes.append(UInt8(truncatingIfNeeded: state))
        }
        return Data(bytes.prefix(count))
    }

    private func startServer(body: Data, mimeType: String = "audio/mpeg") throws -> LoopbackMediaServer {
        let server = try LoopbackMediaServer(body: body, mimeType: mimeType)
        servers.append(server)
        return server
    }

    private func makeStore(write: GrowingFileStore.WriteFunction? = nil) -> GrowingFileStore {
        if let write { return GrowingFileStore(directory: directory, write: write) }
        return GrowingFileStore(directory: directory)
    }

    private func makeSource(
        _ url: URL, store: GrowingFileStore? = nil, authHeaders: [String: String] = [:],
        cacheKey: URL? = nil, connectionPolicy: GrowingFileConnectionPolicy? = nil,
        clock: GrowingFileClock = SystemGrowingFileClock.shared, session: URLSession = GrowingFileByteSourceTests.testSession,
        pathMonitor: GrowingFilePathMonitor = GrowingFilePathMonitor(), readAhead: GrowingFileReadAhead? = nil
    ) -> GrowingFileByteSource {
        let recorder = events
        let source = GrowingFileByteSource(
            url: url, authHeaders: authHeaders, cacheKey: cacheKey, connectionPolicy: connectionPolicy,
            readAhead: readAhead, store: store ?? makeStore(), session: session,
            clock: clock, pathMonitor: pathMonitor, onEvent: { recorder.append($0) }
        )
        sources.append(source)
        return source
    }

    /// Reads exactly `count` bytes, or fewer at the end of the stream.
    private func read(_ source: GrowingFileByteSource, _ count: Int) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while out.count < count {
            let got = try buffer.withUnsafeMutableBytes {
                try source.read(into: $0.baseAddress!, maxLength: min($0.count, count - out.count))
            }
            if got == 0 { break }
            out.append(contentsOf: buffer[0..<got])
        }
        return out
    }

    private func readToEnd(_ source: GrowingFileByteSource) throws -> Data {
        try read(source, Int.max)
    }

    /// A blocking read running off the test thread.
    final class PendingRead: @unchecked Sendable {
        struct StillBlocked: Error {}

        private let group = DispatchGroup()
        private let lock = NSLock()
        private var _result: Result<Data, Error>?

        init(_ body: @escaping () throws -> Data) {
            group.enter()
            DispatchQueue.global().async {
                let result = Result { try body() }
                self.lock.lock(); self._result = result; self.lock.unlock()
                self.group.leave()
            }
        }

        /// Whether the read returned within `timeout`.
        func finished(within timeout: TimeInterval) -> Bool {
            group.wait(timeout: .now() + timeout) == .success
        }

        /// What the read returned, waiting up to 10 s for it.
        var result: Result<Data, Error> {
            _ = group.wait(timeout: .now() + 10)
            lock.lock(); defer { lock.unlock() }
            return _result ?? .failure(StillBlocked())
        }
    }

    private func readAsync(_ source: GrowingFileByteSource, _ count: Int) -> PendingRead {
        PendingRead { try self.read(source, count) }
    }

    /// Generous by default: a condition that holds returns at once, and the machine may be loaded.
    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func partials() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".partial") }
    }

    private func readerError(_ result: Result<Data, Error>) -> StreamByteReaderError? {
        guard case .failure(let error) = result else { return nil }
        return error as? StreamByteReaderError
    }

    private func assertTransport(_ result: Result<Data, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .transport? = readerError(result) else {
            return XCTFail("expected .transport, got \(result)", file: file, line: line)
        }
    }

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
        XCTAssertTrue(events.events.contains { if case .download(_, _, false) = $0 { return true } else { return false } })
        XCTAssertTrue(waitUntil {
            if case .download(Int64(body.count), _, true) = self.events.events.last { return true } else { return false }
        }, "the last event is the completion")
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
        XCTAssertTrue(clock.drive(step: 0.01) { server.requestedRanges.count == 3 }, "no restart after the refused resume")
        XCTAssertEqual(server.requestedRanges, [0, 20_000, 10_000])
        clock.advance(by: GrowingFileByteSource.retryRequestTimeoutSeconds - 0.5)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(server.requestedRanges.count, 3, "the restart was given up on before a retry's wait")
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
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100..<200), "before the base restarts")
        XCTAssertEqual(source.snapshot.transactionGeneration, 3)
    }

    /// Issue #68: a far seek the download would close in a couple of seconds is still a new
    /// request when a request answers sooner, as media3's `seekToUs` resets the loader at the target.
    /// On a throttled link with a 0.3 s response latency, the first byte at the target arrives
    /// within that latency and a margin, not after the 2.5 s the running download would take.
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
        XCTAssertLessThan(waited, latency + 0.5, "the seek waited for the running download")
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
        let source = makeSource(server.url)

        try source.seek(to: 100_000)
        let pending = readAsync(source, 100)
        XCTAssertTrue(pending.finished(within: 20), "every restart is from byte 0 and ends before 100 000")
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
        let source = makeSource(server.url, connectionPolicy: policy)
        let pending = readAsync(source, 100)
        XCTAssertTrue(waitUntil { server.requestHeads.count == 1 && source.currentTask != nil })
        source.certificateRejected(task: try XCTUnwrap(source.currentTask))

        XCTAssertTrue(pending.finished(within: 5), "a refused certificate fails the read without waiting out a retry")
        guard case .transport(let reason)? = readerError(pending.result) else { return XCTFail("\(pending.result)") }
        XCTAssertEqual(reason, GrowingFileConnectionPolicy.untrustedCertificateReason)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(server.requestHeads.count, 1, "no retry")
    }

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
        let source = makeSource(server.url)

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
        let pending = readAsync(makeSource(longer.url, clock: clock), 1)
        XCTAssertTrue(clock.drive { pending.finished(within: 0) }, "the window never closed")
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
        let pending = readAsync(makeSource(server.url, clock: clock), 1)
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 1 })

        clock.advance(by: GrowingFileByteSource.requestTimeoutSeconds - 0.5)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(server.requestedRanges.count, 1, "the first request was given up on before its header wait")

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
            XCTAssertTrue(clock.drive(timeout: 30) { rest.finished(within: 0) }, "the read never failed")
            assertTransport(rest.result)
            let quietFor = clock.now - 1_000
            XCTAssertGreaterThanOrEqual(quietFor, GrowingFileDownload.Retry.linkWindowSeconds - GrowingFileDownload.Retry.maxBackoffSeconds, "\(redirected)")
            XCTAssertLessThanOrEqual(quietFor, GrowingFileDownload.Retry.linkWindowSeconds + 1.5, "the window ran long: \(redirected)")
            XCTAssertEqual(server.requestedRanges.first, 0)
            XCTAssertTrue(server.requestedRanges.dropFirst().allSatisfy { $0 == 20_000 }, "a retry did not resume")
        }
    }

    /// The link drops mid-body and nothing answers for seconds (airplane mode). The three
    /// attempts used to go in 0.7 s and the read failed, which the player took for the end of the
    /// file. A connect nothing answered spends no attempt: the read waits out the outage, and the
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
        _ = clock.drive { clock.now - 1_000 >= 20 }
        XCTAssertFalse(rest.finished(within: 0), "the outage failed the read")
        XCTAssertGreaterThan(
            server.requestHeads.count - server.requestedRanges.count, GrowingFileDownload.Retry.maxAttempts,
            "the outage was asked about more often than the attempts a host's refusal gets"
        )

        server.refuseRequests(for: 0)
        XCTAssertTrue(clock.drive { rest.finished(within: 0) }, "the read never came back")
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
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(server.requestedRanges, [0], "a body silent for less than the idle timeout was ended")

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
            clock.advance(by: 1)
            Thread.sleep(forTimeInterval: 0.06)
        }
        XCTAssertEqual(server.requestedRanges, [0], "a body still arriving was ended")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    /// A host slower to its first byte than the body's idle timeout (a cold origin, a chain of
    /// a long redirect chain) is waited for: the idle check starts with the response, and the
    /// session gives the headers ``GrowingFileByteSource/requestTimeoutSeconds``. Real time, on the
    /// system clock, because the session's timeout is real time.
    func testAResponseSlowerThanTheIdleTimeoutIsWaitedFor() throws {
        let body = makeBody(32 * 1024)
        let server = try startServer(body: body)
        server.delayForEveryRange = GrowingFileByteSource.idleTimeoutSeconds + 1
        let source = makeSource(server.redirectingURL(hops: 1))

        XCTAssertEqual(try read(source, 1000), body.prefix(1000))
        XCTAssertEqual(server.requestedRanges, [0], "the slow response was given up on")
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

    func testAPageInsteadOfAudioFailsTheRead() throws {
        let page = Data("<!DOCTYPE html><html><body>expired</body></html>".utf8)
        for mimeType in ["text/html; charset=utf-8", "application/octet-stream"] {
            let server = try startServer(body: page, mimeType: mimeType)
            let pending = readAsync(makeSource(server.url), 1)
            XCTAssertTrue(pending.finished(within: 5))
            assertTransport(pending.result)
        }
        XCTAssertEqual(partials(), [])
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

    // MARK: - Files

    func testABodyCompletedFromByteZeroIsPromotedIntoTheCacheAndOutlivesCancel() throws {
        let body = makeBody(48 * 1024)
        let server = try startServer(body: body)
        let source = makeSource(server.url)

        XCTAssertEqual(try readToEnd(source), body)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))
        XCTAssertEqual(source.snapshot.fileURL, cached)
        XCTAssertEqual(try Data(contentsOf: cached), body)
        XCTAssertEqual(partials(), [])

        source.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    private func audioFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".audio") }
    }

    private func tokenURL(_ base: URL, _ token: String) -> URL {
        URL(string: base.absoluteString + "?api_key=\(token)")!
    }

    func testACacheKeyLetsTwoTokenURLsShareOneCompletedFile() throws {
        let body = makeBody(48 * 1024)
        let server = try startServer(body: body)
        let key = server.url
        let store = makeStore()

        let first = makeSource(tokenURL(key, "session-one"), store: store, cacheKey: key)
        XCTAssertEqual(try readToEnd(first), body)
        XCTAssertTrue(waitUntil { first.snapshot.isComplete })
        first.cancel()

        // The second play's lookup, by the same key, finds the first play's file: no download.
        let cached = try XCTUnwrap(store.completedFile(for: key))
        XCTAssertEqual(try Data(contentsOf: cached), body)
        XCTAssertNil(store.completedFile(for: tokenURL(key, "session-one")))
        XCTAssertNil(store.completedFile(for: tokenURL(key, "session-two")))

        // A second download under another token lands on the same file.
        let second = makeSource(tokenURL(key, "session-two"), store: store, cacheKey: key)
        XCTAssertEqual(try readToEnd(second), body)
        XCTAssertTrue(waitUntil { second.snapshot.isComplete })
        XCTAssertEqual(second.snapshot.fileURL, cached)
        XCTAssertEqual(audioFiles().count, 1)
    }

    func testWithoutACacheKeyTokenURLsCacheSeparately() throws {
        let body = makeBody(48 * 1024)
        let server = try startServer(body: body)
        let store = makeStore()

        for token in ["session-one", "session-two"] {
            let source = makeSource(tokenURL(server.url, token), store: store)
            XCTAssertEqual(try readToEnd(source), body)
            XCTAssertTrue(waitUntil { source.snapshot.isComplete })
            source.cancel()
        }
        XCTAssertEqual(audioFiles().count, 2)
        XCTAssertNil(store.completedFile(for: server.url))
    }

    /// A load that failed on bytes the download had already finished into the cache: those bytes
    /// do not decode, so they leave the cache with the source.
    func testCancelDiscardingCacheRemovesTheFileThisSourcePromoted() throws {
        let body = makeBody(48 * 1024)
        let server = try startServer(body: body)
        let source = makeSource(server.url)

        XCTAssertEqual(try readToEnd(source), body)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))

        source.cancelDiscardingCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertNil(GrowingFileStore(directory: directory).completedFile(for: server.url))
        XCTAssertEqual(partials(), [])
    }

    func testASplicedBodyOnARestartIsReadWithItsOwnLength() throws {
        let first = makeBody(100_000)
        let second = makeBody(120_000, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        let source = makeSource(server.url)

        try source.seek(to: 50_000)
        XCTAssertEqual(try read(source, 100), first.subdata(in: 50_000..<50_100))
        XCTAssertEqual(source.totalLength, 100_000)

        try source.seek(to: 0)
        XCTAssertEqual(try readToEnd(source), second, "a new transaction is a new file, never a splice")
        XCTAssertEqual(source.totalLength, 120_000)
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
    }

    func testASpliceWithNoLengthIsReadPastTheEarlierSplicesLength() throws {
        let first = makeBody(100_000)
        let second = makeBody(120_000, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        let source = makeSource(server.url)

        try source.seek(to: 50_000)
        XCTAssertEqual(try read(source, 100), first.subdata(in: 50_000..<50_100))
        XCTAssertEqual(source.totalLength, 100_000)

        server.respondsWholeBodyIgnoringRange = true
        server.omitsContentLength = true
        try source.seek(to: 0)
        XCTAssertEqual(try readToEnd(source), second, "100 000 was the old splice's length, not this one's")
        XCTAssertEqual(source.totalLength, 120_000)
    }

    // MARK: - Seek claims

    private var seekLandings: [GrowingFileEvent] {
        events.events.filter { if case .seekLanded = $0 { return true } else { return false } }
    }

    /// A seek the file already answers opens nothing: it lands, and says so, so the target waiting
    /// for a transaction is dropped instead of riding on the next one nobody asked for.
    func testASeekAnsweredFromTheFileLandsAndTagsNoLaterTransaction() throws {
        let body = makeBody(512 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        let source = makeSource(server.url)
        _ = try read(source, 1)
        XCTAssertTrue(waitUntil { source.snapshot.frontier >= 48 * 1024 })

        source.willSeek(generation: 4)
        try source.seek(to: 32 * 1024)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 32 * 1024..<32 * 1024 + 100))
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
        XCTAssertEqual(seekLandings, [.seekLanded(seekGeneration: 4)])

        // The read jumping on its own later, with no seek announced: a transaction nobody's.
        try source.seek(to: 400_000)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 400_000..<400_100))
        XCTAssertEqual(events.transactions.last, .transaction(base: 400_000, generation: 2, seekGeneration: nil, httpStatus: 206))
        XCTAssertNil(source.snapshot.seekGeneration)
    }

    /// The decoder answered the seek from its own buffer, so it never moved the read position: the
    /// next read that has to restart is not that seek's and carries no anchor.
    func testASeekTheDecoderNeverMovedForTagsNothing() throws {
        let body = makeBody(512 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        let source = makeSource(server.url)
        _ = try read(source, 1)

        source.willSeek(generation: 6)
        // No `seek(to:)` for it: the read goes on from where it was, and the file answers it.
        _ = try read(source, 100)
        XCTAssertEqual(seekLandings, [.seekLanded(seekGeneration: 6)])
        try source.seek(to: 400_000)
        _ = try read(source, 100)
        XCTAssertEqual(events.transactions.last, .transaction(base: 400_000, generation: 2, seekGeneration: nil, httpStatus: 206))
    }

    /// The seek's transaction carries its generation; the resume after its body dropped is the same
    /// file, so it opens no transaction and pairs nothing again.
    func testAResumeAfterASeekOpensNoTransaction() throws {
        let body = makeBody(512 * 1024)
        let server = try startServer(body: body)
        server.bytesPerSecond = 64 * 1024
        let source = makeSource(server.url)
        _ = try read(source, 1)

        source.willSeek(generation: 7)
        try source.seek(to: 400_000)
        server.closesAfterBodyBytes = 8_000
        XCTAssertEqual(try read(source, 100), body.subdata(in: 400_000..<400_100))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 }, "the dropped body was never retried")
        XCTAssertEqual(server.requestedRanges.last, 408_000)
        XCTAssertEqual(try read(source, 20_000), body.subdata(in: 400_100..<420_100))
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
        XCTAssertEqual(events.transactions.map(\.seekGenerationForTest), [nil, 7])
    }

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
        XCTAssertTrue(clock.drive(timeout: 60) { failed.finished(within: 0) }, "the window never closed")
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
        XCTAssertTrue(clock.drive { rest.finished(within: 0) }, "the read after the failure never came back")
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
        Thread.sleep(forTimeInterval: 0.1)
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
        XCTAssertTrue(clock.drive { pending.finished(within: 0) }, "the wait never looked again")
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
        XCTAssertTrue(clock.drive { rest.finished(within: 0) }, "the read never came back")
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
        XCTAssertTrue(clock.drive(step: 0.05) { chainWalks() == 2 }, "the refused end never fell back to the chain")
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

    private static let wifi = GrowingFilePathMonitor.Path(satisfied: true, interface: "en0")
    private static let cellular = GrowingFilePathMonitor.Path(satisfied: true, interface: "pdp_ip0")
    private static let offline = GrowingFilePathMonitor.Path(satisfied: false, interface: nil)

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
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(server.requestedRanges, [0], "a path that was no change reopened the transaction")

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
        XCTAssertTrue(clock.drive(step: 0.1) { rest.finished(within: 0) }, "the read never failed")
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

    // MARK: - Read-ahead on an expensive path (ADR-0013)

    private static let hotspot = GrowingFilePathMonitor.Path(satisfied: true, interface: "en0", isExpensive: true)
    private static let lowDataWifi = GrowingFilePathMonitor.Path(satisfied: true, interface: "en0", isConstrained: true)
    private static let expensiveCellular = GrowingFilePathMonitor.Path(satisfied: true, interface: "pdp_ip0", isExpensive: true)
    private static let readAhead: Int64 = 128 * 1024
    private static let probe = 64 * 1024
    /// What the server may write past the chunk that reached the read-ahead before the cancel
    /// lands: the chunk itself and a slice or two of its ~20 ms drip at 1 MB/s.
    private static let onTheWire = 48 * 1024

    /// A capped source on `path`, its probe read, and the frontier waited for at the read-ahead.
    private func pausedSource(
        _ server: LoopbackMediaServer, path: GrowingFilePathMonitor.Path, store: GrowingFileStore? = nil
    ) throws -> (GrowingFileByteSource, GrowingFilePathMonitor) {
        let monitor = GrowingFilePathMonitor()
        monitor.update(path)
        let source = makeSource(
            server.url, store: store, pathMonitor: monitor, readAhead: GrowingFileReadAhead(bytes: Self.readAhead)
        )
        XCTAssertEqual(try read(source, Self.probe), server.body.prefix(Self.probe))
        XCTAssertTrue(waitUntil { source.snapshot.frontier - source.position >= Self.readAhead }, "never reached the read-ahead")
        return (source, monitor)
    }

    /// (c) A track skipped after its probe on cellular cost the host the probe, the read-ahead and
    /// the chunk on the wire when the request was cancelled; not the rest of the file.
    func testAnExpensivePathDownloadsOnlyTheReadAheadPastTheDecoder() throws {
        let body = makeBody(1_000_000)
        let server = try startServer(body: body)
        server.bytesPerSecond = 512 * 1024
        let (source, _) = try pausedSource(server, path: Self.expensiveCellular)
        // Uncapped, another half second would be 256 kB more.
        Thread.sleep(forTimeInterval: 0.5)
        source.cancel()
        XCTAssertEqual(server.requestedRanges, [0])
        XCTAssertLessThanOrEqual(server.servedBytes, Int64(Self.probe) + Self.readAhead + Int64(Self.onTheWire))
    }

    /// (c) Played to the end on cellular: one request per pause, each from the frontier it paused
    /// at, and the file the cache keeps is the body, byte for byte.
    func testAnExpensivePathPlayedToTheEndResumesFromEachPauseAndCachesTheFile() throws {
        let body = makeBody(600_000)
        let server = try startServer(body: body)
        server.bytesPerSecond = 1024 * 1024
        let store = makeStore()
        let (source, _) = try pausedSource(server, path: Self.expensiveCellular, store: store)
        var played = body.prefix(Self.probe)
        var pauses: [Int64] = []
        while !source.snapshot.isComplete, pauses.count < 10 {
            let frontier = source.snapshot.frontier
            pauses.append(frontier)
            // Up to half the read-ahead behind the frontier, then the read that resumes it.
            played += try read(source, Int(frontier - source.position - Self.readAhead / 2))
            XCTAssertEqual(server.requestedRanges.count, pauses.count)
            played += try read(source, 1)
            XCTAssertTrue(waitUntil {
                let next = source.snapshot
                return next.isComplete || next.frontier - source.position >= Self.readAhead
            })
        }
        played += try readToEnd(source)
        XCTAssertEqual(played, body)
        XCTAssertGreaterThan(pauses.count, 1)
        XCTAssertEqual(server.requestedRanges, [0] + pauses)
        // Only what was on the wire at each cancel comes twice.
        XCTAssertLessThanOrEqual(server.servedBytes, Int64(body.count + pauses.count * Self.onTheWire))
        let cached = try XCTUnwrap(store.completedFile(for: server.url))
        XCTAssertEqual(try Data(contentsOf: cached), body)
    }

    /// (e) On Wi-Fi the capped source downloads the whole file with nobody reading; a hotspot that
    /// stops costing (no change of interface, so no reopen) lifts a pause at once.
    func testACheapPathIsUncappedAndLiftsAPauseAtOnce() throws {
        let body = makeBody(600_000)
        let server = try startServer(body: body)
        server.bytesPerSecond = 1024 * 1024
        let monitor = GrowingFilePathMonitor()
        monitor.update(Self.wifi)
        let cheap = makeSource(server.url, pathMonitor: monitor, readAhead: GrowingFileReadAhead(bytes: Self.readAhead))
        XCTAssertEqual(try read(cheap, Self.probe), body.prefix(Self.probe))
        XCTAssertTrue(waitUntil { cheap.snapshot.isComplete })
        XCTAssertEqual(server.requestedRanges, [0])

        let (source, hotspot) = try pausedSource(server, path: Self.hotspot)
        let pausedAt = source.snapshot.frontier
        hotspot.update(Self.lowDataWifi)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.requestedRanges, [0, 0], "Low Data Mode is a cost too, and no change")
        hotspot.update(Self.wifi)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete }, "the pause was not lifted")
        XCTAssertEqual(server.requestedRanges, [0, 0, pausedAt])
    }

    /// (f) A host that ignores ranges is never capped: a resume would start it from 0 again.
    func testARangeIgnoringHostDownloadsWholeOnAnExpensivePath() throws {
        let body = makeBody(600_000)
        let server = try startServer(body: body)
        server.bytesPerSecond = 1024 * 1024
        server.respondsWholeBodyIgnoringRange = true
        let monitor = GrowingFilePathMonitor()
        monitor.update(Self.expensiveCellular)
        let source = makeSource(server.url, pathMonitor: monitor, readAhead: GrowingFileReadAhead(bytes: Self.readAhead))
        XCTAssertEqual(try read(source, Self.probe), body.prefix(Self.probe))
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        XCTAssertEqual(server.requestedRanges, [0])
        XCTAssertEqual(server.servedBytes, Int64(body.count))
    }

    /// A cancelled source stops listening.
    func testACancelledSourceNoLongerHearsPathChanges() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 20_000
        let clock = ManualGrowingFileClock()
        let monitor = GrowingFilePathMonitor()
        let source = makeSource(server.url, clock: clock, pathMonitor: monitor)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))
        source.cancel()
        monitor.update(Self.wifi)
        monitor.update(Self.cellular)
        clock.advance(by: 1)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(server.requestedRanges, [0])
    }

    // MARK: - 416, gzip and a changing resource

    /// The file shrank behind the URL between a drop and its resume, so the frontier is now at
    /// the new end and a strict origin answers the resume 416. That is a refused resume, not an
    /// end of stream: the retry restarts at the decoder's position into a new file, and the read
    /// gets the new file's bytes instead of hanging or ending early.
    func testAResumeAnswered416AtTheEndRestartsAndTheReadGetsTheNewFile() throws {
        let first = makeBody(160_000)
        let second = makeBody(100_000, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        server.answers416AtOrAfterEnd = true
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), first.prefix(4096))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertEqual(server.requestedRanges, [0, 100_000, 4096], "the resume asked for the new end, then restarted")
        let rest = readAsync(source, Int.max)
        XCTAssertTrue(rest.finished(within: 20), "the read hung after a 416")
        XCTAssertEqual(try rest.result.get(), second.suffix(from: 4096))
        XCTAssertEqual(source.totalLength, 100_000)
    }

    /// The same shrunken file with the decoder already at the old frontier: the restart asks for
    /// a byte past the new end and gets 416 again. The source cannot tell that from an end of
    /// stream it may trust, so the read fails clearly after the retries, never hangs and never
    /// reports the old file's bytes as the whole.
    func testA416ForARestartPastTheEndFailsTheReadAfterTheRetries() throws {
        let first = makeBody(160_000)
        let second = makeBody(100_000, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        server.answers416AtOrAfterEnd = true
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        let pending = readAsync(source, Int.max)
        XCTAssertTrue(pending.finished(within: 30), "the read hung after a 416")
        assertTransport(pending.result)
        XCTAssertEqual(server.requestedRanges.prefix(3), [0, 100_000, 100_000])
    }

    /// A body of unknown length stalls after its last byte, and the reopen from the frontier (a
    /// path change) is answered `416` with `bytes */N`, N being the frontier. As for a fresh
    /// request, that is the end of the file, not a refused resume: the length is learned and the
    /// read ends, with no restart. A different N is still a refused resume.
    func testAResumeAtTheFrontierAnswered416WithTheTotalAtThatPositionIsTheEnd() throws {
        // The first body is cut at 100 000 by the stall; the file that answers the reopen ends
        // there, so its strict origin says `bytes */100000`.
        let body = makeBody(160_000)
        let server = try startServer(body: body)
        server.bodies = [body, makeBody(100_000, seed: 42)]
        server.answers416AtOrAfterEnd = true
        // A plain `200` without a length: the total is not known when the reopen is answered.
        server.respondsWholeBodyIgnoringRange = true
        server.omitsContentLength = true
        server.stallsAfterBodyBytes = 100_000
        let clock = ManualGrowingFileClock()
        let monitor = GrowingFilePathMonitor()
        let source = makeSource(server.url, clock: clock, pathMonitor: monitor)

        XCTAssertEqual(try read(source, 4096), body.prefix(4096))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 100_000 })
        let rest = readAsync(source, Int.max)
        XCTAssertTrue(waitUntil { source.parkCount > 0 })
        monitor.update(Self.wifi)
        monitor.update(Self.cellular)
        XCTAssertTrue(clock.drive(step: 0.1) { rest.finished(within: 0) }, "the read hung after a 416 at the frontier")
        XCTAssertEqual(try rest.result.get(), body[4096..<100_000])
        XCTAssertEqual(server.requestedRanges, [0, 100_000], "the end was taken for a refused resume")
        XCTAssertEqual(source.totalLength, 100_000)
    }

    /// A gzip-encoded body is inflated by the session, and its `Content-Length` is the encoded
    /// size, not the file's. The file must never be taken for complete at the wrong length.
    func testAGzipEncodedBodyIsReadAsThePlainFileDespiteItsEncodedContentLength() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.gzipsBody = true
        let source = makeSource(server.url)

        let pending = readAsync(source, Int.max)
        XCTAssertTrue(pending.finished(within: 20), "the read hung on a gzip body")
        // The session inflates the body, so the read is the plain file whose length the encoded
        // `Content-Length` never named.
        XCTAssertEqual(try pending.result.get(), body)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))
        XCTAssertEqual(try Data(contentsOf: cached), body, "a garbled file was promoted as complete")
    }

    /// The same-length file swapped behind the URL between a drop and its resume: the total does
    /// not move, so only the validator can tell. The resume sends `If-Range` with the first
    /// response's ETag, the origin answers the whole new body, and the retry restarts at the
    /// decoder's position into a new file instead of splicing the new tail onto the old head.
    func testAResumeOfAFileChangedToSameLengthBytesIsNotSplicedBecauseOfIfRange() throws {
        let first = makeBody(160_000)
        let second = makeBody(160_000, seed: 42)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        server.etags = ["\"v1\"", "\"v2\""]
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), first.prefix(4096))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertTrue(
            server.requestHeads[1].lowercased().contains("if-range: \"v1\""), "the resume carried no validator"
        )
        XCTAssertEqual(server.requestedRanges, [0, 100_000, 4096])
        XCTAssertEqual(try readToEnd(source), second.suffix(from: 4096), "the new file was spliced onto the old")
        XCTAssertEqual(source.snapshot.base, 4096)
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
    }

    /// The control: a validator that still matches resumes into the same file, as before.
    func testAResumeOfAnUnchangedFileWithAnETagStaysInTheSameFile() throws {
        let body = makeBody(160_000)
        let server = try startServer(body: body)
        server.etag = "\"v1\""
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), body.prefix(4096))
        XCTAssertEqual(try readToEnd(source).count, body.count - 4096)
        XCTAssertEqual(server.requestedRanges, [0, 100_000])
        XCTAssertTrue(server.requestHeads[1].lowercased().contains("if-range: \"v1\""))
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }

    func testCancelDuringARetryBackoffEndsTheRetries() throws {
        let body = makeBody(32 * 1024)
        let server = try startServer(body: body)
        server.reject(host: "127.0.0.1:\(server.port)", status: 503)
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        let pending = readAsync(source, 1)
        XCTAssertTrue(clock.drive(step: 0.05) { server.requestHeads.count >= 2 })
        XCTAssertTrue(waitUntil { clock.pendingCount > 0 }, "the next retry is waiting out its backoff")

        source.cancel()
        XCTAssertTrue(pending.finished(within: 20))
        let requests = server.requestHeads.count
        // Longer than every backoff left: a retry that ignored the cancel shows here.
        clock.advance(by: 10)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.requestHeads.count, requests, "no request after cancel")
        XCTAssertEqual(partials(), [])
        XCTAssertNil(source.snapshot.fileURL)
    }

    func testALateCallbackFromAnOldTaskAfterARestartChangesNothing() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        server.stallsAfterBodyBytes = 8192
        let source = makeSource(server.url)
        try source.seek(to: 100_000)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100_000..<100_100))
        let old = try XCTUnwrap(runningTasks().first {
            $0.originalRequest?.value(forHTTPHeaderField: "Range") == "bytes=100000-"
        } as? URLSessionDataTask)

        try source.seek(to: 0)
        XCTAssertEqual(try read(source, 100), body.prefix(100))
        XCTAssertTrue(waitUntil { source.snapshot.frontier == 8192 })
        let before = source.snapshot

        let response = HTTPURLResponse(
            url: server.url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 100000-262143/262144", "Content-Type": "audio/mpeg"]
        )!
        var disposition: URLSession.ResponseDisposition?
        source.urlSession(Self.testSession, dataTask: old, didReceive: response) { disposition = $0 }
        source.urlSession(Self.testSession, dataTask: old, didReceive: Data(repeating: 0xAA, count: 4096))
        source.urlSession(Self.testSession, task: old, didCompleteWithError: nil)

        XCTAssertEqual(disposition, .cancel)
        let after = source.snapshot
        XCTAssertEqual(after.transactionGeneration, before.transactionGeneration)
        XCTAssertEqual(after.base, before.base)
        XCTAssertEqual(after.frontier, before.frontier)
        XCTAssertEqual(after.totalLength, before.totalLength)
        XCTAssertEqual(after.fileURL, before.fileURL)
        XCTAssertFalse(after.isComplete)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 100..<200))
    }

    private func runningTasks() -> [URLSessionTask] {
        let done = DispatchSemaphore(value: 0)
        var tasks: [URLSessionTask] = []
        Self.testSession.getAllTasks { tasks = $0; done.signal() }
        done.wait()
        return tasks
    }
}

private extension GrowingFileEvent {
    /// A transaction's seek generation; nil for any other event, and for a transaction no seek opened.
    var seekGenerationForTest: Int? {
        if case let .transaction(_, _, seekGeneration, _) = self { return seekGeneration }
        return nil
    }
}
