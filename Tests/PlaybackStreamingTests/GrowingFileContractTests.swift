import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

/// media3's `DataSourceContractTest` cases, run over the resource matrix of
/// ``GrowingFileContractCase``. The mapping from media3's case names to these tests is in
/// `docs/testing.md`.
final class GrowingFileContractTests: GrowingFileContractCase {

    // MARK: - Reading

    /// media3 `unboundedDataSpec_readUntilEnd`: open at 0, read to the end, and the end is a 0.
    func testTheWholeBodyIsReadAndThenEndsInAZero() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            let pending = readAsync(source, Int.max)
            let result = finish(pending, resource.name)
            XCTAssertEqual(try result.get(), body, resource.name)
            XCTAssertEqual(try read(source, 10), Data(), "\(resource.name): after the end")
            XCTAssertEqual(source.totalLength, Int64(body.count), resource.name)
            XCTAssertEqual(source.position, Int64(body.count), resource.name)
        }
    }

    /// media3 `dataSpecWithPosition_readUntilEnd`: open at an offset, read to the end.
    func testASeekThenAReadToTheEndReturnsTheSuffix() throws {
        let body = makeBody()
        try forEachResource { resource in
            for offset in [1, 4095, 12_345, body.count - 1] {
                let (_, source) = try open(resource, body: body)
                try source.seek(to: Int64(offset))
                let result = finish(readAsync(source, Int.max), "\(resource.name) @\(offset)")
                XCTAssertEqual(try result.get(), body.suffix(from: offset), "\(resource.name) @\(offset)")
            }
        }
    }

    /// media3 `dataSpecWithPositionAndLength_readExpectedRange`: a window in the middle, and the
    /// position follows it. A length is a read size here; the source has no length-limited open.
    func testABoundedReadFromAPositionReturnsThatWindow() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            try source.seek(to: 7000)
            let window = try finish(readAsync(source, 1000), resource.name).get()
            XCTAssertEqual(window, body[7000..<8000], resource.name)
            XCTAssertEqual(source.position, 8000, resource.name)
        }
    }

    /// media3 `dataSpecWithLength_readUntilEndInTwoParts` (and `dataSpecWithLength_readExpectedRange`
    /// from position 0): contiguous windows read in order add up to the body.
    func testContiguousWindowsAddUpToTheBody() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            var joined = Data()
            for size in [1, 4096, 777, 10_000, 20_000] {
                joined.append(try finish(readAsync(source, size), resource.name).get())
            }
            XCTAssertEqual(joined, body.prefix(34_874), resource.name)
        }
    }

    /// Ours, no media3 counterpart: read on, seek back and forth, and the bytes stay the file's.
    func testSeekingBackAndForwardReadsTheSameBytes() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            XCTAssertEqual(try finish(readAsync(source, 20_000), resource.name).get(), body.prefix(20_000), resource.name)
            try source.seek(to: 100)
            XCTAssertEqual(try finish(readAsync(source, 500), resource.name).get(), body[100..<600], resource.name)
            try source.seek(to: 30_000)
            XCTAssertEqual(try finish(readAsync(source, 500), resource.name).get(), body[30_000..<30_500], resource.name)
            try source.seek(to: 0)
            XCTAssertEqual(try finish(readAsync(source, Int.max), resource.name).get(), body, resource.name)
        }
    }

    /// Ours, no media3 counterpart (media3 checks the bytes, not the request): a seek asks the host for exactly that offset.
    func testASeekAsksTheHostForExactlyThatOffset() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (server, source) = try open(resource, body: body)
            try source.seek(to: 5000)
            _ = try finish(readAsync(source, 10), resource.name).get()
            XCTAssertEqual(server.requestedRanges, [5000], resource.name)
            let sent = server.requestHeads.last?.lowercased() ?? ""
            XCTAssertTrue(sent.contains("range: bytes=5000-"), "\(resource.name): \(sent)")
        }
    }

    // MARK: - The end of the resource

    /// media3 `dataSpecWithPositionAtEnd_readsZeroBytes` (and `dataSpecWithPositionAtEndAndLength_readsZeroBytes`):
    /// once the length is known, a position at the end is an end of stream, not an error.
    func testAPositionAtTheEndOfAKnownLengthIsEndOfStream() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            _ = try finish(readAsync(source, 1), resource.name).get()
            try source.seek(to: Int64(body.count))
            XCTAssertEqual(try finish(readAsync(source, 10), resource.name).get(), Data(), resource.name)
        }
    }

    /// media3 `dataSpecWithPositionOutOfRange_throwsPositionOutOfRangeException`: a position beyond the end is a failed read, after the retries,
    /// whether the origin clamps the range to its last byte or answers `416`.
    func testAPositionPastTheEndFailsTheRead() throws {
        let body = makeBody()
        for strict in [false, true] {
            for html in [false, true] {
                let server = try startServer(body: body)
                server.answers416AtOrAfterEnd = strict
                server.htmlErrorBodies = html
                let source = makeSource(server.url)
                try source.seek(to: Int64(body.count) + 10)
                let context = "strict416=\(strict) html=\(html)"
                assertTransport(finish(readAsync(source, 1), within: 30, context), context)
                XCTAssertEqual(server.requestedRanges.count, 1 + DownloadRetry.maxAttempts, context)
            }
        }
    }

    /// Pinned; a `416` with `Content-Range: bytes */N` could be read as end of stream (issue #39).
    /// Today a seek to exactly the end, before the length is known, fails the read like a position
    /// past the end; media3's `dataSpecWithPositionAtEnd_readsZeroBytes` expects zero bytes.
    func testAnOpenAtExactlyTheEndFailsTheReadBeforeTheLengthIsKnown() throws {
        let body = makeBody()
        for strict in [false, true] {
            let server = try startServer(body: body)
            server.answers416AtOrAfterEnd = strict
            let source = makeSource(server.url)
            try source.seek(to: Int64(body.count))
            assertTransport(finish(readAsync(source, 1), within: 30, "strict416=\(strict)"), "strict416=\(strict)")
        }
    }

    /// media3 `dataSpecWithEndPositionOutOfRange_readsToEnd`: asking for more bytes than remain
    /// returns what remains, and the next read is the end.
    func testAReadLongerThanWhatRemainsReturnsTheRest() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            try source.seek(to: Int64(body.count - 100))
            XCTAssertEqual(try finish(readAsync(source, 1000), resource.name).get(), body.suffix(100), resource.name)
            XCTAssertEqual(try read(source, 10), Data(), "\(resource.name): after the end")
        }
    }

    // MARK: - Failing to open

    /// media3 `uriSchemeIsCaseInsensitive`: `HTTP://` opens like `http://`, redirects included.
    func testAnUpperCaseSchemeOpensLikeALowerCaseOne() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (server, _) = try open(resource, body: body)
            let url = resource.url(server)
            let shouted = URL(string: url.absoluteString.replacingOccurrences(of: "http://", with: "HTTP://"))!
            XCTAssertTrue(shouted.absoluteString.hasPrefix("HTTP://"), resource.name)
            let source = makeSource(shouted)
            XCTAssertEqual(try finish(readAsync(source, Int.max), resource.name).get(), body, resource.name)
        }
    }

    /// Nothing listening at all (a refused connection) is a transport error after the retries,
    /// not a hang and not an empty body.
    func testAConnectionRefusedFailsTheRead() throws {
        let server = try startServer(body: makeBody())
        let url = server.url
        server.stop()
        assertTransport(finish(readAsync(makeSource(url), 1), within: 30, "connection refused"), "connection refused")
        XCTAssertEqual(partials(), [])
    }

    /// media3 `resourceNotFound`, and the error statuses of its `HttpDataSource` tests: any non-success
    /// status fails the read with a transport error after the retries, with or without an HTML
    /// error page behind it.
    func testErrorStatusesFailTheReadAfterTheRetries() throws {
        let body = makeBody()
        for html in [false, true] {
            for status in [400, 401, 403, 404, 410, 416, 500, 503] {
                let server = try startServer(body: body)
                server.htmlErrorBodies = html
                server.reject(host: "127.0.0.1:\(server.port)", status: status)
                let context = "status=\(status) html=\(html)"
                assertTransport(finish(readAsync(makeSource(server.url), 1), within: 30, context), context)
                XCTAssertEqual(server.requestHeads.count, 1 + DownloadRetry.maxAttempts, context)
            }
            let server = try startServer(body: body)
            server.htmlErrorBodies = html
            let context = "missing path html=\(html)"
            assertTransport(finish(readAsync(makeSource(server.missingURL), 1), within: 30, context), context)
            XCTAssertEqual(server.requestHeads.count, 1 + DownloadRetry.maxAttempts, context)
        }
        XCTAssertEqual(partials(), [])
    }

    /// An HTML page where the audio should be: declared as HTML, or as an unknown type whose body
    /// sniffs as HTML. A page declared `audio/mpeg` is trusted and left to the decoder.
    func testAPageServedAsAudioOrAsAPageFailsTheRead() throws {
        let page = Data("<!DOCTYPE html><html><body>expired</body></html>".utf8)
        for mimeType in ["text/html; charset=utf-8", "application/octet-stream"] {
            let server = try startServer(body: page, mimeType: mimeType)
            let context = "mime=\(mimeType)"
            assertTransport(finish(readAsync(makeSource(server.url), 1), within: 10, context), context)
        }
        XCTAssertEqual(partials(), [])
    }

    /// Ours (media3's `HttpDataSource` tests cover request properties, not in the contract test):
    /// the caller's headers ride every request,
    /// the redirect hops too, whatever the case the host answers in.
    func testRequestHeadersRideEveryRequestIncludingRedirectHops() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (server, source) = try open(resource, body: body, authHeaders: ["X-Token": "abc123"])
            try source.seek(to: 3000)
            _ = try finish(readAsync(source, 10), resource.name).get()
            XCTAssertEqual(server.requestHeads.count, resource.redirectHops + 1, resource.name)
            for head in server.requestHeads {
                XCTAssertTrue(head.lowercased().contains("x-token: abc123"), "\(resource.name): \(head)")
            }
        }
    }

    // MARK: - Life cycle

    /// Ours, no media3 counterpart: cancelling a source never read from is
    /// harmless and starts nothing, twice over; a read after it is a cancellation.
    func testCancelBeforeAnyReadAndCancelTwiceAreHarmless() throws {
        let server = try startServer(body: makeBody())
        let source = makeSource(server.url)
        source.cancel()
        source.cancel()
        XCTAssertThrowsError(try read(source, 1)) { XCTAssertEqual($0 as? StreamByteReaderError, .cancelled) }
        XCTAssertEqual(server.requestHeads, [])
        XCTAssertEqual(partials(), [])
    }

    /// Ours, no media3 counterpart: cancelled after bytes were read, the next read is a cancellation
    /// and so is a seek-and-read; nothing hangs.
    func testAReadAfterCancelThrowsCancelled() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (_, source) = try open(resource, body: body)
            _ = try finish(readAsync(source, 100), resource.name).get()
            source.cancel()
            XCTAssertThrowsError(try read(source, 1), resource.name) {
                XCTAssertEqual($0 as? StreamByteReaderError, .cancelled, resource.name)
            }
        }
    }

    /// Ours, no media3 counterpart: a new source on the same URL after a cancel reads the whole
    /// body again.
    func testANewSourceAfterACancelReadsTheWholeBodyAgain() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (server, first) = try open(resource, body: body)
            _ = try finish(readAsync(first, 100), resource.name).get()
            first.cancel()
            let second = makeSource(resource.url(server))
            XCTAssertEqual(try finish(readAsync(second, Int.max), resource.name).get(), body, resource.name)
        }
    }

    // MARK: - What the first answer records

    /// Ours, no media3 counterpart (`getResponseHeaders_*` and `getUri_*` are n/a: the source
    /// exposes neither): it records the first answer's status, the hosts it passed through and the
    /// length it learned. A resource that declares no length may leave the length unknown at this point.
    func testTheFirstAnswerRecordsItsStatusAndTheRedirectHops() throws {
        let body = makeBody()
        try forEachResource { resource in
            let (server, source) = try open(resource, body: body)
            _ = try finish(readAsync(source, 1), resource.name).get()
            XCTAssertEqual(source.startup.status, resource.ignoresRange ? 200 : 206, resource.name)
            XCTAssertEqual(source.startup.hosts.count, resource.redirectHops, resource.name)
            if resource.declaresLength {
                XCTAssertEqual(source.totalLength, Int64(body.count), resource.name)
            } else {
                // Learned only at the end of the body: unknown, or exactly the body's size.
                XCTAssertTrue(source.totalLength == nil || source.totalLength == Int64(body.count), "\(resource.name): \(String(describing: source.totalLength))")
            }
            XCTAssertEqual(server.requestedRanges.count, 1, resource.name)
        }
    }

    private func partials() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".partial") }
    }
}
