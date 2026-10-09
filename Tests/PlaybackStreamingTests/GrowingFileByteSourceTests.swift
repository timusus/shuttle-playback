import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

/// The growing-file byte source against a loopback origin and its fault knobs. Every read here is the decoder's: it blocks, and a 0 is the end.
final class GrowingFileByteSourceTests: XCTestCase {

    static let testSession = GrowingFileByteSource.makeSession(configuration: .ephemeral)

    var directory: URL!
    var servers: [LoopbackMediaServer] = []
    var sources: [GrowingFileByteSource] = []
    let events = EventRecorder()

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
    func makeBody(_ count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> Data {
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

    func makeStore(write: GrowingFileStore.WriteFunction? = nil) -> GrowingFileStore {
        if let write { return GrowingFileStore(directory: directory, write: write) }
        return GrowingFileStore(directory: directory)
    }

    func makeSource(
        _ url: URL, store: GrowingFileStore? = nil, authHeaders: [String: String] = [:],
        cacheKey: URL? = nil, connectionPolicy: GrowingFileConnectionPolicy? = nil,
        clock: GrowingFileClock = SystemGrowingFileClock.shared, session: URLSession = GrowingFileByteSourceTests.testSession,
        pathMonitor: GrowingFilePathMonitor = GrowingFilePathMonitor(), readAhead: GrowingFileReadAhead? = nil,
        unknownLengthWindow: Int64 = GrowingFileDownload.unknownLengthWindowBytes
    ) -> GrowingFileByteSource {
        let recorder = events
        let source = GrowingFileByteSource(
            url: url, authHeaders: authHeaders, cacheKey: cacheKey, connectionPolicy: connectionPolicy,
            readAhead: readAhead, store: store ?? makeStore(), session: session,
            clock: clock, pathMonitor: pathMonitor, unknownLengthWindow: unknownLengthWindow, onEvent: { recorder.append($0) }
        )
        sources.append(source)
        return source
    }

    /// Reads exactly `count` bytes, or fewer at the end of the stream.
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

    func readToEnd(_ source: GrowingFileByteSource) throws -> Data {
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

    func readAsync(_ source: GrowingFileByteSource, _ count: Int) -> PendingRead {
        PendingRead { try self.read(source, count) }
    }

    /// Generous by default: a condition that holds returns at once, and the machine may be loaded.
    func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            // Kept: URLSession and the loopback server raise no signal for these states.
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func partials() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".partial") }
    }

    func readerError(_ result: Result<Data, Error>) -> StreamByteReaderError? {
        guard case .failure(let error) = result else { return nil }
        return error as? StreamByteReaderError
    }

    func assertTransport(_ result: Result<Data, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .transport? = readerError(result) else {
            return XCTFail("expected .transport, got \(result)", file: file, line: line)
        }
    }

}

extension GrowingFileEvent {
    /// A transaction's seek generation; nil for any other event, and for a transaction no seek opened.
    var seekGenerationForTest: Int? {
        if case let .transaction(_, _, seekGeneration, _) = self { return seekGeneration }
        return nil
    }
}
