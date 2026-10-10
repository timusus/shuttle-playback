import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
    // MARK: - Read-ahead on an expensive path (ADR-0013)

    static let hotspot = GrowingFilePathMonitor.Path(satisfied: true, interface: "en0", isExpensive: true)
    static let lowDataWifi = GrowingFilePathMonitor.Path(satisfied: true, interface: "en0", isConstrained: true)
    static let expensiveCellular = GrowingFilePathMonitor.Path(satisfied: true, interface: "pdp_ip0", isExpensive: true)
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
        // Waits for the request to end: paused at the read-ahead, or, uncapped, only once the whole body is served.
        XCTAssertTrue(waitUntil { !source.awaitsNetworkForTest }, "the request never ended")
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
        XCTAssertEqual(source.requestsSentForTest, 1, "Low Data Mode is a cost too, and no change")
        hotspot.update(Self.wifi)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete }, "the pause was not lifted")
        XCTAssertEqual(server.requestedRanges, [0, 0, pausedAt])
    }

    /// An unsatisfied path reports no cost; it must not lift a pause. The resume would go out
    /// offline and fail on a transaction the decoder still has file to play.
    func testAnOfflinePathLeavesAPauseAloneAndTheNextSatisfiedPathLiftsIt() throws {
        let body = makeBody(600_000)
        let server = try startServer(body: body)
        server.bytesPerSecond = 1024 * 1024
        let (source, monitor) = try pausedSource(server, path: Self.hotspot)
        let pausedAt = source.snapshot.frontier
        monitor.update(Self.offline)
        XCTAssertEqual(source.requestsSentForTest, 1, "offline lifted the pause")
        monitor.update(Self.wifi)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete }, "the pause was not lifted")
        XCTAssertEqual(server.requestedRanges, [0, pausedAt])
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
        XCTAssertEqual(source.requestsSentForTest, 1)
    }

}
