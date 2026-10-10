import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
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
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)

        let pending = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source) { pending.finished(within: 0) }, "the read hung after a 416")
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
        XCTAssertTrue(clock.drive(source, step: 0.1) { rest.finished(within: 0) }, "the read hung after a 416 at the frontier")
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
        XCTAssertTrue(clock.drive(source, step: 0.05) { server.requestHeads.count >= 2 })
        XCTAssertTrue(waitUntil { clock.pendingCount > 0 }, "the next retry is waiting out its backoff")

        source.cancel()
        XCTAssertTrue(pending.finished(within: 20))
        let requests = source.requestsSentForTest
        // Longer than every backoff left: a retry that ignored the cancel shows here.
        clock.advance(by: 10)
        XCTAssertEqual(source.requestsSentForTest, requests, "no request after cancel")
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
