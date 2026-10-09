import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport

/// The session's one file through the adapter (ADR-0014): what the server is asked for, what the
/// cache ends up with, and what stays on disk.
extension GrowingFileByteSourceTests {

    private func ranges(_ server: LoopbackMediaServer) -> [String] {
        server.requestHeads.compactMap { head in
            head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst("range: ".count)) }
        }
    }

    func testAResumedPlayThatSeeksToZeroIsPromotedWithNoByteFetchedTwice() throws {
        let body = makeBody(256 * 1024)
        let server = try startServer(body: body)
        let source = makeSource(server.url, clock: ManualGrowingFileClock())
        try source.seek(to: 128 * 1024)
        XCTAssertEqual(try read(source, 1000), body[(128 * 1024)..<(128 * 1024 + 1000)])
        XCTAssertTrue(waitUntil { source.snapshot.isComplete }, "the resumed body never reached the end")

        try source.seek(to: 0)
        XCTAssertEqual(try readToEnd(source), body)
        XCTAssertEqual(ranges(server), ["bytes=131072-", "bytes=0-131071"])
        XCTAssertEqual(server.servedBytes, Int64(body.count), "a byte was fetched twice")
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))
        XCTAssertEqual(source.snapshot.fileURL, cached)
        XCTAssertEqual(try Data(contentsOf: cached), body)
        source.cancel()
        XCTAssertEqual(partials(), [])
        XCTAssertNotNil(GrowingFileStore(directory: directory).completedFile(for: server.url))
    }

    func testAChangedETagOnALaterTransactionDiscardsTheFile() throws {
        let first = makeBody(256 * 1024), second = makeBody(256 * 1024, seed: 7)
        let server = try startServer(body: first)
        server.bodies = [first, second]
        server.etags = ["\"v1\"", "\"v2\""]
        let source = makeSource(server.url, clock: ManualGrowingFileClock())
        try source.seek(to: 128 * 1024)
        XCTAssertEqual(try read(source, 1000), first[(128 * 1024)..<(128 * 1024 + 1000)])
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        let firstFile = try XCTUnwrap(source.snapshot.fileURL)

        try source.seek(to: 0)
        XCTAssertEqual(try readToEnd(source), second, "a byte of the old resource was read")
        XCTAssertEqual(ranges(server), ["bytes=131072-", "bytes=0-131071", "bytes=0-"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path), "the old resource's file was kept")
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))
        XCTAssertEqual(try Data(contentsOf: cached), second)
    }

    func testAStreamOfUnknownLengthKeepsOnlyTheWindowBehindTheReaderOnDisk() throws {
        let window: Int64 = 64 * 1024
        let body = makeBody(1024 * 1024)
        let server = try startServer(body: body)
        server.respondsWholeBodyIgnoringRange = true
        server.omitsContentLength = true
        // The body never ends, so its length stays unknown.
        server.stallsAfterBodyBytes = 768 * 1024
        let source = makeSource(server.url, clock: ManualGrowingFileClock(), unknownLengthWindow: window)
        XCTAssertEqual(try read(source, 768 * 1024), body.prefix(768 * 1024))
        XCTAssertEqual(source.snapshot.frontier, 768 * 1024)
        XCTAssertNil(source.snapshot.totalLength)
        let file = try XCTUnwrap(source.snapshot.fileURL)
        var info = stat()
        XCTAssertEqual(stat(file.path, &info), 0)
        let allocated = Int64(info.st_blocks) * 512
        // The last read began one 16 KiB buffer back; a punch keeps the block it shares with kept bytes.
        XCTAssertLessThanOrEqual(allocated, window + 16 * 1024 + Int64(info.st_blksize), "\(allocated) bytes on disk")

        // A seek back behind the window fetches again.
        try source.seek(to: 0)
        let pending = readAsync(source, 1000)
        XCTAssertTrue(waitUntil { server.requestHeads.count == 2 }, "the dropped bytes were not asked for again")
        XCTAssertTrue(pending.finished(within: 20))
        XCTAssertEqual(try pending.result.get(), body.prefix(1000))
        XCTAssertNil(GrowingFileStore(directory: directory).completedFile(for: server.url))
    }
}
