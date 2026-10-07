import Foundation
import Network

/// A minimal `Range`-aware HTTP server on the loopback interface, for tests that need a real
/// network origin rather than a `file://` URL.
///
/// Only an `http`/`https` URL streams through the growing-file byte source (a file URL is played
/// from disk), so any test of streaming has to serve its fixture over HTTP. This is that origin:
/// one fixed body, byte ranges, and a settable delay on the response so a test can widen a race that a loopback socket would otherwise close too fast to see.
public final class LoopbackMediaServer: @unchecked Sendable {

    private var _body: Data
    private var _bodies: [Data]?
    private let mimeType: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-media-server")
    private let lock = NSLock()
    private var _requestedRanges: [Int64] = []
    private var _requestHeads: [String] = []
    private var _servedBytes: Int64 = 0
    private var _respondsWholeBodyIgnoringRange = false
    private var _omitsContentLength = false
    private var _failNextRequest = false
    private var _rejectNextRangeStartingAt: Int64?
    private var _rejectedHostStatus: (host: String, status: Int)?
    private var _pageForHost: (host: String, contentType: String, body: Data, firstChunkBytes: Int?)?
    private var _delayForOffsetZero: TimeInterval = 0
    private var _delayForRangeStartingAt: (offset: Int64, seconds: TimeInterval)?
    private var _heldBodyAfterBytesForRangeStartingAt: [Int64: Int] = [:]
    private var _heldRemainders: [Int64: (connection: NWConnection, rest: Data)] = [:]
    private var _releasedHeldRanges: Set<Int64> = []
    private var _delayForEveryRange: TimeInterval = 0
    private var _stallsAfterBodyBytes: Int?
    private var _redirectsToAlternateHost = false
    private var _delayForRedirectHops: TimeInterval = 0
    private var _bytesPerSecond: Int?
    private var _burstPattern: BurstPattern?
    private var _closesAfterBodyBytes: Int?
    private var _outageAfterClose: TimeInterval?
    private var _contentLengthLie: Int?
    private var _refusesRequestsUntil: Date?
    private var connections: [NWConnection] = []

    /// Drip every response body at this many bytes per second instead of writing it at once: a
    /// link slower (or faster) than the media plays. The header goes out at once; the body follows
    /// in ~20 ms slices on a schedule anchored to the first body byte, so a slow client (a full
    /// socket buffer) delays the drip without the drip then bursting to catch up. Composes with
    /// ``burstPattern``, ``closesAfterBodyBytes``, ``contentLengthLie`` and
    /// ``stallsAfterBodyBytes``, which bound how much of the body is written. Nil writes at once.
    public var bytesPerSecond: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _bytesPerSecond }
        set { lock.lock(); _bytesPerSecond = newValue; lock.unlock() }
    }

    /// Write `burstBytes` of the body, go quiet for `pauseSeconds` with the connection open, and
    /// repeat to the end: the shape of a cellular link that delivers in bursts. Each burst goes at
    /// ``bytesPerSecond`` when that is set, else at once.
    public struct BurstPattern: Equatable, Sendable {
        public var burstBytes: Int
        public var pauseSeconds: TimeInterval
        public init(burstBytes: Int, pauseSeconds: TimeInterval) {
            self.burstBytes = burstBytes
            self.pauseSeconds = pauseSeconds
        }
    }

    /// See ``BurstPattern``. Nil sends the body without pauses.
    public var burstPattern: BurstPattern? {
        get { lock.lock(); defer { lock.unlock() }; return _burstPattern }
        set { lock.lock(); _burstPattern = newValue; lock.unlock() }
    }

    /// **Once**: write this many bytes of the next body and then close the connection, with the
    /// declared `Content-Length` still the full slice — the connection that drops mid-episode
    /// (airplane mode, a cell handoff). Cleared when it fires, so the client's reconnect is served
    /// whole; set it again for another drop. Unlike ``stallsAfterBodyBytes`` the client sees the
    /// end of the body at once.
    public var closesAfterBodyBytes: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _closesAfterBodyBytes }
        set { lock.lock(); _closesAfterBodyBytes = newValue; lock.unlock() }
    }

    /// With ``closesAfterBodyBytes``: the moment that drop fires, ``refuseRequests(for:)`` this
    /// long, so the drop is the start of an outage rather than one lost connection. Airplane mode
    /// for a few seconds mid-episode, as the harness fixture server's `--drop-at --drop-for` does.
    public var outageAfterClose: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return _outageAfterClose }
        set { lock.lock(); _outageAfterClose = newValue; lock.unlock() }
    }

    /// On every body response, declare the full `Content-Length` but write `k` bytes fewer and
    /// close: a host whose length lies, so the body always ends short. Unlike
    /// ``closesAfterBodyBytes`` it never clears, so every retry comes up short too. Nil is honest.
    public var contentLengthLie: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _contentLengthLie }
        set { lock.lock(); _contentLengthLie = newValue; lock.unlock() }
    }

    /// Drop every connection without a response for the next `seconds`: no network at all (the
    /// airplane-mode blackout), as opposed to a host that answers with an error. Requests that
    /// arrive after the window are served normally.
    public func refuseRequests(for seconds: TimeInterval) {
        lock.lock(); _refusesRequestsUntil = Date().addingTimeInterval(seconds); lock.unlock()
    }

    /// How long a request whose range starts at byte 0 is held before its response is written.
    ///
    /// The restart race is a race against a real HTTP round trip. On loopback that trip is
    /// sub-millisecond, so a test that wants to observe the window has to make it as wide as a
    /// phone's is on a cellular link.
    public var delayForOffsetZero: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delayForOffsetZero }
        set { lock.lock(); _delayForOffsetZero = newValue; lock.unlock() }
    }

    /// Write only this many bytes of each response body, then hold the connection open forever
    /// without closing it — a host that went quiet mid-episode.
    ///
    /// A dropped connection is a different failure and the source already retries it; what a seek
    /// has to survive is the one where nothing arrives and nothing ends, because that is when the
    /// decoder is parked inside a read and the seek is queued behind it. The declared
    /// `Content-Length` is the full slice, so the client goes on waiting.
    public var stallsAfterBodyBytes: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _stallsAfterBodyBytes }
        set { lock.lock(); _stallsAfterBodyBytes = newValue; lock.unlock() }
    }

    /// The start byte of every range served, in order. The restart is visible here as a second
    /// request for byte 0 after the first one has run to the end of the body.
    public var requestedRanges: [Int64] { lock.lock(); defer { lock.unlock() }; return _requestedRanges }

    /// Every request head served, verbatim, so a test can assert on the headers a client sent.
    public var requestHeads: [String] { lock.lock(); defer { lock.unlock() }; return _requestHeads }

    /// How many body bytes have been written out. A read-ahead bound is only observable from the
    /// server's side: the client's own frontier says what it kept, not what it asked the host for.
    public var servedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return _servedBytes }

    /// Answer `200 OK` with the whole body and no `Content-Range`, ignoring any `Range` header —
    /// what a surprising number of podcast CDNs do to a ranged request.
    public var respondsWholeBodyIgnoringRange: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _respondsWholeBodyIgnoringRange }
        set { lock.lock(); _respondsWholeBodyIgnoringRange = newValue; lock.unlock() }
    }

    /// Send no `Content-Length`: with ``respondsWholeBodyIgnoringRange`` the body's length is then
    /// unknown until the connection closes.
    public var omitsContentLength: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _omitsContentLength }
        set { lock.lock(); _omitsContentLength = newValue; lock.unlock() }
    }

    /// Drop the next request's connection without a response, once. The transport failure a retry
    /// has to survive.
    public var failNextRequest: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failNextRequest }
        set { lock.lock(); _failNextRequest = newValue; lock.unlock() }
    }

    /// Hold the response to every request whose `Range` starts at `offset` for `seconds`, and let
    /// every other request through at once. The footer side fetch on a slow CDN while the head
    /// is already on disk: what a probe must not wait on.
    public var delayForRangeStartingAt: (offset: Int64, seconds: TimeInterval)? {
        get { lock.lock(); defer { lock.unlock() }; return _delayForRangeStartingAt }
        set { lock.lock(); _delayForRangeStartingAt = newValue; lock.unlock() }
    }

    /// Send the response headers and the first N body bytes at once, per range start, and hold
    /// the rest of the body until ``releaseHeldBody(forRangeStartingAt:)``. Two things make the
    /// split necessary rather than a headers-only hold: the session hands a response to its
    /// delegate only together with the first bytes of its body, so headers alone put nothing in
    /// front of the client; and the response's disposition is answered from the byte source's own
    /// queue, so a response that lands while that queue is parked by another body's chunk is
    /// stranded, body and all. Sending N bytes up front lets the client answer the disposition
    /// (and see those N bytes) at a moment the test chooses, and the remainder at another (#261).
    public var heldBodyAfterBytesForRangeStartingAt: [Int64: Int] {
        get { lock.lock(); defer { lock.unlock() }; return _heldBodyAfterBytesForRangeStartingAt }
        set { lock.lock(); _heldBodyAfterBytesForRangeStartingAt = newValue; lock.unlock() }
    }

    /// Write the rest of a body held by ``heldBodyAfterBytesForRangeStartingAt`` and close the
    /// connection. Safe to call before the request has arrived: the remainder then goes out with
    /// the first bytes. The remainder counts as served when it is written.
    public func releaseHeldBody(forRangeStartingAt offset: Int64) {
        lock.lock()
        guard let held = _heldRemainders.removeValue(forKey: offset) else {
            _releasedHeldRanges.insert(offset)
            lock.unlock()
            return
        }
        lock.unlock()
        queue.async { self.sendHeldRemainder(held.rest, on: held.connection) }
    }

    /// Close the connection of a body held by ``heldBodyAfterBytesForRangeStartingAt`` without
    /// the rest: a drop mid-body at a moment the test chooses, rather than whenever the server
    /// gets there. False when no such body is held yet.
    @discardableResult
    public func dropHeldBody(forRangeStartingAt offset: Int64) -> Bool {
        lock.lock()
        let held = _heldRemainders.removeValue(forKey: offset)
        lock.unlock()
        guard let held else { return false }
        queue.async { held.connection.cancel() }
        return true
    }

    private func sendHeldRemainder(_ rest: Data, on connection: NWConnection) {
        lock.lock(); _servedBytes += Int64(rest.count); lock.unlock()
        connection.send(content: rest, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Hold EVERY response for this long: a slow network, where any read that reaches the origin
    /// at all shows up as this delay. A cache-served start that touches the network is caught by
    /// this where a per-offset delay would need to guess which range it opened.
    public var delayForEveryRange: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delayForEveryRange }
        set { lock.lock(); _delayForEveryRange = newValue; lock.unlock() }
    }

    /// Answer `503`, once, to the next request whose `Range` starts at this byte, and let every
    /// other request through. The side fetch for the tail failing while the head streams. A
    /// status rather than a dropped connection, because CFNetwork transparently retries a request
    /// whose connection died before any response byte.
    public var rejectNextRangeStartingAt: Int64? {
        get { lock.lock(); defer { lock.unlock() }; return _rejectNextRangeStartingAt }
        set { lock.lock(); _rejectNextRangeStartingAt = newValue; lock.unlock() }
    }

    /// Answer every fixture request whose `Host` header names `host` (e.g. `localhost:<port>`)
    /// with `status` and an empty body, indefinitely. The signed CDN URL whose signature expired:
    /// the remembered end of a chain answers `403` while the chain itself still works.
    public func reject(host: String, status: Int = 403) {
        lock.lock(); _rejectedHostStatus = (host, status); lock.unlock()
    }

    /// Answer every fixture request whose `Host` header names `host` with `200`, `contentType`
    /// and `body`, ignoring the range. The signed CDN URL whose signature expired on a host that
    /// serves a page about it instead of refusing.
    ///
    /// `firstChunkBytes`, when given, splits the body into two writes — the first this many bytes,
    /// the rest in a second write once the first is processed — instead of one: a body whose sniff
    /// cannot be settled by the first delegate chunk alone (#226).
    public func answerWithPage(
        host: String, contentType: String = "text/html; charset=utf-8", body: Data, firstChunkBytes: Int? = nil
    ) {
        lock.lock(); _pageForHost = (host, contentType, body, firstChunkBytes); lock.unlock()
    }

    /// Send redirect hops to `localhost` instead of `127.0.0.1`: a different host to CFNetwork and
    /// to the source's auth-header scope, on the same listener.
    public var redirectsToAlternateHost: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _redirectsToAlternateHost }
        set { lock.lock(); _redirectsToAlternateHost = newValue; lock.unlock() }
    }

    /// Hold every redirect hop's `302` for this long: an ad-stitching chain that is slow but
    /// alive, while its end answers at once.
    public var delayForRedirectHops: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delayForRedirectHops }
        set { lock.lock(); _delayForRedirectHops = newValue; lock.unlock() }
    }

    /// The port the listener bound; zero until `init` returns.
    public private(set) var port: UInt16 = 0

    /// The stitch the origin serves. Settable, because a host re-stitches its ad breaks behind a
    /// stable URL: a test swaps this between requests to stand in for that.
    public var body: Data {
        get { lock.lock(); defer { lock.unlock() }; return _body }
        set { lock.lock(); _body = newValue; _bodies = nil; lock.unlock() }
    }

    /// One stitch per request, in order; the last one serves every request after it. A host that
    /// re-stitches between a listener's first body and their reconnect, made deterministic.
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

    /// A URL that answers `302` `hops` times before landing on ``url``'s path — an enclosure URL
    /// behind a tracking prefix. Each hop is `/redirect/<n>/fixture.mp3`, the last a `302` to
    /// ``fixturePath`` (on `localhost` when ``redirectsToAlternateHost`` is set).
    public func redirectingURL(hops: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/redirect/\(hops)/fixture.mp3")!
    }

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

    // MARK: - Serving

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    /// HTTP/1.1 requests here are tiny and header-only, so the head is read until the blank line and
    /// nothing else is expected on the connection.
    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let terminator = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<terminator.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receiveHead(connection, buffer: accumulated)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        lock.lock()
        let refusing = _refusesRequestsUntil.map { Date() < $0 } ?? false
        // A refused request is logged in `requestHeads` only, not `requestedRanges`: no range is
        // served, and `_bodies` is indexed by `_requestedRanges.count`, so counting a refusal
        // would skip a body in the sequence.
        if refusing { _requestHeads.append(head) }
        lock.unlock()
        guard !refusing else {
            connection.cancel()
            return
        }
        let path = Self.parsePath(head)
        if let hop = Self.redirectHop(path) {
            lock.lock()
            _requestHeads.append(head)
            let alternate = _redirectsToAlternateHost
            let hopDelay = _delayForRedirectHops
            lock.unlock()
            let next = hop > 1
                ? "http://127.0.0.1:\(port)/redirect/\(hop - 1)/fixture.mp3"
                : "http://\(alternate ? "localhost" : "127.0.0.1"):\(port)\(Self.fixturePath)"
            let header = "HTTP/1.1 302 Found\r\nLocation: \(next)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            queue.asyncAfter(deadline: .now() + hopDelay) {
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }
        lock.lock()
        let body = _bodies.map { $0[min(_requestedRanges.count, $0.count - 1)] } ?? _body
        lock.unlock()
        let range = Self.parseRange(head, total: Int64(body.count))
        lock.lock()
        _requestedRanges.append(range.lowerBound)
        _requestHeads.append(head)
        var delay = range.lowerBound == 0 ? _delayForOffsetZero : 0
        if let held = _delayForRangeStartingAt, held.offset == range.lowerBound { delay = held.seconds }
        delay = max(delay, _delayForEveryRange)
        let wholeBody = _respondsWholeBodyIgnoringRange
        let omitsLength = _omitsContentLength
        let shouldFail = _failNextRequest
        if shouldFail { _failNextRequest = false }
        var rejectedRange = false
        if _rejectNextRangeStartingAt == range.lowerBound {
            _rejectNextRangeStartingAt = nil
            rejectedRange = true
        }
        let stallAfter = _stallsAfterBodyBytes
        let rejected = _rejectedHostStatus
        let page = _pageForHost
        let heldAfter = _heldBodyAfterBytesForRangeStartingAt[range.lowerBound]
        lock.unlock()

        guard !shouldFail else {
            connection.cancel()
            return
        }
        if rejectedRange || (rejected != nil && Self.parseHost(head) == rejected?.host) {
            let status = rejectedRange ? 503 : rejected?.status ?? 503
            let header = "HTTP/1.1 \(status) Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        if let page, Self.parseHost(head) == page.host {
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: \(page.contentType)\r\nContent-Length: \(page.body.count)\r\nConnection: close\r\n\r\n".utf8)
            if let firstChunkBytes = page.firstChunkBytes, firstChunkBytes < page.body.count {
                var first = header
                first.append(page.body.prefix(firstChunkBytes))
                let rest = Data(page.body.dropFirst(firstChunkBytes))
                connection.send(content: first, completion: .contentProcessed { [queue] _ in
                    // A gap wide enough that the two writes land as separate reads on the client
                    // instead of coalescing into one over a loopback connection this fast.
                    queue.asyncAfter(deadline: .now() + 0.05) {
                        connection.send(content: rest, completion: .contentProcessed { _ in connection.cancel() })
                    }
                })
                return
            }
            var payload = header
            payload.append(page.body)
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        let slice = wholeBody ? body : body.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
        var header: String
        if wholeBody {
            header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(mimeType)\r\n"
            header += "Accept-Ranges: bytes\r\n"
        } else {
            header = "HTTP/1.1 206 Partial Content\r\n"
            header += "Content-Type: \(mimeType)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            header += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)\r\n"
        }
        if !omitsLength { header += "Content-Length: \(slice.count)\r\n" }
        header += "Connection: close\r\n\r\n"
        if let heldAfter, heldAfter < slice.count {
            // Headers and the first bytes now, the rest on release — see
            // ``heldBodyAfterBytesForRangeStartingAt``.
            var first = Data(header.utf8)
            first.append(slice.prefix(heldAfter))
            let rest = Data(slice.dropFirst(heldAfter))
            lock.lock()
            _servedBytes += Int64(heldAfter)
            let alreadyReleased = _releasedHeldRanges.remove(range.lowerBound) != nil
            if !alreadyReleased { _heldRemainders[range.lowerBound] = (connection, rest) }
            lock.unlock()
            connection.send(content: first, completion: .contentProcessed { [weak self] _ in
                guard alreadyReleased, let self else { return }
                self.sendHeldRemainder(rest, on: connection)
            })
            return
        }
        lock.lock()
        let closeAfter = _closesAfterBodyBytes
        _closesAfterBodyBytes = nil
        let outage = _outageAfterClose
        let lie = _contentLengthLie
        let rate = _bytesPerSecond
        let bursts = _burstPattern
        lock.unlock()

        // How much of the body goes out, and whether the connection is then held (a stall) or
        // closed (a drop, a lie, or simply the end). The smallest bound wins.
        var limit = slice.count
        var holdsOpen = false
        var outageOnClose: TimeInterval?
        if let stallAfter, stallAfter < limit { limit = stallAfter; holdsOpen = true }
        if let closeAfter, closeAfter < limit { limit = closeAfter; holdsOpen = false; outageOnClose = outage }
        if let lie, slice.count - lie < limit { limit = max(slice.count - lie, 0); holdsOpen = false; outageOnClose = nil }
        let written = slice.prefix(limit)

        // A stalled body is never finished and never closed: closing would look like a short read
        // the source retries, which is the recoverable failure, not this one. An outage starts
        // before the close, so the client's first reconnect is already refused.
        let finish = { [weak self] in
            guard !holdsOpen else { return }
            if let outageOnClose { self?.refuseRequests(for: outageOnClose) }
            connection.cancel()
        }
        let send = { [weak self] in
            guard let self else { return }
            if rate == nil && bursts == nil {
                var payload = Data(header.utf8)
                payload.append(written)
                self.lock.lock(); self._servedBytes += Int64(written.count); self.lock.unlock()
                connection.send(content: payload, completion: .contentProcessed { _ in finish() })
                return
            }
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { return }
                self.drip(
                    Data(written), offset: 0, on: connection,
                    pacing: Pacing(bytesPerSecond: rate, burst: bursts, started: Date(), pausedSeconds: 0),
                    finish: finish
                )
            })
        }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: send)
        } else {
            send()
        }
    }

    /// The schedule a dripped body is written on: byte `n` is due at
    /// `started + pausedSeconds + n / bytesPerSecond`, where `pausedSeconds` sums the burst pauses
    /// already taken. Anchored rather than relative, so a slice that went out late does not push
    /// every later one back.
    private struct Pacing {
        let bytesPerSecond: Int?
        let burst: BurstPattern?
        let started: Date
        var pausedSeconds: TimeInterval
    }

    /// One drip slice per call, then the next scheduled on the server queue when it is due. Stops
    /// quietly when a write fails (the client went away, or ``stop()`` cancelled the connection).
    private func drip(_ body: Data, offset: Int, on connection: NWConnection, pacing: Pacing, finish: @escaping () -> Void) {
        guard offset < body.count else {
            finish()
            return
        }
        // ~20 ms of the rate per slice, at least 1 KiB; the whole remainder when unpaced.
        var sliceBytes = pacing.bytesPerSecond.map { max($0 / 50, 1024) } ?? body.count
        var nextPaused = pacing.pausedSeconds
        if let burst = pacing.burst, burst.burstBytes > 0 {
            // Never write across a burst boundary; the pause is taken after the slice that ends it.
            let intoBurst = offset % burst.burstBytes
            sliceBytes = min(sliceBytes, burst.burstBytes - intoBurst)
            if intoBurst + sliceBytes == burst.burstBytes { nextPaused += burst.pauseSeconds }
        }
        let end = min(offset + sliceBytes, body.count)
        let chunk = body.subdata(in: offset..<end)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            self.lock.lock(); self._servedBytes += Int64(chunk.count); self.lock.unlock()
            var next = pacing
            next.pausedSeconds = nextPaused
            let paced = pacing.bytesPerSecond.map { Double(end) / Double($0) } ?? 0
            let due = pacing.started.addingTimeInterval(paced + nextPaused)
            let wait = max(due.timeIntervalSinceNow, 0)
            self.queue.asyncAfter(deadline: .now() + wait) {
                self.drip(body, offset: end, on: connection, pacing: next, finish: finish)
            }
        })
    }

    /// The `Host` header's value, or nil when the request carries none.
    static func parseHost(_ head: String) -> String? {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("host:") {
            return line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The request target of `GET /path HTTP/1.1`, query and all.
    static func parsePath(_ head: String) -> String {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        return parts.count > 1 ? String(parts[1]) : "/"
    }

    /// `n` for `/redirect/<n>/...`, else nil.
    static func redirectHop(_ path: String) -> Int? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "redirect" else { return nil }
        return Int(parts[1])
    }

    /// `bytes=a-b`, `bytes=a-`, or no header at all (the whole body).
    static func parseRange(_ head: String, total: Int64) -> ClosedRange<Int64> {
        let whole: ClosedRange<Int64> = 0...max(total - 1, 0)
        guard let line = head.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("range:")
        }) else { return whole }
        guard let spec = line.split(separator: "=").last else { return whole }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int64(bounds.first ?? "") else { return whole }
        let end = bounds.count > 1 ? Int64(bounds[1]) : nil
        let clampedStart = min(max(start, 0), max(total - 1, 0))
        let clampedEnd = min(end ?? (total - 1), total - 1)
        guard clampedEnd >= clampedStart else { return clampedStart...clampedStart }
        return clampedStart...clampedEnd
    }
}
