import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

/// The reusable base for contract tests of `GrowingFileByteSource` over `LoopbackMediaServer`,
/// after media3's `DataSourceContractTest` run over `HttpDataSourceTestEnv`'s resources.
///
/// A ``Resource`` is one way an origin can serve the same fixed body: a server configuration and
/// the URL to open. ``matrix`` lists them, and a test loops over it, so a new server behaviour is
/// one entry that every contract case then runs against. A later suite (connection policy,
/// path-change reopen, cache budget) subclasses this, overrides ``matrix`` or adds cases, and gets
/// the helpers below. This class has no test methods of its own.
class GrowingFileContractCase: XCTestCase {

    static let session = GrowingFileByteSource.makeSession(configuration: .ephemeral)

    /// One way of serving the body.
    struct Resource {
        let name: String
        var mimeType = "audio/mpeg"
        /// Number of redirect hops between the URL opened and the body.
        var redirectHops = 0
        var configure: (LoopbackMediaServer) -> Void = { _ in }
        var url: (LoopbackMediaServer) -> URL = { $0.url }
    }

    /// The matrix every contract case runs over: the ways a media host serves a ranged body.
    var matrix: [Resource] { Self.defaultMatrix }

    static var defaultMatrix: [Resource] {
        var out: [Resource] = [
            Resource(name: "range-206"),
            Resource(name: "range-ignored-200", configure: { $0.respondsWholeBodyIgnoringRange = true }),
            Resource(name: "no-content-length", configure: { $0.omitsContentLength = true }),
            Resource(name: "chunked", configure: { $0.usesChunkedEncoding = true }),
            Resource(name: "lowercase-headers", configure: { $0.lowercasesHeaders = true; $0.etag = "\"v1\"" }),
            Resource(name: "etag", configure: { $0.etag = "\"v1\"" }),
            Resource(name: "gzip", configure: { $0.gzipsBody = true }),
            Resource(name: "octet-stream", mimeType: "application/octet-stream"),
            Resource(name: "redirect-chain-3", redirectHops: 3, url: { $0.redirectingURL(hops: 3) }),
        ]
        for location in LoopbackMediaServer.RedirectLocation.allCases {
            out.append(Resource(name: "redirect-302-\(location.rawValue)", redirectHops: 1, url: { $0.redirectURL(location: location) }))
        }
        for status in [301, 303, 307, 308] {
            out.append(Resource(name: "redirect-\(status)-rooted", redirectHops: 1, url: { $0.redirectURL(status: status, location: .rooted) }))
        }
        out.append(Resource(
            name: "lowercase-chunked-redirect", redirectHops: 1,
            configure: { $0.lowercasesHeaders = true; $0.usesChunkedEncoding = true },
            url: { $0.redirectURL(location: .parentRelative) }
        ))
        return out
    }

    static let bodySize = 40_000

    var directory: URL!
    var servers: [LoopbackMediaServer] = []
    var sources: [GrowingFileByteSource] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("growing-contract-\(UUID().uuidString)")
    }

    override func tearDown() {
        sources.forEach { $0.cancel() }
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random bytes behind an ID3 tag, so the body passes the media sniff.
    func makeBody(_ count: Int = GrowingFileContractCase.bodySize, seed: UInt64 = 0x9E3779B97F4A7C15) -> Data {
        var state = seed
        var bytes = [UInt8](Data("ID3\u{04}\u{00}\u{00}\u{00}\u{00}\u{00}\u{00}".utf8))
        bytes.reserveCapacity(count)
        while bytes.count < count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes.append(UInt8(truncatingIfNeeded: state))
        }
        return Data(bytes.prefix(count))
    }

    func startServer(body: Data, mimeType: String = "audio/mpeg") throws -> LoopbackMediaServer {
        let server = try LoopbackMediaServer(body: body, mimeType: mimeType)
        servers.append(server)
        return server
    }

    /// A server configured as `resource`, and a source on its URL.
    func open(
        _ resource: Resource, body: Data, authHeaders: [String: String] = [:]
    ) throws -> (server: LoopbackMediaServer, source: GrowingFileByteSource) {
        let server = try startServer(body: body, mimeType: resource.mimeType)
        resource.configure(server)
        return (server, makeSource(resource.url(server), authHeaders: authHeaders))
    }

    func makeSource(_ url: URL, authHeaders: [String: String] = [:]) -> GrowingFileByteSource {
        let source = GrowingFileByteSource(
            url: url, authHeaders: authHeaders, store: GrowingFileStore(directory: directory),
            session: Self.session
        )
        sources.append(source)
        return source
    }

    /// Reads `count` bytes, or fewer at the end of the stream.
    func read(_ source: GrowingFileByteSource, _ count: Int) throws -> Data {
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

    func readToEnd(_ source: GrowingFileByteSource) throws -> Data { try read(source, Int.max) }

    /// A blocking read running off the test thread, so a read that hangs fails the test instead
    /// of wedging it.
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

        func finished(within timeout: TimeInterval) -> Bool {
            group.wait(timeout: .now() + timeout) == .success
        }

        var result: Result<Data, Error> {
            _ = group.wait(timeout: .now() + 10)
            lock.lock(); defer { lock.unlock() }
            return _result ?? .failure(StillBlocked())
        }
    }

    func readAsync(_ source: GrowingFileByteSource, _ count: Int) -> PendingRead {
        PendingRead { try self.read(source, count) }
    }

    /// The result of a read that must finish within `timeout`, as a `Result`; a hang is a failure.
    func finish(
        _ pending: PendingRead, within timeout: TimeInterval = 20, _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Result<Data, Error> {
        XCTAssertTrue(pending.finished(within: timeout), "\(context): the read hung", file: file, line: line)
        return pending.result
    }

    func readerError(_ result: Result<Data, Error>) -> StreamByteReaderError? {
        if case .failure(let error) = result { return error as? StreamByteReaderError }
        return nil
    }

    func assertTransport(
        _ result: Result<Data, Error>, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .transport? = readerError(result) else {
            return XCTFail("\(context): expected .transport, got \(result)", file: file, line: line)
        }
    }

    /// Runs `check` once per resource of ``matrix``, with the resource's name in every failure.
    func forEachResource(_ check: (Resource) throws -> Void) rethrows {
        for resource in matrix {
            try check(resource)
        }
    }
}
