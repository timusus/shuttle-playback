import Foundation
import Network

// Fault-injection and shaping controls; the serving code reads them under `lock`.
extension LoopbackMediaServer {

    /// Answer `416 Range Not Satisfiable` (with `Content-Range: bytes */<total>`) to a request
    /// whose range starts at or after the end of the body, as a strict origin does, instead of
    /// clamping it to the last byte. The resume of a download that was in fact already complete.
    public var answers416AtOrAfterEnd: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answers416AtOrAfterEnd }
        set { lock.lock(); _answers416AtOrAfterEnd = newValue; lock.unlock() }
    }

    /// Write every response header name in lower case (`content-range`, `etag`), as an HTTP/2
    /// front end or a CDN does. Header names are case-insensitive, so nothing may depend on case.
    public var lowercasesHeaders: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _lowercasesHeaders }
        set { lock.lock(); _lowercasesHeaders = newValue; lock.unlock() }
    }

    /// Send a body as `Transfer-Encoding: chunked`, with no `Content-Length`. A range answer still
    /// carries its `Content-Range`, so only a `200` has no length at all.
    public var usesChunkedEncoding: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _usesChunkedEncoding }
        set { lock.lock(); _usesChunkedEncoding = newValue; lock.unlock() }
    }

    /// Give every error answer (a rejected host or range, a `416`, a missing path) a
    /// `text/html` body with a `Content-Length`, as a real origin's error page does, instead
    /// of an empty one.
    public var htmlErrorBodies: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _htmlErrorBodies }
        set { lock.lock(); _htmlErrorBodies = newValue; lock.unlock() }
    }

    /// Send every body gzip-encoded (`Content-Encoding: gzip`). The declared `Content-Length` is
    /// the encoded size, so it no longer matches the bytes the client ends up with. The range
    /// still names offsets of the plain body; the slice it selects is what is encoded.
    public var gzipsBody: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _gzipsBody }
        set { lock.lock(); _gzipsBody = newValue; lock.unlock() }
    }

    /// A strong `ETag` on every response, e.g. `"v1"` (quotes included). A request carrying
    /// `If-Range` is honoured: a range is served only while the validator matches the current
    /// tag, otherwise the whole current body answers `200`, as RFC 9110 says. Swap ``body`` and
    /// this together to change the resource between a download and its resume.
    public var etag: String? {
        get { lock.lock(); defer { lock.unlock() }; return _etag }
        set { lock.lock(); _etag = newValue; _etags = nil; lock.unlock() }
    }

    /// One `ETag` per request, in order; the last serves every request after it. The counterpart
    /// of ``bodies`` for a validator that changes between a client's response and its reconnect.
    public var etags: [String]? {
        get { lock.lock(); defer { lock.unlock() }; return _etags }
        set { lock.lock(); _etags = newValue; lock.unlock() }
    }

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
    /// declared `Content-Length` still the full slice — the connection that drops mid-file
    /// (airplane mode, a cell handoff). Cleared when it fires, so the client's reconnect is served
    /// whole; set it again for another drop. Unlike ``stallsAfterBodyBytes`` the client sees the
    /// end of the body at once.
    public var closesAfterBodyBytes: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _closesAfterBodyBytes }
        set { lock.lock(); _closesAfterBodyBytes = newValue; lock.unlock() }
    }

    /// With ``closesAfterBodyBytes``: the moment that drop fires, ``refuseRequests(for:)`` this
    /// long, so the drop is the start of an outage rather than one lost connection. Airplane mode
    /// for a few seconds mid-file.
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
    /// without closing it — a host that went quiet mid-file.
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
    /// what a surprising number of media CDNs do to a ranged request.
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
        get { lock.lock(); defer { lock.unlock() }; return _failingRequests > 0 }
        set { lock.lock(); _failingRequests = newValue ? 1 : 0; lock.unlock() }
    }

    /// Drop the connections of the next `count` requests without a response: a run of transport
    /// failures, for a retry budget that one failure cannot exhaust.
    public func failNextRequests(_ count: Int) {
        lock.lock(); _failingRequests = max(count, 0); lock.unlock()
    }

    /// Hold the response to every request whose range starts at byte 0 until
    /// ``releaseOffsetZero()``, so a test decides whether the restart's response or another
    /// request's lands first. Requests for other offsets are served at once.
    public var holdsOffsetZero: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holdsOffsetZero }
        set { lock.lock(); _holdsOffsetZero = newValue; lock.unlock() }
    }

    /// Write the offset-0 responses held by ``holdsOffsetZero`` and stop holding: later requests
    /// for byte 0 are served at once.
    public func releaseOffsetZero() {
        lock.lock()
        _holdsOffsetZero = false
        let held = _heldOffsetZeroSends
        _heldOffsetZeroSends = []
        lock.unlock()
        for send in held { queue.async(execute: send) }
    }

    /// Answer every request `200` with the whole body, no `Content-Length` and no range support
    /// (any `Range` is ignored, no `Accept-Ranges`), ending when the connection closes: a
    /// transcoding origin, whose length nobody knows. Composes with ``stallsAfterBodyBytes``
    /// for one that goes quiet before it ends.
    public var streamsWithoutLength: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _streamsWithoutLength }
        set { lock.lock(); _streamsWithoutLength = newValue; lock.unlock() }
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
    /// (and see those N bytes) at a moment the test chooses, and the remainder at another.
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

    func sendHeldRemainder(_ rest: Data, on connection: NWConnection) {
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
    /// cannot be settled by the first delegate chunk alone.
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

    /// Hold every redirect hop's `302` for this long: a long redirect chain that is slow but
    /// alive, while its end answers at once.
    public var delayForRedirectHops: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delayForRedirectHops }
        set { lock.lock(); _delayForRedirectHops = newValue; lock.unlock() }
    }
}
