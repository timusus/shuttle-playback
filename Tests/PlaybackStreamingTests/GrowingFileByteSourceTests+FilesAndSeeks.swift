import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
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

    /// Issue #71: a transcode served with an estimated length can promise bytes that never come.
    func testASeekPastAKnownTotalIsRefusedAndOneToTheTotalIsTheEnd() throws {
        let body = makeBody(48 * 1024)
        let server = try startServer(body: body)
        let source = makeSource(server.url)
        _ = try read(source, 1)
        XCTAssertEqual(source.totalLength, 48 * 1024)

        XCTAssertThrowsError(try source.seek(to: 48 * 1024 + 1)) {
            guard case .unseekable? = $0 as? StreamByteReaderError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(source.position, 1, "a refused seek moves nothing")

        try source.seek(to: 48 * 1024)
        XCTAssertEqual(try read(source, 100), Data(), "the total itself is the end of the stream")
    }

    func testASeekBeforeTheTotalIsKnownIsAccepted() throws {
        let server = try startServer(body: makeBody(48 * 1024))
        let source = makeSource(server.url)
        XCTAssertNil(source.totalLength)
        XCTAssertNoThrow(try source.seek(to: 10_000_000))
    }

}
