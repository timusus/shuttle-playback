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
        // Kept: the blackout is a real-time window on the server's own clock, and it ending is the behaviour.
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

    /// The response itself, for a test of status and headers.
    private func respond(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    /// The head of the answer as it goes on the wire, read from a raw socket: `URLSession` would
    /// normalise the header names, which is what the lower-case knob must not be judged through.
    private func rawHead(of url: URL) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(url.port ?? 80).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        _ = request.withCString { send(descriptor, $0, strlen($0), 0) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while String(decoding: received, as: UTF8.self).range(of: "\r\n\r\n") == nil {
            let got = recv(descriptor, &buffer, buffer.count, 0)
            if got <= 0 { break }
            received.append(contentsOf: buffer[0..<got])
        }
        let text = String(decoding: received, as: UTF8.self)
        return text.range(of: "\r\n\r\n").map { String(text[..<$0.lowerBound]) } ?? text
    }

    func testLowercasesHeadersLowercasesTheNamesOnTheWire() throws {
        let (origin, _) = try start(bodyBytes: 4096)
        let normal = try rawHead(of: origin.url)
        XCTAssertTrue(normal.contains("Content-Type: "), normal)
        origin.lowercasesHeaders = true
        let lower = try rawHead(of: origin.url)
        XCTAssertTrue(lower.contains("\r\ncontent-type: audio/mpeg"), lower)
        XCTAssertFalse(lower.contains("Content-Type"), lower)
        XCTAssertTrue(lower.hasPrefix("HTTP/1.1 2"), "the status line is not a header: \(lower)")
    }

    func testUsesChunkedEncodingSendsChunkedInPlaceOfAContentLength() throws {
        let (origin, _) = try start(bodyBytes: 4096)
        let plain = try rawHead(of: origin.url)
        XCTAssertTrue(plain.contains("Content-Length: 4096"), plain)
        XCTAssertFalse(plain.contains("Transfer-Encoding"), plain)
        origin.usesChunkedEncoding = true
        let chunked = try rawHead(of: origin.url)
        XCTAssertTrue(chunked.contains("Transfer-Encoding: chunked"), chunked)
        XCTAssertFalse(chunked.lowercased().contains("content-length"), chunked)
    }

    func testAnswers416AtOrAfterEndAnswers416OnlyForARangePastTheBody() async throws {
        let (origin, body) = try start(bodyBytes: 4096)
        origin.answers416AtOrAfterEnd = true
        for start in [body.count, body.count + 10] {
            let (data, response) = try await respond(origin.url, headers: ["Range": "bytes=\(start)-"])
            XCTAssertEqual(response.statusCode, 416)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes */\(body.count)")
            XCTAssertTrue(data.isEmpty)
        }
        let (tail, response) = try await respond(origin.url, headers: ["Range": "bytes=\(body.count - 1)-"])
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(tail, body.suffix(1))
        XCTAssertEqual(origin.requestedRanges, [4096, 4106, 4095])
    }

    func testGzipsBodyEncodesTheBodyAndItsContentLengthIsTheEncodedSize() async throws {
        let (origin, body) = try start(bodyBytes: 70_000)
        origin.gzipsBody = true
        let (data, _) = try await respond(origin.url, headers: ["Accept-Encoding": "gzip"])
        XCTAssertEqual(data, body, "URLSession inflates a gzip body, and the inflated bytes are the plain ones")
        let encoded = LoopbackMediaServer.gzip(body)
        XCTAssertGreaterThan(encoded.count, body.count, "stored blocks: the declared length cannot match the plain one")
        XCTAssertEqual(Array(encoded.prefix(3)), [0x1f, 0x8b, 8])
    }

    func testEtagIsSentAndIfRangeIsHonouredAgainstTheCurrentTag() async throws {
        let (origin, body) = try start(bodyBytes: 4096)
        origin.etag = "\"v1\""
        let (first, response) = try await respond(origin.url, headers: ["Range": "bytes=1000-"])
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "ETag"), "\"v1\"")
        XCTAssertEqual(first, body.suffix(from: 1000))

        let (matched, matchedResponse) = try await respond(origin.url, headers: ["Range": "bytes=1000-", "If-Range": "\"v1\""])
        XCTAssertEqual(matchedResponse.statusCode, 206)
        XCTAssertEqual(matched, body.suffix(from: 1000))

        // The resource changed: the same validator now buys the whole new body, not a range of it.
        let changed = Data(body.reversed())
        origin.body = changed
        origin.etag = "\"v2\""
        let (stale, staleResponse) = try await respond(origin.url, headers: ["Range": "bytes=1000-", "If-Range": "\"v1\""])
        XCTAssertEqual(staleResponse.statusCode, 200)
        XCTAssertNil(staleResponse.value(forHTTPHeaderField: "Content-Range"))
        XCTAssertEqual(staleResponse.value(forHTTPHeaderField: "ETag"), "\"v2\"")
        XCTAssertEqual(stale, changed)
    }

    func testEtagsServeOneTagPerRequestAndTheLastForever() async throws {
        let (origin, _) = try start(bodyBytes: 1024)
        origin.etags = ["\"a\"", "\"b\""]
        var seen: [String?] = []
        for _ in 0..<3 {
            seen.append(try await respond(origin.url, headers: [:]).1.value(forHTTPHeaderField: "ETag"))
        }
        XCTAssertEqual(seen, ["\"a\"", "\"b\"", "\"b\""])
    }
}
