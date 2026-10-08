import Foundation
import OSLog
import PlaybackDecode

private let downloadLog = Logger(subsystem: "com.simplecityapps.shuttle-playback", category: "download")

/// **The growing-file source's transaction lifecycle, as one state machine**: ADR-0004's single
/// recovery layer as one module.
///
/// Events go in: the decoder's reads and seeks, a response, body bytes, a task's end, a timer the
/// machine asked for, a new network path. ``Effect``s come out, for the adapter
/// (``GrowingFileByteSource``) to carry out in order: open a file, send a request, cancel a task,
/// schedule a timer, wake a parked read, hand an event out. A read gets a ``ReadStep``: serve from
/// the file, park, end, or fail. Every rule of the source lives here: the read rule (``ReadRule``),
/// the retry budget (``Retry``), resume or restart, the redirect chain's remembered end, the seek
/// generation a transaction carries, the measured rate.
///
/// No lock, task, file or clock: times come in with each event, and every transition is driven by
/// a test with literal numbers. The adapter holds the one lock around every call.
struct GrowingFileDownload {

    // MARK: - Effects and events

    /// A request for the current transaction: `Range: bytes=<from>-`, to `url`.
    struct Request: Equatable {
        /// Names this request; a timer or a callback for an earlier one changes nothing.
        let attempt: Int
        let url: URL
        let from: Int64
        /// The resume's validator: the first response's strong ETag.
        let ifRange: String?
    }

    enum Timer: Equatable {
        /// The backoff of a failed transaction is over: resume or restart it.
        case retry(transaction: Int)
        /// The request has had its wait for a response.
        case response(attempt: Int)
        /// Look whether the body has been silent for ``GrowingFileByteSource/idleTimeoutSeconds``.
        case idle(transaction: Int)
        /// A parked read looks again.
        case recheck
    }

    /// What the adapter does, in order, under its lock unless said otherwise.
    enum Effect: Equatable {
        /// Cancel the current transaction's task and, when `discardFile`, delete its file.
        case retire(discardFile: Bool)
        /// Drop the current transaction: there is none until the next open.
        case release
        /// Make a new partial for the next transaction and report it with ``opened(fileReady:now:)``.
        case openFile
        /// Cancel the current task.
        case cancelTask
        /// Send `request` as the current transaction's task.
        case send(Request)
        case schedule(Timer, after: TimeInterval)
        /// Wake parked reads.
        case wake
        /// Rename the complete file into the cache and report it with ``promoted()``.
        case promote
        /// After the lock is released: reserve room in the store for this many bytes.
        case makeRoom(bytes: Int64)
        /// After the lock is released.
        case emit(GrowingFileEvent)
    }

    /// The parts of a response the lifecycle decides on.
    struct Response: Equatable {
        var status: Int
        var contentRange: String?
        var mimeType: String?
        /// `expectedContentLength`, -1 when unknown.
        var expectedContentLength: Int64 = -1
        var entityTag: String?
        /// Where the response came from: the redirect chain's end.
        var url: URL?
    }

    /// A read's next step: carry out `effects`, then do `action`.
    struct ReadStep: Equatable {
        enum Action: Equatable {
            /// Copy `count` bytes at `fileOffset` of the current file, then ``advance(by:)``.
            /// `landed`: report that seek's landing first.
            case serve(fileOffset: Int64, count: Int, landed: Int?)
            /// Answer 0, after reporting `landed`.
            case endOfStream(landed: Int?)
            /// Wait for a wake.
            case park
            /// Ask again at once: a transaction was opened.
            case again
            case fail(StreamByteReaderError)
        }

        var effects: [Effect]
        var action: Action
    }

    // MARK: - One transaction

    /// One transaction's state: one file, one base, one or more requests (a resume is another).
    struct Transaction: Equatable {
        let id: Int
        var generation: Int
        var seekGeneration: Int?
        /// False once the partial is deleted: nothing of it is readable any more.
        var hasFile = true
        /// The current request went to the redirect chain's remembered end, not the requested URL.
        var remembered: Bool
        /// The current request's ``Request/attempt``.
        var attempt = 0
        /// A resume is in flight: the byte its `206` must start at. Nil once it is answered.
        var resumeAt: Int64?
        /// The first response's strong ETag, the resume's `If-Range`.
        var entityTag: String?
        var base: Int64
        /// This transaction's own, from its response; never inherited from an earlier transaction's body.
        var totalLength: Int64?
        /// Bytes in the file.
        var written: Int64 = 0
        /// The body's first bytes are not yet proven to be media; nothing is readable until they are.
        var sniffPending = false
        /// A response arrived, whatever it said. A failure before one is the link's, not the host's.
        var answered = false
        /// The time the current request went out.
        var attemptStartedAt: TimeInterval = 0
        /// Done with the network: complete, failed, or handed to a retry.
        var ended = false
        var isComplete = false
        var isCached = false
        /// The time of the response or the last body chunk, whichever came later.
        var lastByteAt: TimeInterval = 0
        /// An idle check is scheduled; one at a time.
        var idleCheckPending = false
        var frontier: Int64 { base + (sniffPending || !hasFile ? 0 : written) }
    }

    // MARK: - State

    let url: URL
    private(set) var current: Transaction?
    /// The decoder's read position.
    private(set) var offset: Int64 = 0
    private(set) var generation = 0
    /// Reads that have parked at the frontier so far.
    private(set) var parks = 0
    /// Set around the decoder's `open()`; see ``ReadRule``.
    var isProbing = false
    private(set) var startup = GrowingFileByteSource.Startup()
    private(set) var retry = Retry()
    private(set) var cancelled = false
    private var interrupted = false
    /// A seek announced by ``willSeek(generation:)`` that no read has answered yet. The read that
    /// answers it claims it, once: it opens the transaction that carries it, or finds its bytes
    /// already in the file and reports ``GrowingFileEvent/seekLanded(seekGeneration:)``. `sought`
    /// says the decoder moved the read position for it; one it answered from its own buffer never
    /// did, and the read after it is no seek's, so it tags nothing.
    private var unclaimedSeek: (generation: Int, sought: Bool)?
    /// A parked read's recheck is scheduled; one at a time however often the read wakes.
    private var recheckPending = false
    /// Why the current transaction cannot deliver more; a read at its frontier throws it.
    private var failure: String?
    /// The failure a read threw, until the next ``seek(to:)`` or ``willSeek(generation:)``: a read
    /// after the throw throws it again instead of opening a transaction nobody asked for.
    private var stickyFailure: String?
    /// The resource's length as the last accepted response gave it: what ``totalLength`` and the
    /// snapshot answer once a failed read has dropped the transaction that knew it.
    private var lastKnownTotalLength: Int64?
    /// The host answered a ranged request with `200`: every later transaction starts at byte 0.
    private(set) var rangeIgnored = false
    /// The end of the redirect chain, from the first response; later requests go straight there
    /// until one there is refused or unanswered.
    private(set) var finalURL: URL?
    /// The chain's end was just forgotten: the next request walks the chain from `url` with the
    /// generous wait, even as a retry. Once; the request it goes with clears it.
    private var chainEndForgotten = false
    /// The last accepted response's time from its request going out: what a new request costs,
    /// which ``ReadRule`` weighs a seek's wait against.
    private(set) var responseLatency: TimeInterval?
    private var samples: [(at: TimeInterval, bytes: Int)] = []
    private var firstSampleAt: TimeInterval?
    private var lastDownloadEventAt: TimeInterval = -.infinity
    private var transactionsOpened = 0
    private var attemptsSent = 0
    /// An ``Effect/openFile`` is out: what the transaction it opens is.
    private var pendingOpen: (base: Int64, seekGeneration: Int?, retrying: Bool)?
    /// The last read step opened a transaction because there was none; if it is still missing the
    /// read fails instead of asking again.
    private var readOpened = false
    private var effects: [Effect] = []

    init(url: URL) {
        self.url = url
    }

    // MARK: - Published state

    var totalLength: Int64? { current?.totalLength ?? lastKnownTotalLength }

    mutating func snapshot(fileURL: URL?, now: TimeInterval) -> GrowingFileSnapshot {
        GrowingFileSnapshot(
            base: current?.base ?? offset,
            frontier: current?.frontier ?? offset,
            totalLength: totalLength,
            isComplete: current?.isComplete ?? false,
            fileURL: fileURL,
            transactionGeneration: generation,
            seekGeneration: current?.seekGeneration,
            downloadBytesPerSecond: downloadBytesPerSecond(now: now)
        )
    }

    /// Body bytes per second over the last ``GrowingFileByteSource/throughputWindowSeconds``.
    mutating func downloadBytesPerSecond(now: TimeInterval) -> Double? {
        guard let firstSampleAt else { return nil }
        samples.removeAll { now - $0.at > GrowingFileByteSource.throughputWindowSeconds }
        let span = min(GrowingFileByteSource.throughputWindowSeconds, max(0.25, now - firstSampleAt))
        return Double(samples.reduce(0) { $0 + $1.bytes }) / span
    }

    // MARK: - The decoder's side

    /// The player's seek of `generation` is about to be issued; nil drops a claim no read has taken.
    mutating func willSeek(generation: Int?) {
        unclaimedSeek = generation.map { ($0, false) }
        stickyFailure = nil
    }

    mutating func seek(to newOffset: Int64) throws {
        if cancelled { throw StreamByteReaderError.cancelled }
        if interrupted { throw StreamByteReaderError.interrupted }
        guard newOffset >= 0 else { throw StreamByteReaderError.unseekable }
        offset = newOffset
        unclaimedSeek?.sought = true
        stickyFailure = nil
    }

    mutating func interrupt() -> [Effect] {
        interrupted = true
        return [.wake]
    }

    mutating func clearInterrupt() {
        interrupted = false
    }

    /// A read of up to `maxLength` bytes at the decoder's position.
    mutating func read(maxLength: Int, now: TimeInterval) -> ReadStep {
        let opened = readOpened
        readOpened = false
        if cancelled { return step(.fail(.cancelled)) }
        if interrupted { return step(.fail(.interrupted)) }
        guard let tx = current else {
            if opened { return step(.fail(.transport(failure ?? "no transaction"))) }
            if let reason = stickyFailure { return step(.fail(.transport(reason))) }
            start(at: offset, seekGeneration: claimSeek())
            readOpened = true
            return step(.again)
        }
        // A failure that deleted the file (a page, a full disk) took its frontier with it, so the
        // decoder's next read is no seek ahead: it gets the failure.
        if let reason = failure, !tx.hasFile { return reportFailure(reason) }
        let action = ReadRule.action(
            position: offset, base: tx.base, frontier: tx.frontier, totalLength: tx.totalLength,
            isComplete: tx.isComplete, isProbing: isProbing, rangeIgnored: rangeIgnored,
            downloadBytesPerSecond: downloadBytesPerSecond(now: now), responseLatency: responseLatency
        )
        switch action {
        case .serve:
            let count = Int(min(Int64(maxLength), tx.frontier - offset))
            return step(.serve(fileOffset: offset - tx.base, count: count, landed: landSeek()))
        case .endOfStream:
            return step(.endOfStream(landed: landSeek()))
        case .restart:
            retry.reset()
            start(at: offset, seekGeneration: claimSeek())
            return step(.again)
        case .wait:
            if let reason = failure { return reportFailure(reason) }
            parks += 1
            if !recheckPending {
                recheckPending = true
                effects.append(.schedule(.recheck, after: GrowingFileByteSource.recheckSeconds))
            }
            return step(.park)
        }
    }

    /// The failed transaction goes with the error. The error stays until a seek (Play once the
    /// player shows it seeks to where it stopped), whose read opens a fresh one there with a fresh
    /// budget; the total length stays known.
    private mutating func reportFailure(_ reason: String) -> ReadStep {
        retireCurrent()
        current = nil
        effects.append(.release)
        failure = nil
        stickyFailure = reason
        retry.reset()
        return step(.fail(.transport(reason)))
    }

    /// A served read copied `count` bytes.
    mutating func advance(by count: Int) {
        offset += Int64(count)
    }

    /// Ends the download: a new load or stop. Logs what was fetched and never read.
    mutating func cancel() -> [Effect] {
        guard !cancelled else { return [] }
        cancelled = true
        if let tx = current {
            let wasted = max(0, tx.frontier - max(offset, tx.base))
            let share = tx.totalLength.map { $0 > 0 ? Double(wasted) / Double($0) : 0 } ?? 0
            downloadLog.info("download: cancel bytes_wasted=\(wasted) share=\(share, format: .fixed(precision: 3))")
            retireCurrent()
        }
        effects.append(.wake)
        return takeEffects()
    }

    /// The complete file leaves the cache: whether there was one, which the adapter deletes.
    mutating func dropCachedFile() -> Bool {
        guard let tx = current, tx.isCached, tx.hasFile else { return false }
        current?.hasFile = false
        current?.isCached = false
        return true
    }

    // MARK: - Transactions

    /// The answer to an ``Effect/openFile``: the new transaction's request goes out, or, without a
    /// file, there is no transaction and `failure` says why.
    mutating func opened(fileReady: Bool, now: TimeInterval) -> [Effect] {
        guard let open = pendingOpen else { return [] }
        pendingOpen = nil
        guard fileReady else {
            failure = "cannot open a partial"
            return takeEffects() + [.wake]
        }
        generation += 1
        transactionsOpened += 1
        current = Transaction(
            id: transactionsOpened, generation: generation, seekGeneration: open.seekGeneration,
            remembered: finalURL != nil, base: open.base
        )
        if startup.requestIssuedAt == nil { startup.requestIssuedAt = now }
        send(from: open.base, ifRange: nil, retrying: open.retrying, now: now)
        let opened = generation, host = url.host ?? "?"
        downloadLog.info("download: open gen=\(opened) base=\(open.base) host=\(host, privacy: .public)")
        return takeEffects() + [.wake]
    }

    /// The complete file is the cache's now.
    mutating func promoted() {
        current?.isCached = true
        if let tx = current { downloadLog.info("download: cached gen=\(tx.generation)") }
    }

    /// A hop of the redirect chain, before the first accepted response.
    mutating func redirected(toHost host: String?) {
        if startup.firstResponseAt == nil, let host { startup.hosts.append(host) }
    }

    /// Retires the current transaction and asks for one at `start` (0 once the host ignores ranges).
    /// - Parameters:
    ///   - seekGeneration: the seek this transaction answers, nil when none asked for it.
    ///   - retrying: a retry's restart, whose request waits the shorter time (``target(retrying:)``).
    private mutating func start(at start: Int64, seekGeneration: Int?, retrying: Bool = false) {
        if current != nil { retireCurrent() }
        current = nil
        failure = nil
        pendingOpen = (rangeIgnored ? 0 : start, seekGeneration, retrying)
        effects.append(.openFile)
    }

    /// The seek waiting for a read, taken by the read that answers it: its generation when the
    /// read is at the position that seek moved to, the tag for a transaction this read opens.
    private mutating func claimSeek() -> Int? {
        defer { unclaimedSeek = nil }
        guard let claim = unclaimedSeek, claim.sought else { return nil }
        return claim.generation
    }

    /// The seek waiting for a read, answered from the file: whether or not the decoder moved for
    /// it, no transaction will carry it.
    private mutating func landSeek() -> Int? {
        defer { unclaimedSeek = nil }
        return unclaimedSeek?.generation
    }

    /// Cancels the task and deletes the file unless it is the cache's now.
    private mutating func retireCurrent() {
        guard let tx = current else { return }
        current?.ended = true
        let discard = tx.hasFile && !tx.isCached
        if discard { current?.hasFile = false }
        effects.append(.retire(discardFile: discard))
    }

    /// The current transaction delivers no more. Retryable with retries left: after a backoff, a
    /// resume from the frontier or a restart at the decoder's position (``retryCurrent(now:)``),
    /// the file still read until then. Otherwise the read reports `reason` at the frontier, and a
    /// failure no retry fixes (a page, a full disk) deletes the file.
    ///
    /// An outage the host never answered spends no attempt while the link window lasts: the read
    /// waits through it, which the player shows as buffering, instead of failing a second into it.
    /// The window runs from when the link went quiet: `quietSince` when given (a silent
    /// body's last byte), else the start of the attempt nothing answered.
    ///
    /// `refused`: the host said no to this URL (a `4xx`, a page). That, or no answer at all, from
    /// the chain's remembered end forgets it: a signed hop may have expired. `pathChanged`: the
    /// source ended the request itself for a new network path, so no answer yet is not the end's.
    private mutating func end(
        _ reason: String, retryable: Bool, refused: Bool = false, pathChanged: Bool = false,
        quietSince: TimeInterval? = nil, now: TimeInterval
    ) {
        guard let tx = current else { return }
        current?.ended = true
        effects.append(.cancelTask)
        if tx.remembered, refused || (!tx.answered && !pathChanged), let end = finalURL {
            finalURL = nil
            // Without a chain there is nothing to walk again, so no longer wait for it either.
            chainEndForgotten = end != url
        }
        let decision = retry.failed(
            answered: tx.answered, retryable: retryable,
            quietSince: quietSince ?? (tx.answered ? nil : tx.attemptStartedAt), now: now
        )
        guard case .retry(let backoff) = decision else {
            downloadLog.error("download: failed gen=\(tx.generation) \(reason, privacy: .public)")
            if !retryable { retireCurrent() }
            failure = reason
            effects.append(.wake)
            return
        }
        let attempt = retry.failuresInRow
        downloadLog.error(
            "download: retry gen=\(tx.generation) attempt=\(attempt) answered=\(tx.answered) \(reason, privacy: .public)"
        )
        effects.append(.schedule(.retry(transaction: tx.id), after: backoff))
    }

    /// The retry ``end(_:retryable:refused:pathChanged:quietSince:now:)`` scheduled. A file that
    /// holds the decoder's position is resumed from its frontier, keeping every byte ahead of the
    /// decoder; anything else (nothing proven in it yet, a seek that left it, a host that ignores
    /// ranges) restarts at the decoder's position. Neither is the seek's: a restart carries no seek
    /// generation and claims none, and a resume keeps the one its transaction had.
    private mutating func retryCurrent(now: TimeInterval) {
        guard let tx = current else { return }
        let resumable = !rangeIgnored && tx.hasFile && !tx.isCached && !tx.sniffPending
            && tx.written > 0 && offset >= tx.base && offset <= tx.frontier
        guard resumable else {
            start(at: offset, seekGeneration: nil, retrying: true)
            return
        }
        let from = tx.frontier
        current?.ended = false
        current?.answered = false
        current?.resumeAt = from
        current?.remembered = finalURL != nil
        send(from: from, ifRange: tx.entityTag, retrying: true, now: now)
        let decoder = offset
        downloadLog.info("download: resume gen=\(tx.generation) at=\(from) decoder=\(decoder)")
    }

    /// The current transaction's next request, and its wait for a response: ``target(retrying:)``'s,
    /// cut at the link window's end. The session's own timeout is real time, restarted on every
    /// hop, and longer.
    private mutating func send(from: Int64, ifRange: String?, retrying: Bool, now: TimeInterval) {
        let target = target(retrying: retrying)
        attemptsSent += 1
        current?.attempt = attemptsSent
        current?.attemptStartedAt = now
        let wait = min(target.timeout, retry.linkWindowLeft(now: now) ?? target.timeout)
        effects.append(.schedule(.response(attempt: attemptsSent), after: wait))
        effects.append(.send(Request(attempt: attemptsSent, url: target.url, from: from, ifRange: ifRange)))
    }

    /// Where the next request goes and how long it waits for its response: the chain's remembered
    /// end when there is one, else the requested URL. A retry waits
    /// ``GrowingFileByteSource/retryRequestTimeoutSeconds`` unless it walks the chain again because
    /// its end was just forgotten; that one, like a transaction's first request, waits
    /// ``GrowingFileByteSource/requestTimeoutSeconds``.
    private mutating func target(retrying: Bool) -> (url: URL, timeout: TimeInterval) {
        defer { chainEndForgotten = false }
        let short = retrying && (finalURL != nil || !chainEndForgotten)
        return (
            finalURL ?? url,
            short ? GrowingFileByteSource.retryRequestTimeoutSeconds : GrowingFileByteSource.requestTimeoutSeconds
        )
    }

    /// Asks for an idle check ``GrowingFileByteSource/idleTimeoutSeconds`` from now (or `seconds`).
    private mutating func scheduleIdleCheck(after seconds: TimeInterval = GrowingFileByteSource.idleTimeoutSeconds) {
        guard let tx = current, !tx.idleCheckPending else { return }
        current?.idleCheckPending = true
        effects.append(.schedule(.idle(transaction: tx.id), after: seconds))
    }

    private mutating func step(_ action: ReadStep.Action) -> ReadStep {
        ReadStep(effects: takeEffects(), action: action)
    }

    private mutating func takeEffects() -> [Effect] {
        defer { effects = [] }
        return effects
    }

    // MARK: - Timers and the network path

    mutating func fire(_ timer: Timer, now: TimeInterval) -> [Effect] {
        switch timer {
        case .recheck:
            recheckPending = false
            effects.append(.wake)
        case .retry(let id):
            guard !cancelled, current?.id == id else { break }
            retryCurrent(now: now)
        case .response(let attempt):
            guard !cancelled, let tx = current, tx.attempt == attempt, !tx.answered, !tx.ended else { break }
            end("no_response_s=\(Int(now - tx.attemptStartedAt))", retryable: true, now: now)
        case .idle(let id):
            // Ends the body once it has been silent for the idle timeout: a failure like a drop,
            // into the retry. Looks again when a chunk came in the meantime, and stops once the
            // transaction is done with the network. The link went quiet at the last byte, so that
            // is where the link window starts if nothing answers the retry. Nothing is checked
            // before the response arrives: that wait is the response timer's.
            guard current?.id == id else { break }
            current?.idleCheckPending = false
            guard !cancelled, let tx = current, tx.answered, !tx.ended, !tx.isComplete else { break }
            let silent = now - tx.lastByteAt
            guard silent >= GrowingFileByteSource.idleTimeoutSeconds else {
                scheduleIdleCheck(after: GrowingFileByteSource.idleTimeoutSeconds - silent)
                break
            }
            end("idle_s=\(Int(silent)) at=\(tx.frontier)", retryable: true, quietSince: tx.lastByteAt, now: now)
        }
        return takeEffects()
    }

    /// A usable network path replaced the one the transaction's connection is on (Wi-Fi gone to
    /// cellular). That connection may never say another word, and the idle check would take
    /// ``GrowingFileByteSource/idleTimeoutSeconds`` to notice; the transaction is ended now
    /// instead, like a drop, and ``Retry`` decides on it as on any other: a resume from the
    /// frontier after the backoff, from the same budget. A transaction done with the network, or
    /// whose every byte is in and only its completion is still on the way, is left alone.
    mutating func pathChanged(now: TimeInterval) -> [Effect] {
        guard !cancelled, let tx = current, !tx.ended, !tx.isComplete, tx.frontier != tx.totalLength else { return [] }
        end("path_changed at=\(tx.frontier)", retryable: true, pathChanged: true, now: now)
        return takeEffects()
    }

    /// The system refused the origin's certificate and the user trusted no such leaf: the read fails
    /// at once, with no retry.
    mutating func certificateRejected(attempt: Int, now: TimeInterval) -> [Effect] {
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return [] }
        end(GrowingFileConnectionPolicy.untrustedCertificateReason, retryable: false, now: now)
        return takeEffects()
    }

    // MARK: - The request's answers

    /// The response to the request `attempt`: whether its body is taken.
    mutating func received(_ response: Response, attempt: Int, now: TimeInterval) -> (allow: Bool, effects: [Effect]) {
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return (false, []) }
        let allow = accept(response, tx, now: now)
        return (allow, takeEffects())
    }

    private mutating func accept(_ response: Response, _ tx: Transaction, now: TimeInterval) -> Bool {
        // The link is up, whatever the host says next.
        current?.answered = true
        retry.linkAnswered()
        let status = response.status
        let contentRange = response.contentRange
        let range = Self.contentRange(contentRange)
        if let total = Self.totalEndingAt(tx.resumeAt ?? tx.base, status: status, contentRange: contentRange),
           lastKnownTotalLength.map({ $0 == total }) ?? true {
            // The host says the resource ends exactly where this transaction starts: a `416`
            // with `bytes */N`, or a range clamped to the last byte, at position N. As media3
            // does, that is a zero-length open: the length is learned and the read is at its
            // end. A resume at the frontier is the same open, there. A total that differs from
            // the one already known (the file shrank) is refused like any other answer.
            downloadLog.info("download: open_at_end gen=\(tx.generation) status=\(status) total=\(total)")
            current?.resumeAt = nil
            current?.ended = true
            current?.isComplete = true
            current?.totalLength = total
            lastKnownTotalLength = total
            if finalURL == nil { finalURL = response.url }
            recordResponse(tx, status: status, now: now)
            effects.append(.emit(.transaction(base: tx.base, generation: tx.generation, seekGeneration: tx.seekGeneration, httpStatus: status)))
            effects.append(.emit(.download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: true)))
            effects.append(.wake)
            return false
        }
        if let resumeAt = tx.resumeAt {
            current?.resumeAt = nil
            // The same bytes from the frontier on, as far as the host lets that be checked:
            // the start asked for, and the total the file was begun under.
            let sameTotal = range?.total.map { tx.totalLength == nil || $0 == tx.totalLength } ?? true
            switch status {
            case 206 where range?.start == resumeAt && sameTotal:
                break
            case 200, 206, 416:
                // The range ignored, or a different file behind the URL: not these bytes' end.
                downloadLog.warning(
                    "download: resume_refused gen=\(tx.generation) status=\(status) content-range=\(contentRange ?? "-", privacy: .public)"
                )
                // A retry's restart, to the end of the chain that just answered: the short wait.
                if finalURL == nil { finalURL = response.url }
                start(at: offset, seekGeneration: nil, retrying: true)
                return false
            default:
                end(
                    "status=\(status) content-range=\(contentRange ?? "-")", retryable: true,
                    refused: (400..<500).contains(status), now: now
                )
                return false
            }
            if Self.isMedia(mimeType: response.mimeType) == false {
                end("not audio: content-type=\(response.mimeType ?? "?")", retryable: tx.remembered, refused: true, now: now)
                return false
            }
            if tx.totalLength == nil { current?.totalLength = range?.total }
            lastKnownTotalLength = current?.totalLength
            if let total = current?.totalLength { effects.append(.makeRoom(bytes: total - resumeAt)) }
            if finalURL == nil { finalURL = response.url }
            recordResponse(tx, status: status, now: now)
            current?.lastByteAt = now
            scheduleIdleCheck()
            effects.append(.wake)
            return true
        }
        switch status {
        case 200:
            if tx.base > 0 {
                // The host ignored the range: this body is the file from byte 0, and the read
                // waits for its position to arrive. Restarting would only get 200 again. A new
                // base is a new generation, so a frontier never moves back within one.
                if !rangeIgnored {
                    let host = url.host ?? "?"
                    downloadLog.warning("download: range_ignored host=\(host, privacy: .public) asked=\(tx.base)")
                }
                rangeIgnored = true
                generation += 1
                current?.base = 0
                current?.generation = generation
                // Byte 0 is not where the seek landed, so it is no anchor for it.
                current?.seekGeneration = nil
            }
        case 206 where range?.start == tx.base:
            break
        default:
            end(
                "status=\(status) content-range=\(contentRange ?? "-")", retryable: true,
                refused: (400..<500).contains(status), now: now
            )
            return false
        }
        guard let accepted = current else { return false }
        switch Self.isMedia(mimeType: response.mimeType) {
        case false?:
            // From the remembered end of the chain, the page may be its signature expiring.
            end("not audio: content-type=\(response.mimeType ?? "?")", retryable: accepted.remembered, refused: true, now: now)
            return false
        case nil: current?.sniffPending = accepted.base == 0
        case true?: break
        }
        let total = range?.total
            ?? (response.expectedContentLength > 0 ? response.expectedContentLength + accepted.base : nil)
        current?.totalLength = total
        lastKnownTotalLength = total
        if let total { effects.append(.makeRoom(bytes: total - accepted.base)) }
        if let tag = response.entityTag, !tag.hasPrefix("W/") { current?.entityTag = tag }
        if finalURL == nil { finalURL = response.url }
        recordResponse(accepted, status: status, now: now)
        effects.append(.emit(.transaction(
            base: accepted.base, generation: accepted.generation, seekGeneration: accepted.seekGeneration, httpStatus: status
        )))
        current?.lastByteAt = now
        scheduleIdleCheck()
        effects.append(.wake)
        return true
    }

    /// An accepted response to `tx`'s current request: its latency, and the startup's first answer.
    private mutating func recordResponse(_ tx: Transaction, status: Int, now: TimeInterval) {
        responseLatency = now - tx.attemptStartedAt
        guard startup.firstResponseAt == nil else { return }
        startup.firstResponseAt = now
        startup.status = status
        startup.remembered = tx.remembered
    }

    /// Where a chunk of the request `attempt`'s body goes in the file; nil when that body is no
    /// longer wanted.
    func chunkOffset(attempt: Int) -> Int64? {
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return nil }
        return tx.written
    }

    /// A chunk of `count` bytes was written at ``chunkOffset(attempt:)``, or failed with `writeError`.
    /// - Parameter head: the file's first ``GrowingFileByteSource/sniffBytes``, for the media
    ///   sniff; nil when they cannot be read.
    mutating func chunkWritten(
        _ count: Int, attempt: Int, writeError: Int32? = nil, now: TimeInterval, head: () -> [UInt8]?
    ) -> [Effect] {
        // Still this request's: across the write, an idle check may have ended it and a resume
        // gone out from the frontier this chunk would move, under the same transaction.
        guard let tx = current, tx.attempt == attempt, !tx.ended else { return [] }
        if let writeError {
            end("write failed errno=\(writeError)", retryable: false, now: now)
            return takeEffects()
        }
        current?.written += Int64(count)
        current?.lastByteAt = now
        if tx.sniffPending, tx.written + Int64(count) >= Int64(GrowingFileByteSource.sniffBytes) {
            guard let bytes = head(), Self.isMedia(mimeType: nil, head: bytes) == true else {
                end("not audio: body sniff", retryable: tx.remembered, refused: true, now: now)
                return takeEffects()
            }
            current?.sniffPending = false
        }
        // Progress is the decoder's: a host that drops before the read position (a 200 from
        // byte 0, every time) spends its retries instead of looping.
        if let frontier = current?.frontier, frontier > offset { retry.reset() }
        if firstSampleAt == nil { firstSampleAt = now }
        samples.append((now, count))
        if now - lastDownloadEventAt >= GrowingFileByteSource.downloadEventSeconds, let frontier = current?.frontier {
            lastDownloadEventAt = now
            effects.append(.emit(.download(frontier: frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: false)))
        }
        effects.append(.wake)
        return takeEffects()
    }

    /// The request `attempt` ended: its body is whole when `errorCode` is nil.
    mutating func completed(attempt: Int, errorCode: Int?, now: TimeInterval) -> [Effect] {
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return [] }
        if let errorCode {
            end("error=\(errorCode)", retryable: true, now: now)
            return takeEffects()
        }
        if tx.sniffPending {
            end("not audio: body of \(tx.written) bytes", retryable: tx.remembered, refused: true, now: now)
            return takeEffects()
        }
        if let total = tx.totalLength, tx.frontier < total {
            end("short body ended=\(tx.frontier) total=\(total)", retryable: true, now: now)
            return takeEffects()
        }
        current?.ended = true
        current?.isComplete = true
        let total = tx.totalLength ?? tx.frontier
        current?.totalLength = total
        lastKnownTotalLength = total
        if tx.base == 0, tx.hasFile { effects.append(.promote) }
        downloadLog.info("download: complete gen=\(tx.generation) base=\(tx.base) frontier=\(tx.frontier)")
        effects.append(.emit(.download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: true)))
        effects.append(.wake)
        return takeEffects()
    }

    // MARK: - Reading a response

    /// `X` and `Z` of `bytes X-Y/Z`; `Z` is nil for `*`.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst("bytes ".count).split(whereSeparator: { "-/".contains($0) })
        guard parts.count == 3, let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, Int64(parts[2].trimmingCharacters(in: .whitespaces)))
    }

    /// The resource's total when an answer says it ends exactly at `base` (a request's start or a
    /// resume's frontier): a `416` with `Content-Range: bytes */<base>`, or a `206` clamped to the
    /// last byte (`bytes X-Y/<base>` with `X` before `base`). Nil for any other answer.
    static func totalEndingAt(_ base: Int64, status: Int, contentRange header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count)
        let total: Int64?
        switch status {
        case 416:
            guard spec.hasPrefix("*/") else { return nil }
            total = Int64(spec.dropFirst(2).trimmingCharacters(in: .whitespaces))
        case 206:
            guard let range = contentRange(header), range.start < base else { return nil }
            total = range.total
        default:
            return nil
        }
        return total == base ? base : nil
    }

    /// Whether a body is media. A page by its type, what a signed URL past its expiry
    /// answers with, never is; an audio or video type is. Otherwise (`application/octet-stream`
    /// names nothing) the body's first ``GrowingFileByteSource/sniffBytes`` decide when given: an
    /// mp3 or ADTS frame sync, an ID3 tag, or a container's magic, which a page never starts with.
    /// Nil: undecided.
    static func isMedia(mimeType: String?, head: [UInt8]? = nil) -> Bool? {
        let type = mimeType?.lowercased() ?? ""
        if type == "text/html" || type == "application/xhtml+xml" { return false }
        if type.hasPrefix("audio/") || type.hasPrefix("video/") || type == "application/ogg" { return true }
        guard let head else { return nil }
        guard head.count >= GrowingFileByteSource.sniffBytes else { return false }
        if head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return true }
        let magic = String(decoding: head[0..<4], as: UTF8.self)
        return magic.hasPrefix("ID3") || ["OggS", "fLaC", "RIFF"].contains(magic)
            || String(decoding: head[4..<8], as: UTF8.self) == "ftyp"
    }
}

// MARK: - The read rule

extension GrowingFileDownload {

    /// **What a read at a position of a growing file does**: the seek-wait rule, pinned with
    /// literal numbers.
    enum ReadRule {

        /// The tail FFmpeg's MP3 open looks at while probing, and why it is the one footer rule
        /// left (ADR-0003): `mp3_read_header` reads an ID3v1 tag from exactly the last 128 bytes
        /// (`ff_id3v1_read`) and an APE footer from the last 32, inside it. Answering that look
        /// with end of file during the probe keeps the head download running.
        static let footerBytes: Int64 = 128

        enum Action: Equatable, Sendable {
            /// `position` is in `[base, frontier)`: copy from the file.
            case serve
            /// End of stream: answer 0.
            case endOfStream
            /// Block until bytes land, the body completes, or a cancel or interrupt arrives.
            case wait
            /// Cancel the download and open a new transaction, into a new file, at `position`.
            case restart
        }

        /// Decided on the first read at a position, never at the seek: the ID3v1 probe seeks to the
        /// footer, reads it and seeks back, and deciding at the seek would cancel the head download for
        /// a read that never needed the network.
        ///
        /// A gap ahead of the frontier is waited for only while the download closes it sooner than a
        /// new request would answer (`gap / rate < responseLatency`); otherwise the download restarts
        /// at the position (issue #68). media3's `seekToUs` never waits on a seek its buffer cannot
        /// serve: it cancels the loader and loads from the target.
        ///
        /// - Parameters:
        ///   - isProbing: the decoder is inside `open()`; a footer look past the frontier is then
        ///     answered EOF at once (FFmpeg reads that as "no footer"). Outside the probe the same read
        ///     waits, or the last frames would be cut.
        ///   - rangeIgnored: the host answered a ranged request with `200`; a restart would only be
        ///     answered from byte 0 again, so everything ahead is waited for.
        ///   - downloadBytesPerSecond: the observed download rate; nil (no sample yet) restarts.
        ///   - responseLatency: how long this source's last accepted response took to arrive after
        ///     its request went out; nil (none yet) restarts.
        static func action(
            position: Int64,
            base: Int64,
            frontier: Int64,
            totalLength: Int64?,
            isComplete: Bool,
            isProbing: Bool,
            rangeIgnored: Bool,
            downloadBytesPerSecond: Double?,
            responseLatency: TimeInterval?
        ) -> Action {
            if position >= base, position < frontier { return .serve }
            if let totalLength, position >= totalLength { return .endOfStream }
            if position < base { return .restart }
            if isComplete { return .endOfStream }
            if isProbing, let totalLength, position >= totalLength - footerBytes { return .endOfStream }
            if position == frontier || rangeIgnored { return .wait }
            guard let downloadBytesPerSecond, downloadBytesPerSecond > 0, let responseLatency else { return .restart }
            return Double(position - frontier) / downloadBytesPerSecond < responseLatency ? .wait : .restart
        }
    }
}

// MARK: - The retry budget

extension GrowingFileDownload {

    /// **Whether a failed download transaction is tried again, and after how long**.
    ///
    /// - A failure the host answered (a refused status, a body cut short) spends one of
    ///   ``maxAttempts``.
    /// - A failure nothing answered (no network, a refused connect, no response in time) spends none:
    ///   the link is down, not the host saying no. Those go on while the next attempt can start inside
    ///   ``linkWindow``, measured from when the link went quiet: the start of the first attempt nothing
    ///   answered, or the last byte of a body that fell silent. A retry does not move that start; only
    ///   a response does. Each attempt's wait is cut at the window's end
    ///   (``linkWindowLeft(now:)``), so a dead link fails about ``linkWindow`` after it went quiet.
    /// - Each failure in a row doubles the backoff, from ``firstBackoffSeconds`` up to
    ///   ``maxBackoffSeconds``.
    /// - Progress (the frontier passing the decoder's position), or a restart no failure caused,
    ///   ``reset()``s the lot.
    struct Retry: Equatable, Sendable {

        /// Failures the host answered, in a row without progress, before the read fails.
        static let maxAttempts = 3
        /// How long a link that answers nothing is retried before the read fails: long enough for
        /// airplane mode, a lift or a tunnel, short enough that a dead network becomes an error.
        static let linkWindowSeconds: Double = 30
        static let firstBackoffSeconds: Double = 0.1
        /// The backoff doubles up to this, so a long outage is asked about every couple of seconds
        /// and the first request after it comes back goes out soon after.
        static let maxBackoffSeconds: Double = 2

        enum Decision: Equatable, Sendable {
            /// Ask again after this many seconds: resume the file from its frontier, or restart at the
            /// decoder's position when the file does not hold it.
            case retry(after: TimeInterval)
            /// The read fails at the frontier.
            case fail
        }

        let linkWindow: TimeInterval
        /// Answered failures spent; see ``maxAttempts``.
        private(set) var attempts = 0
        /// Failures in a row, answered or not: what the backoff grows with.
        private(set) var failuresInRow = 0
        /// When the link went quiet: the first quiet failure's `quietSince` since the last response.
        private(set) var linkDownSince: TimeInterval?

        init(linkWindow: TimeInterval = Retry.linkWindowSeconds) {
            self.linkWindow = linkWindow
        }

        /// A transaction failed at `now`. `retryable` false (a full disk, a page where audio should
        /// be) fails at once and spends nothing.
        /// - Parameter quietSince: when the link last said anything to this attempt, if it went quiet
        ///   rather than answering with a refusal or a close: the attempt's start when nothing answered
        ///   it (`now` when not given), the last byte when its body fell silent. The first one since the
        ///   last response starts the link window.
        mutating func failed(answered: Bool, retryable: Bool, quietSince: TimeInterval? = nil, now: TimeInterval) -> Decision {
            if linkDownSince == nil, let since = quietSince ?? (answered ? nil : now) { linkDownSince = since }
            let backoff = min(Self.firstBackoffSeconds * pow(2.0, Double(failuresInRow)), Self.maxBackoffSeconds)
            let left = answered
                ? attempts < Self.maxAttempts
                : now + backoff - (linkDownSince ?? now) < linkWindow
            guard retryable, left else { return .fail }
            if answered { attempts += 1 }
            failuresInRow += 1
            return .retry(after: backoff)
        }

        /// How long an attempt starting at `now` may wait for its response before the link window
        /// ends; nil while the link is up.
        func linkWindowLeft(now: TimeInterval) -> TimeInterval? {
            linkDownSince.map { max(0, $0 + linkWindow - now) }
        }

        /// A response arrived: the link is up, whatever the host said.
        mutating func linkAnswered() {
            linkDownSince = nil
        }

        /// A fresh budget.
        mutating func reset() {
            self = Retry(linkWindow: linkWindow)
        }
    }
}
