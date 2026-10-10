import Foundation
import Network

/// A minimal `Range`-aware HTTP server on the loopback interface, for tests that need a real
/// network origin rather than a `file://` URL.
///
/// Only an `http`/`https` URL streams through the growing-file byte source (a file URL is played
/// from disk), so any test of streaming has to serve its fixture over HTTP. This is that origin:
/// one fixed body, byte ranges, and a settable delay on the response so a test can widen a race that a loopback socket would otherwise close too fast to see.
public final class LoopbackMediaServer: @unchecked Sendable {

    // The state below is internal rather than private: the fault controls
    // (`LoopbackMediaServer+Faults.swift`) and the serving code (`LoopbackMediaServer+Serving.swift`)
    // read and write it, always under `lock`.
    var _body: Data
    var _bodies: [Data]?
    let mimeType: String
    private let listener: NWListener
    let queue = DispatchQueue(label: "loopback-media-server")
    let lock = NSLock()
    var _requestedRanges: [Int64] = []
    var _requestHeads: [String] = []
    var _servedBytes: Int64 = 0
    var _respondsWholeBodyIgnoringRange = false
    var _omitsContentLength = false
    var _failingRequests = 0
    var _holdsOffsetZero = false
    var _heldOffsetZeroSends: [() -> Void] = []
    var _streamsWithoutLength = false
    var _rejectNextRangeStartingAt: Int64?
    var _rejectedHostStatus: (host: String, status: Int)?
    var _pageForHost: (host: String, contentType: String, body: Data, firstChunkBytes: Int?)?
    var _delayForOffsetZero: TimeInterval = 0
    var _delayForRangeStartingAt: (offset: Int64, seconds: TimeInterval)?
    var _heldBodyAfterBytesForRangeStartingAt: [Int64: Int] = [:]
    var _heldRemainders: [Int64: (connection: NWConnection, rest: Data)] = [:]
    var _releasedHeldRanges: Set<Int64> = []
    var _delayForEveryRange: TimeInterval = 0
    var _stallsAfterBodyBytes: Int?
    var _redirectsToAlternateHost = false
    var _delayForRedirectHops: TimeInterval = 0
    var _bytesPerSecond: Int?
    var _burstPattern: BurstPattern?
    var _closesAfterBodyBytes: Int?
    var _outageAfterClose: TimeInterval?
    var _contentLengthLie: Int?
    var _refusesRequestsUntil: Date?
    var _answers416AtOrAfterEnd = false
    var _gzipsBody = false
    var _lowercasesHeaders = false
    var _usesChunkedEncoding = false
    var _htmlErrorBodies = false
    var _etag: String?
    var _etags: [String]?
    private var connections: [NWConnection] = []

    /// The port the listener bound; zero until `init` returns.
    public private(set) var port: UInt16 = 0

    /// The body the origin serves. Settable, because a server that splices dynamic content can
    /// change the body behind a stable URL: a test swaps this between requests to stand in for that.
    public var body: Data {
        get { lock.lock(); defer { lock.unlock() }; return _body }
        set { lock.lock(); _body = newValue; _bodies = nil; lock.unlock() }
    }

    /// One body per request, in order; the last one serves every request after it. A server that
    /// changes the body between a client's first response and its reconnect, made deterministic.
    public var bodies: [Data]? {
        get { lock.lock(); defer { lock.unlock() }; return _bodies }
        set { lock.lock(); _bodies = newValue; lock.unlock() }
    }

    public init(body: Data, mimeType: String) throws {
        self._body = body
        self.mimeType = mimeType
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw ServerError.didNotStart
        }
    }

    /// Thrown by `init` when the listener never reached `.ready`.
    public enum ServerError: Error { case didNotStart }

    /// The one URL this origin serves.
    public var url: URL { URL(string: "http://127.0.0.1:\(port)/fixture.mp3")! }

    /// The fixture path a redirect chain ends at.
    public static let fixturePath = "/fixture.mp3"

    /// A URL that answers `302` `hops` times before landing on ``url``'s path — a media URL
    /// behind a redirect chain. Each hop is `/redirect/<n>/fixture.mp3`, the last a `302` to
    /// ``fixturePath`` (on `localhost` when ``redirectsToAlternateHost`` is set).
    public func redirectingURL(hops: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/redirect/\(hops)/fixture.mp3")!
    }

    /// How a redirect names its target.
    public enum RedirectLocation: String, Sendable, CaseIterable {
        /// `http://127.0.0.1:<port>/fixture.mp3`
        case absolute
        /// `/fixture.mp3`
        case rooted
        /// `../fixture.mp3`, resolved against the redirecting path.
        case parentRelative = "parent"
        /// `//127.0.0.1:<port>/fixture.mp3`
        case schemeRelative = "scheme"
    }

    /// A URL that answers one redirect with `status` (301, 302, 303, 307 or 308), its `Location`
    /// written as `location`, and lands on ``url``'s path.
    public func redirectURL(status: Int = 302, location: RedirectLocation) -> URL {
        URL(string: "http://127.0.0.1:\(port)/redirect-\(status)-\(location.rawValue)/fixture.mp3")!
    }

    /// A URL no resource lives at: `404`, with an HTML page when ``htmlErrorBodies`` is set.
    public var missingURL: URL { URL(string: "http://127.0.0.1:\(port)/missing/fixture.mp3")! }

    /// The URL the chain from ``redirectingURL(hops:)`` ends at, given the current host setting.
    public var resolvedURL: URL {
        URL(string: "http://\(redirectsToAlternateHost ? "localhost" : "127.0.0.1"):\(port)\(Self.fixturePath)")!
    }

    /// Cancels the listener and every open connection.
    public func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }
}
