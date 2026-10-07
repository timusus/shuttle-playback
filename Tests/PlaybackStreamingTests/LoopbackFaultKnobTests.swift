import Foundation
import XCTest
import PlaybackStreamingTestSupport

/// **The loopback origin's network-fault knobs do what they say** , checked from a plain `URLSession` so a contract or output test that leans on them is
/// measuring the player, not the server.
final class LoopbackFaultKnobTests: XCTestCase {

    private var server: LoopbackMediaServer?
    private let session = URLSession(configuration: .ephemeral)

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func start(bodyBytes: Int) throws -> (LoopbackMediaServer, Data) {
        let body = Data((0..<bodyBytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let started = try LoopbackMediaServer(body: body, mimeType: "audio/mpeg")
        server = started
        return (started, body)
    }

    /// The body (or nil on a transport error) and how long the request took.
    private func fetch(_ url: URL, range: String? = nil) async -> (data: Data?, seconds: TimeInterval) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let startedAt = Date()
        let data = try? await session.data(for: request).0
        return (data, Date().timeIntervalSince(startedAt))
    }

    func testBytesPerSecondDripsTheBodyAtThatRate() async throws {
        let (origin, body) = try start(bodyBytes: 96 * 1024)
        origin.bytesPerSecond = 128 * 1024
        let result = await fetch(origin.url)
        XCTAssertEqual(result.data, body)
        // 0.75 s at the rate; a body written at once is milliseconds on loopback.
        XCTAssertGreaterThan(result.seconds, 0.6)
        XCTAssertLessThan(result.seconds, 2.0)
    }

    func testBurstPatternPausesBetweenBursts() async throws {
        let (origin, body) = try start(bodyBytes: 30 * 1024)
        origin.burstPattern = .init(burstBytes: 10 * 1024, pauseSeconds: 0.3)
        let result = await fetch(origin.url)
        XCTAssertEqual(result.data, body)
        // Two pauses between three bursts, at least.
        XCTAssertGreaterThan(result.seconds, 0.55)
        XCTAssertLessThan(result.seconds, 2.0)
    }

    func testClosesAfterBodyBytesDropsOneBodyThenServesWhole() async throws {
        let (origin, body) = try start(bodyBytes: 64 * 1024)
        origin.closesAfterBodyBytes = 16 * 1024
        let dropped = await fetch(origin.url)
        XCTAssertNotEqual(dropped.data, body, "the first body was not cut short")
        XCTAssertNil(origin.closesAfterBodyBytes, "the drop did not clear itself")
        let whole = await fetch(origin.url)
        XCTAssertEqual(whole.data, body)
    }

    func testContentLengthLieShortensEveryBody() async throws {
        let (origin, body) = try start(bodyBytes: 64 * 1024)
        origin.contentLengthLie = 1000
        for _ in 0..<2 {
            let short = await fetch(origin.url, range: "bytes=0-")
            XCTAssertNotEqual(short.data, body, "a body came out whole")
        }
        XCTAssertEqual(origin.servedBytes, Int64(2 * (body.count - 1000)))
    }

    func testRefuseRequestsDropsEveryConnectionForTheWindow() async throws {
        let (origin, body) = try start(bodyBytes: 8 * 1024)
        origin.refuseRequests(for: 0.5)
        let refused = await fetch(origin.url)
        XCTAssertNil(refused.data, "a request inside the blackout was answered")
        try await Task.sleep(nanoseconds: 600_000_000)
        let served = await fetch(origin.url)
        XCTAssertEqual(served.data, body)
    }

    func testDripComposesWithAStall() async throws {
        let (origin, _) = try start(bodyBytes: 64 * 1024)
        origin.bytesPerSecond = 256 * 1024
        origin.stallsAfterBodyBytes = 16 * 1024
        var request = URLRequest(url: origin.url, timeoutInterval: 1.0)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try? await session.data(for: request).0
        XCTAssertNil(data, "a stalled body completed")
        XCTAssertEqual(origin.servedBytes, 16 * 1024)
    }
}
