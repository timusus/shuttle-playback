import Foundation
import Network

extension LoopbackMediaServer {

    /// HTTP/1.1 requests here are tiny and header-only, so the head is read until the blank line and
    /// nothing else is expected on the connection.
    func receiveHead(_ connection: NWConnection, buffer: Data) {
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
            answerRedirectHop(hop, head: head, on: connection)
            return
        }
        if let (status, location) = Self.redirectSpec(path) {
            answerRedirect(status: status, location: location, head: head, on: connection)
            return
        }
        if path.hasPrefix("/missing/") {
            lock.lock(); _requestHeads.append(head); lock.unlock()
            connection.send(content: errorAnswer(status: 404), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        lock.lock()
        let body = _bodies.map { $0[min(_requestedRanges.count, $0.count - 1)] } ?? _body
        let etag = _etags.map { $0[min(_requestedRanges.count, $0.count - 1)] } ?? _etag
        let gzips = _gzipsBody
        let strict416 = _answers416AtOrAfterEnd
        lock.unlock()
        let range = Self.parseRange(head, total: Int64(body.count))
        let rawStart = Self.rawRangeStart(head)
        let unsatisfiable = strict416 && rawStart.map { $0 >= Int64(body.count) } == true
        // `If-Range` is a validator for the range: stale, the range is dropped for the whole body.
        let staleValidator = Self.parseHeader(head, "if-range").map { $0 != etag } ?? false
        lock.lock()
        _requestedRanges.append(unsatisfiable ? rawStart ?? range.lowerBound : range.lowerBound)
        _requestHeads.append(head)
        var delay = range.lowerBound == 0 ? _delayForOffsetZero : 0
        if let held = _delayForRangeStartingAt, held.offset == range.lowerBound { delay = held.seconds }
        delay = max(delay, _delayForEveryRange)
        let wholeBody = _respondsWholeBodyIgnoringRange || staleValidator
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
            connection.send(content: errorAnswer(status: status), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        if unsatisfiable {
            connection.send(
                content: errorAnswer(status: 416, extra: "Content-Range: bytes */\(body.count)\r\n"),
                completion: .contentProcessed { _ in connection.cancel() }
            )
            return
        }

        if let page, Self.parseHost(head) == page.host {
            answerPage(page, on: connection)
            return
        }

        let plainSlice = wholeBody ? body : body.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
        let slice = gzips ? Self.gzip(plainSlice) : plainSlice
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
        if let etag { header += "ETag: \(etag)\r\n" }
        if gzips { header += "Content-Encoding: gzip\r\n" }
        lock.lock()
        let chunks = _usesChunkedEncoding
        let lower = _lowercasesHeaders
        lock.unlock()
        if chunks {
            header += "Transfer-Encoding: chunked\r\n"
        } else if !omitsLength {
            header += "Content-Length: \(slice.count)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        if lower { header = Self.lowercasingNames(header) }
        if let heldAfter, heldAfter < slice.count {
            sendHeldBody(header: header, slice: slice, heldAfter: heldAfter, rangeStart: range.lowerBound, on: connection)
            return
        }
        sendBody(header: header, slice: slice, chunks: chunks, stallAfter: stallAfter, delay: delay, on: connection)
    }

    private func answerRedirectHop(_ hop: Int, head: String, on connection: NWConnection) {
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
    }

    private func answerRedirect(status: Int, location: RedirectLocation, head: String, on connection: NWConnection) {
        lock.lock(); _requestHeads.append(head); lock.unlock()
        let target: String
        switch location {
        case .absolute: target = "http://127.0.0.1:\(port)\(Self.fixturePath)"
        case .rooted: target = Self.fixturePath
        case .parentRelative: target = "../fixture.mp3"
        case .schemeRelative: target = "//127.0.0.1:\(port)\(Self.fixturePath)"
        }
        connection.send(
            content: errorAnswer(status: status, extra: "Location: \(target)\r\n", withPage: false),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func answerPage(_ page: (host: String, contentType: String, body: Data, firstChunkBytes: Int?), on connection: NWConnection) {
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
    }

    /// Headers and the first bytes now, the rest on release — see
    /// ``heldBodyAfterBytesForRangeStartingAt``.
    private func sendHeldBody(header: String, slice: Data, heldAfter: Int, rangeStart: Int64, on connection: NWConnection) {
        var first = Data(header.utf8)
        first.append(slice.prefix(heldAfter))
        let rest = Data(slice.dropFirst(heldAfter))
        lock.lock()
        _servedBytes += Int64(heldAfter)
        let alreadyReleased = _releasedHeldRanges.remove(rangeStart) != nil
        if !alreadyReleased { _heldRemainders[rangeStart] = (connection, rest) }
        lock.unlock()
        connection.send(content: first, completion: .contentProcessed { [weak self] _ in
            guard alreadyReleased, let self else { return }
            self.sendHeldRemainder(rest, on: connection)
        })
    }

    /// How long a body that ends short stays open after its last byte; see `sendBody`.
    private static let shortBodyCloseDelay: TimeInterval = 0.3

    private func sendBody(header: String, slice: Data, chunks: Bool, stallAfter: Int?, delay: TimeInterval, on connection: NWConnection) {
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
        let written = chunks ? Self.chunked(slice.prefix(limit)) : Data(slice.prefix(limit))

        // A stalled body is never finished and never closed: closing would look like a short read
        // the source retries, which is the recoverable failure, not this one. An outage starts
        // before the close, so the client's first reconnect is already refused.
        // A body that ends short is closed a beat late. URLSession on macOS throws away the body
        // it has buffered when the connection ends before the delegate has answered the response
        // (the client's `didReceive response` completion), and on loopback that answer is not
        // instant. Real networks leave that time; this server has to.
        let endsShort = limit < slice.count
        let finish = { [weak self, queue] in
            guard !holdsOpen else { return }
            if let outageOnClose { self?.refuseRequests(for: outageOnClose) }
            if endsShort {
                queue.asyncAfter(deadline: .now() + Self.shortBodyCloseDelay) { connection.cancel() }
            } else {
                connection.cancel()
            }
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
}
