import Foundation
import OSLog
import PlaybackDecode

private let downloadLog = Logger(subsystem: "com.simplecityapps.AudioPlaybackKit", category: "download")

/// **The growing-file source's transaction lifecycle, as one state machine**: ADR-0004's single
/// recovery layer as one module.
///
/// Events go in: the decoder's reads and seeks, a response, body bytes, a task's end, a timer the
/// machine asked for, a new network path. ``Effect``s come out, for the adapter
/// (``GrowingFileByteSource``) to carry out in order: open a file, send a request, cancel a task,
/// schedule a timer, wake a parked read, hand an event out. A read gets a ``ReadStep``: serve from
/// the file, park, end, or fail. Every rule of the source lives here: the read rule (``ReadRule``),
/// the retry budget (``Retry``), resume or restart, the read-ahead pause, the redirect chain's
/// remembered end, the seek generation a transaction carries, the measured rate.
///
/// No lock, task, file or clock: times come in with each event, and every transition is driven by
/// a test with literal numbers. The adapter holds the one lock around every call.
struct GrowingFileDownload {

    // MARK: - State

    /// How far behind the reader a range of a resource with no known total is kept (ADR-0014): an
    /// hour at 128 kbps, under the store's free-space headroom.
    static let unknownLengthWindowBytes: Int64 = 64 << 20

    let url: URL
    private(set) var current: Transaction?
    private(set) var file: SessionFile
    /// The decoder's read position.
    private(set) var offset: Int64 = 0
    private(set) var generation = 0
    /// Reads that have parked at the frontier so far.
    private(set) var parks = 0
    /// When the current read first parked; cleared by ``endRead()`` when the read returns or throws,
    /// so a wake that re-parks (a retry, a restart) keeps the original time.
    private(set) var readWaitingSince: TimeInterval?
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
    private var pendingOpen: (base: Int64, end: Int64?, seekGeneration: Int?, retrying: Bool)?
    /// The last read step opened a transaction because there was none; if it is still missing the
    /// read fails instead of asking again.
    private var readOpened = false
    private var effects: [Effect] = []
    /// How far the frontier may run ahead of the decoder while the path is expensive; nil is no cap.
    let readAhead: Int64?
    /// The network path is expensive or constrained: the read-ahead cap applies.
    private(set) var pathIsExpensive = false

    init(url: URL, readAhead: Int64? = nil, unknownLengthWindow: Int64 = Self.unknownLengthWindowBytes) {
        self.url = url
        self.readAhead = readAhead
        self.file = SessionFile(unknownLengthWindow: unknownLengthWindow)
    }

    // MARK: - Published state

    var totalLength: Int64? { current?.totalLength ?? lastKnownTotalLength }

    /// `base`/`frontier` are the covered run the reader is in, else the current transaction's (ADR-0014).
    mutating func snapshot(fileURL: URL?, now: TimeInterval) -> GrowingFileSnapshot {
        let run = file.ranges.run(containing: offset)
        // A transaction whose file is gone has nothing readable.
        let tx = file.exists ? current : nil
        return GrowingFileSnapshot(
            base: run?.lowerBound ?? tx?.base ?? offset,
            frontier: run?.upperBound ?? tx?.frontier ?? offset,
            totalLength: totalLength,
            // Nothing up to the end is owed to the reader, whichever transactions wrote it.
            isComplete: totalLength.map { (run?.upperBound ?? offset) >= $0 } ?? false,
            fileURL: fileURL,
            transactionGeneration: generation,
            seekGeneration: current?.seekGeneration,
            downloadBytesPerSecond: downloadBytesPerSecond(now: now),
            readWaitingSince: readWaitingSince
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
        // Past a known total nothing can arrive (an estimated transcode length may overpromise);
        // the total itself is end of stream.
        if let total = totalLength, newOffset > total { throw StreamByteReaderError.unseekable }
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
        for range in file.dropBehind(offset, totalLength: totalLength) { effects.append(.punchHole(range)) }
        let run = file.ranges.run(containing: offset)
        guard current != nil || run != nil else {
            if opened { return step(.fail(.transport(failure ?? "no transaction"))) }
            if let reason = stickyFailure { return step(.fail(.transport(reason))) }
            start(at: offset, seekGeneration: claimSeek())
            readOpened = true
            return step(.again)
        }
        let tx = current
        // A failure that deleted the file (a page, a full disk) took its frontier with it, so the
        // decoder's next read is no seek ahead: it gets the failure, unless the total length says
        // nothing is owed there (ADR-0004: the layer fails what it still owes, not a finished stream).
        if let tx, let reason = failure, !file.exists, tx.totalLength.map({ offset < $0 }) ?? true {
            return reportFailure(reason)
        }
        // Only a transaction that will bring bytes up to the read is waited for.
        let frontier = tx.flatMap { tx in
            !tx.isComplete && offset >= tx.frontier && offset < (tx.end ?? .max) ? tx.frontier : nil
        }
        let action = ReadRule.action(
            position: offset, isCovered: run != nil, frontier: frontier, totalLength: tx?.totalLength,
            isProbing: isProbing, rangeIgnored: rangeIgnored,
            downloadBytesPerSecond: tx?.rateAtPause ?? downloadBytesPerSecond(now: now),
            responseLatency: responseLatency
        )
        if let tx, tx.paused, action == .serve || action == .wait, let readAhead,
           offset >= tx.base, tx.frontier - offset <= readAhead / 2 {
            resume(now: now)
        }
        switch action {
        case .serve:
            let count = Int(min(Int64(maxLength), (run?.upperBound ?? offset) - offset))
            return step(.serve(fileOffset: offset, count: count, landed: landSeek()))
        case .endOfStream:
            return step(.endOfStream(landed: landSeek()))
        case .restart:
            retry.reset()
            start(at: offset, seekGeneration: claimSeek())
            return step(.again)
        case .wait:
            if let reason = failure { return reportFailure(reason) }
            parks += 1
            readWaitingSince = readWaitingSince ?? now
            if !recheckPending {
                recheckPending = true
                effects.append(.schedule(.recheck, after: GrowingFileByteSource.recheckSeconds))
            }
            return step(.park)
        }
    }

    /// The read that was parked has been served, ended or failed.
    mutating func endRead() {
        readWaitingSince = nil
    }

    /// The failed transaction goes with the error. The error stays until a seek (Play once the
    /// player shows it seeks to where it stopped), whose read opens a fresh one there with a fresh
    /// budget; the total length stays known.
    private mutating func reportFailure(_ reason: String) -> ReadStep {
        // The file's bytes stay for a seek to read; a file with none is not kept.
        retireCurrent(discardingFile: file.ranges.ranges.isEmpty)
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
        }
        // The session's file goes with it even when no transaction is left.
        retireCurrent(discardingFile: true)
        effects.append(.wake)
        return takeEffects()
    }

    /// The complete file leaves the cache: whether there was one, which the adapter deletes.
    mutating func dropCachedFile() -> Bool {
        guard file.isCached, file.exists else { return false }
        file.deleted()
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
        file.exists = true
        generation += 1
        transactionsOpened += 1
        current = Transaction(
            id: transactionsOpened, generation: generation, seekGeneration: open.seekGeneration,
            remembered: finalURL != nil, base: open.base, end: open.end
        )
        if startup.requestIssuedAt == nil { startup.requestIssuedAt = now }
        send(from: open.base, ifRange: nil, retrying: open.retrying, now: now)
        let opened = generation, host = url.host ?? "?"
        downloadLog.info("download: open gen=\(opened) base=\(open.base) host=\(host, privacy: .public)")
        return takeEffects() + [.wake]
    }

    /// Promotes the file once `[0, total)` is on disk, whichever transactions wrote it (ADR-0014).
    /// A body with more to send then (the whole file answering a bounded request) could only
    /// rewrite bytes already there, so it ends.
    private mutating func promoteIfWhole() {
        guard file.isWhole(totalLength: totalLength) else { return }
        effects.append(.promote)
        guard let tx = current, !tx.ended, tx.frontier < min(tx.end ?? .max, tx.totalLength ?? .max) else { return }
        current?.ended = true
        current?.isComplete = true
        effects.append(.cancelTask)
    }

    /// The complete file is the cache's now.
    mutating func promoted() {
        file.isCached = true
        if let tx = current { downloadLog.info("download: cached gen=\(tx.generation)") }
    }

    /// A hop of the redirect chain, before the first accepted response.
    mutating func redirected(toHost host: String?) {
        if startup.firstResponseAt == nil, let host { startup.hosts.append(host) }
    }

    /// Retires the current transaction and asks for one at the first hole from `start`, up to the
    /// next covered range (ADR-0014; media3's `CacheDataSource` bounds a network read the same way),
    /// or for the whole body once the host ignores ranges.
    /// - Parameters:
    ///   - seekGeneration: the seek this transaction answers, nil when none asked for it.
    ///   - retrying: a retry's restart, whose request waits the shorter time (``target(retrying:)``).
    ///   - discardingFile: the session's file is not this resource's any more.
    private mutating func start(at start: Int64, seekGeneration: Int?, retrying: Bool = false, discardingFile: Bool = false) {
        if current != nil { retireCurrent(discardingFile: discardingFile) }
        current = nil
        failure = nil
        let from = rangeIgnored ? 0 : file.ranges.firstHole(atOrAfter: start)
        let end = rangeIgnored ? nil : file.ranges.nextCoveredStart(after: from)
        pendingOpen = (from, end, seekGeneration, retrying)
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

    /// Cancels the task; its bytes stay in the session's file. `discardingFile` deletes the file too,
    /// unless it is the cache's now.
    private mutating func retireCurrent(discardingFile: Bool = false) {
        current?.ended = true
        let discard = discardingFile && file.exists && !file.isCached
        if discard { file.deleted() }
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
            if !retryable { retireCurrent(discardingFile: true) }
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
        let resumable = !rangeIgnored && file.exists && !file.isCached && !tx.sniffPending
            && tx.written > 0 && offset >= tx.base && offset <= tx.frontier && tx.end.map { tx.frontier < $0 } ?? true
        guard resumable else {
            start(at: offset, seekGeneration: nil, retrying: true)
            return
        }
        resume(now: now)
    }

    /// Asks for the current transaction's file from its frontier on, with `If-Range`, in the same
    /// transaction: a retry's resume, or the end of a read-ahead pause. A fresh attempt with the
    /// retry's short wait; nothing answering it starts the link window from when it went out.
    private mutating func resume(now: TimeInterval) {
        guard let tx = current else { return }
        let from = tx.frontier
        current?.ended = false
        current?.paused = false
        current?.answered = false
        current?.resumeAt = from
        current?.remembered = finalURL != nil
        send(from: from, ifRange: tx.entityTag, retrying: true, now: now)
        let decoder = offset
        downloadLog.info("download: resume gen=\(tx.generation) at=\(from) decoder=\(decoder)")
    }

    /// The read-ahead cap applies to `tx`: a cap was given, the path costs, and the host answered
    /// its range with a `206`, so a resume is not answered from byte 0. A host that ignores ranges
    /// (a `200`, even to `bytes=0-`) downloads whole.
    private func isCapped(_ tx: Transaction) -> Bool {
        readAhead != nil && pathIsExpensive && !rangeIgnored && tx.rangeHonoured
    }

    /// Cancels the request once the frontier is the read-ahead ahead of the decoder. No failure:
    /// nothing is spent and no timer starts; the file stays, and a read resumes it (``read(maxLength:now:)``).
    private mutating func pauseIfFarAhead(now: TimeInterval) {
        guard let readAhead, let tx = current, isCapped(tx), !tx.ended else { return }
        guard tx.frontier - offset >= readAhead, tx.frontier < min(tx.totalLength ?? .max, tx.end ?? .max) else { return }
        current?.ended = true
        current?.paused = true
        let rate = downloadBytesPerSecond(now: now)
        current?.rateAtPause = rate
        effects.append(.cancelTask)
        let decoder = offset
        downloadLog.info("download: pause gen=\(tx.generation) at=\(tx.frontier) decoder=\(decoder)")
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
        effects.append(.send(Request(attempt: attemptsSent, url: target.url, from: from, end: current?.end, ifRange: ifRange)))
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
            // before the response arrives: that wait is the response timer's, nor once every byte
            // is in and only the completion is on the way.
            guard current?.id == id else { break }
            current?.idleCheckPending = false
            guard !cancelled, let tx = current, tx.answered, !tx.ended, !tx.isComplete,
                  tx.frontier < min(tx.totalLength ?? .max, tx.end ?? .max) else { break }
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
        guard !cancelled, let tx = current, !tx.ended, !tx.isComplete,
              tx.frontier < min(tx.totalLength ?? .max, tx.end ?? .max) else { return [] }
        end("path_changed at=\(tx.frontier)", retryable: true, pathChanged: true, now: now)
        return takeEffects()
    }

    /// The path's cost, on every path the monitor reports. A paused transaction resumes at once
    /// on a path that no longer costs; one that costs pauses at its next chunk.
    mutating func pathCost(isExpensive: Bool, now: TimeInterval) -> [Effect] {
        pathIsExpensive = isExpensive
        if !cancelled, let tx = current, tx.paused, !isCapped(tx) { resume(now: now) }
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
            promoteIfWhole()
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
                // Bytes these can no longer be checked against are not kept.
                if finalURL == nil { finalURL = response.url }
                start(at: offset, seekGeneration: nil, retrying: true, discardingFile: true)
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
            current?.end = nil
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
            current?.rangeHonoured = true
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
        // A bounded request's length ends at its bound, not the resource's end.
        let total = range?.total
            ?? (response.expectedContentLength > 0 && accepted.end == nil ? response.expectedContentLength + accepted.base : nil)
        let strongTag = response.entityTag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let changedTotal = total != nil && lastKnownTotalLength != nil && total != lastKnownTotalLength
        let changedTag = strongTag != nil && file.entityTag != nil && strongTag != file.entityTag
        if !file.ranges.ranges.isEmpty, changedTotal || changedTag {
            // The resource changed behind the URL: none of the file's bytes are its.
            downloadLog.warning("download: resource_changed gen=\(accepted.generation) total=\(total ?? -1)")
            start(at: offset, seekGeneration: accepted.seekGeneration, retrying: true, discardingFile: true)
            return false
        }
        current?.totalLength = total
        // A response that gives no total says nothing against the one already known.
        if let total { lastKnownTotalLength = total }
        if let total { effects.append(.makeRoom(bytes: total - accepted.base)) }
        current?.entityTag = strongTag
        file.entityTag = file.entityTag ?? strongTag
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
        return tx.base + tx.written
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
        current?.rateAtPause = nil
        if tx.sniffPending, tx.written + Int64(count) >= Int64(GrowingFileByteSource.sniffBytes) {
            guard let bytes = head(), Self.isMedia(mimeType: nil, head: bytes) == true else {
                end("not audio: body sniff", retryable: tx.remembered, refused: true, now: now)
                return takeEffects()
            }
            current?.sniffPending = false
        }
        // Only the bytes this chunk made readable: a range dropped from the set is never re-added.
        if let frontier = current?.frontier { file.record(tx.frontier..<frontier) }
        promoteIfWhole()
        // Progress is the decoder's: a host that drops before the read position (a 200 from
        // byte 0, every time) spends its retries instead of looping.
        if let frontier = current?.frontier, frontier > offset { retry.reset() }
        if firstSampleAt == nil { firstSampleAt = now }
        samples.append((now, count))
        if now - lastDownloadEventAt >= GrowingFileByteSource.downloadEventSeconds, let frontier = current?.frontier {
            lastDownloadEventAt = now
            effects.append(.emit(.download(frontier: frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: false)))
        }
        pauseIfFarAhead(now: now)
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
        let expectedEnd = min(tx.end ?? .max, tx.totalLength ?? .max)
        if expectedEnd < .max, tx.frontier < expectedEnd {
            end("short body ended=\(tx.frontier) expected=\(expectedEnd)", retryable: true, now: now)
            return takeEffects()
        }
        current?.ended = true
        current?.isComplete = true
        // A bounded body ends at its bound, which says nothing of the resource's end.
        let total = tx.totalLength ?? (tx.end == nil ? tx.frontier : nil)
        current?.totalLength = total
        if let total { lastKnownTotalLength = total }
        promoteIfWhole()
        downloadLog.info("download: complete gen=\(tx.generation) base=\(tx.base) frontier=\(tx.frontier)")
        let complete = total.map { tx.frontier >= $0 } ?? false
        effects.append(.emit(.download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: complete)))
        effects.append(.wake)
        return takeEffects()
    }
}
