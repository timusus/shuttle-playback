import Foundation
import OSLog
import PlaybackDecode

private let downloadLog = Logger(subsystem: "com.simplecityapps.shuttle-playback", category: "download")

/// **One download per transaction, to one file; the decoder reads the file and waits at the
/// frontier**. Unthrottled, no window, no run cache, no redirect cache.
///
/// - A transaction is `GET` with `Range: bytes=<base>-` and the caller's auth headers (on every hop
///   too). Each body chunk is written at its file offset and the frontier advances. A `200` to a
///   ranged request re-declares the file as starting at byte 0, under a new generation, and the
///   read waits for its position. A body from byte 0 that completes is renamed into
///   ``GrowingFileStore``'s cache.
/// - A dropped connection, a silent body or a refused status is tried again after the backoff
///   ``DownloadRetry`` decides, until it says the read fails with `.transport`: a few attempts for
///   failures the host answered, the link window for ones nothing answered. A request
///   nothing answers in time (``requestTimeoutSeconds`` for a transaction's first, the shorter
///   ``retryRequestTimeoutSeconds`` for a retry, neither past the link window's end) is ended as
///   one nothing answered, so a dead link fails about 30 s after it went quiet. A retry whose
///   file holds the decoder's position resumes it: `Range: bytes=<frontier>-` (with `If-Range`
///   when the host gave a strong ETag), appended to the same file under the same generation, so
///   nothing already on disk is fetched again. A resume the host answers with anything but a `206`
///   from the frontier with the same total (a `200`, or a body the server has changed between requests) is dropped for a restart at the
///   decoder's position into a new file, as is a retry whose file does not hold that position.
///   Retries and resumes go straight to the redirect chain's remembered end, so a slow chain is
///   not walked again inside a retry's short wait. A request there that is refused (a `4xx`, a
///   page) or unanswered forgets it, a signed hop may have expired, and the next request walks the
///   chain from the requested URL once with the generous wait (``chainEndForgotten``).
/// - A new network path (``GrowingFilePathMonitor``) ends a transaction still on the network at
///   once, as a drop the retry above decides on, instead of leaving it to the idle timeout.
/// - A transaction whose answer says the resource ends exactly at its base (`416` with
///   `bytes */N`, or a range clamped to the last byte) is a zero-length open, as in media3: the
///   length is learned and the read is at its end (``totalEndingAt(_:status:contentRange:)``).
/// - ``snapshot`` is the only read surface for anyone but the decoder; ``GrowingFileEvent``s
///   go to `onEvent`, on the session's delegate queue or the decoder's thread.
///
/// Threading: the decoder's thread calls the ``StreamByteReader`` methods, and they block; the
/// session's serial delegate queue writes. Both meet under `condition`. File I/O runs outside it,
/// each side holding the ``Transaction`` it works on, which owns the descriptor: a restart can
/// retire a transaction mid-`pread` and its descriptor stays open until the read lets go. Time
/// (the backoff, the link window, the throughput window, the recheck, the body's idle check) is the
/// ``GrowingFileClock``'s.
///
/// **``cancel()`` must be called**: a running task retains its delegate, this object.
public final class GrowingFileByteSource: NSObject, StreamByteReader, GrowingFileSnapshotSource, URLSessionDataDelegate {

    /// The window, in seconds, over which ``GrowingFileSnapshot/downloadBytesPerSecond`` is
    /// averaged. A constant consumers may read.
    public static let throughputWindowSeconds: Double = 2
    static let downloadEventSeconds: Double = 1
    /// A parked read also looks again after this many seconds. Load-bearing: the download rate decays while
    /// no bytes arrive and nothing broadcasts that, so a wait for a gap ahead of the frontier only
    /// becomes the restart the read rule then asks for when the read looks again. A constant
    /// consumers may read.
    public static let recheckSeconds: Double = 1
    /// How many of a body's first bytes the media sniff needs.
    static let sniffBytes = 12
    /// How long a body may go without a byte, once its response has arrived, before the source
    /// ends the transaction itself (``scheduleIdleCheckLocked(_:)``, on the clock). A connection
    /// that falls silent (a dead Wi-Fi, a host that stops sending without closing) is then an
    /// ordinary failure that ``DownloadRetry`` decides on. This is the player's only network
    /// recovery; with URLSession's default 60 s a silent link held the read that long. A constant
    /// consumers may read, in seconds.
    public static let idleTimeoutSeconds: TimeInterval = 6
    /// How long a transaction's first request waits for its response, on the clock
    /// (``sendLocked(_:for:timeout:)``); also the session's `timeoutIntervalForRequest`, a backstop
    /// restarted on every redirect hop. Generous, so a cold origin or a long chain of
    /// redirects (5.3 s to the first byte on a real host) is waited for rather than failed; the
    /// body's silence is ``idleTimeoutSeconds``'s alone.
    static let requestTimeoutSeconds: TimeInterval = 20
    /// How long a retry or resume waits for its response. Short: the host was just talking to
    /// this source or the link just went quiet, the request goes to the chain's remembered end
    /// rather than through the chain, and each wait the link window must cover is one of these, so
    /// a dead link fails about ``DownloadRetry/linkWindowSeconds`` after it went quiet instead of
    /// after three ``requestTimeoutSeconds``. The one retry that walks the chain again after its
    /// end was refused or unanswered waits ``requestTimeoutSeconds``, within the window.
    static let retryRequestTimeoutSeconds: TimeInterval = 8

    /// One process-wide session, so a host's connection stays warm between plays and restarts.
    public static let sharedSession = makeSession(configuration: .default)

    /// No URL cache: a host may change its media body behind the same headers. Delegates are per task.
    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)
    }

    /// One transaction's file and task. Mutable state is behind the source's `condition`.
    private final class Transaction {
        var generation: Int
        var seekGeneration: Int?
        let descriptor: Int32
        /// Nil once the partial is deleted: nothing of it is readable any more.
        var fileURL: URL?
        /// The current request went to the redirect chain's remembered end, not the requested URL.
        var remembered: Bool
        var task: URLSessionDataTask?
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
        /// The clock's time the current request went out.
        var attemptStartedAt: TimeInterval = 0
        /// Done with the network: complete, failed, or handed to a retry.
        var ended = false
        var isComplete = false
        var isCached = false
        /// The clock's time of the response or the last body chunk, whichever came later.
        var lastByteAt: TimeInterval = 0
        /// An idle check is on the clock; one at a time.
        var idleCheckPending = false
        var frontier: Int64 { base + (sniffPending || fileURL == nil ? 0 : written) }

        init(generation: Int, seekGeneration: Int?, descriptor: Int32, fileURL: URL, remembered: Bool, base: Int64) {
            self.generation = generation
            self.seekGeneration = seekGeneration
            self.descriptor = descriptor
            self.fileURL = fileURL
            self.remembered = remembered
            self.base = base
        }

        deinit { Foundation.close(descriptor) }
    }

    private let url: URL
    /// What the completed-file cache knows this resource by: `url` unless the host gave a key.
    private let cacheKey: URL
    private let authHeaders: [String: String]
    private let policy: GrowingFileConnectionPolicy?
    private let store: GrowingFileStore
    private let session: URLSession
    private let onEvent: ((GrowingFileEvent) -> Void)?
    private let clock: GrowingFileClock
    private let pathMonitor: GrowingFilePathMonitor
    /// This source's observation of `pathMonitor`, nil once removed.
    private var pathObserver: Int?

    // Behind `condition`.
    private let condition = NSCondition()
    private var current: Transaction?
    private var offset: Int64 = 0
    private var generation = 0
    private var parks = 0
    /// A seek announced by ``willSeek(generation:)`` that no read has answered yet. The read that
    /// answers it claims it, once: it opens the transaction that carries it, or finds its bytes
    /// already in the file and reports ``GrowingFileEvent/seekLanded(seekGeneration:)``. `sought`
    /// says the decoder moved the read position for it; one it answered from its own buffer never
    /// did, and the read after it is no seek's, so it tags nothing.
    private var unclaimedSeek: (generation: Int, sought: Bool)?
    private var retry: DownloadRetry
    /// A parked read's recheck is on the clock; one at a time however often the read wakes.
    private var recheckPending = false
    /// Why the current transaction cannot deliver more; a read at its frontier throws it.
    private var failure: String?
    /// The failure a read threw, until the next ``seek(to:)`` or ``willSeek(generation:)``: a read
    /// after the throw throws it again instead of opening a transaction nobody asked for.
    private var stickyFailure: String?
    /// The resource's length as the last accepted response gave it: what ``totalLength`` and the
    /// ``snapshot`` answer once a failed read has dropped the transaction that knew it.
    private var lastKnownTotalLength: Int64?
    private var cancelled = false
    private var interrupted = false
    private var probing = false
    private var rangeIgnored = false
    /// The end of the redirect chain, from the first response; later requests go straight there
    /// until one there is refused or unanswered.
    private var finalURL: URL?
    /// The chain's end was just forgotten: the next request walks the chain from `url` with the
    /// generous wait, even as a retry. Once; the request it goes with clears it.
    private var chainEndForgotten = false
    private var startupValue = Startup()
    private var samples: [(at: TimeInterval, bytes: Int)] = []
    private var firstSampleAt: TimeInterval?
    private var lastDownloadEventAt: TimeInterval = -.infinity

    /// - Parameters:
    ///   - authHeaders: resolved by the caller before construction; values are never logged.
    ///   - cacheKey: names the resource in the store's completed-file cache, for a `url` that carries a
    ///     token or session id which changes between plays. Pass the URL without them, and ask the
    ///     store for `completedFile(for:)` with the same key. The requests still go to `url`. Nil
    ///     (the default) keys the cache by `url`.
    ///   - connectionPolicy: extra headers and the leaf certificates the user trusted for `url`'s origin; nil
    ///     (the default) is the system's trust and no extra headers. Like `authHeaders`, its headers
    ///     are sent only to that origin, never to another one a redirect lands on.
    ///   - onEvent: the `transaction`/`download` events.
    public convenience init(
        url: URL,
        authHeaders: [String: String],
        cacheKey: URL? = nil,
        connectionPolicy: GrowingFileConnectionPolicy? = nil,
        store: GrowingFileStore = .shared,
        session: URLSession = GrowingFileByteSource.sharedSession,
        onEvent: ((GrowingFileEvent) -> Void)? = nil
    ) {
        self.init(
            url: url, authHeaders: authHeaders, cacheKey: cacheKey, connectionPolicy: connectionPolicy,
            store: store, session: session, clock: SystemGrowingFileClock.shared, onEvent: onEvent
        )
    }

    /// - Parameters:
    ///   - clock: a test's steps through backoffs and windows; the system's otherwise.
    ///   - pathMonitor: a test's path changes; the shared `NWPathMonitor`'s otherwise.
    init(
        url: URL,
        authHeaders: [String: String],
        cacheKey: URL? = nil,
        connectionPolicy: GrowingFileConnectionPolicy? = nil,
        store: GrowingFileStore = .shared,
        session: URLSession = GrowingFileByteSource.sharedSession,
        clock: GrowingFileClock,
        pathMonitor: GrowingFilePathMonitor = .shared,
        onEvent: ((GrowingFileEvent) -> Void)? = nil
    ) {
        self.url = url
        self.cacheKey = cacheKey ?? url
        self.authHeaders = authHeaders
        self.policy = connectionPolicy
        self.store = store
        self.session = session
        self.clock = clock
        self.pathMonitor = pathMonitor
        self.retry = DownloadRetry()
        self.onEvent = onEvent
        super.init()
        let observer = pathMonitor.addObserver { [weak self] in self?.networkPathChanged() }
        locked { pathObserver = observer }
    }

    // MARK: - Published state

    public var snapshot: GrowingFileSnapshot {
        locked {
            GrowingFileSnapshot(
                base: current?.base ?? offset,
                frontier: current?.frontier ?? offset,
                totalLength: current?.totalLength ?? lastKnownTotalLength,
                isComplete: current?.isComplete ?? false,
                fileURL: current?.fileURL,
                transactionGeneration: generation,
                seekGeneration: current?.seekGeneration,
                downloadBytesPerSecond: downloadBytesPerSecondLocked()
            )
        }
    }

    /// Set around the decoder's `open()`; see ``GrowingFileReadRule/action(position:base:frontier:totalLength:isComplete:isProbing:rangeIgnored:downloadBytesPerSecond:)``.
    public var isProbing: Bool {
        get { locked { probing } }
        set { locked { probing = newValue } }
    }

    /// The player's seek of `generation` is about to be issued. The transaction the decoder's next
    /// read opens carries it; a read the current file answers reports it landed instead. No other
    /// transaction (the probe's, a retry's, the one after a failed read) carries a seek generation.
    /// Nil is a seek that anchors nothing: it only drops a claim no read has taken.
    public func willSeek(generation: Int?) {
        locked {
            unclaimedSeek = generation.map { ($0, false) }
            stickyFailure = nil
        }
    }

    /// Reads that have parked at the frontier so far: what a test waits on instead of a clock.
    var parkCount: Int { locked { parks } }

    /// What the first accepted response cost, for the start timing. Times are the clock's:
    /// `systemUptime` seconds outside a test.
    public struct Startup: Equatable {
        /// The first transaction's `resume()`.
        public var requestIssuedAt: TimeInterval?
        /// The first accepted response; nil until there is one.
        public var firstResponseAt: TimeInterval?
        public var status: Int?
        /// Each redirect hop's destination host before the first accepted response.
        public var hosts: [String] = []
        /// The first accepted response came from a chain end remembered within this source.
        public var remembered = false
    }

    public var startup: Startup { locked { startupValue } }

    // MARK: - StreamByteReader

    /// The current transaction's, nil until its response. Known before `AVSEEK_SIZE` is first
    /// asked: the decoder's first call is a read (`probe_id3_offset`), which waits for a byte.
    public var totalLength: Int64? { locked { current?.totalLength ?? lastKnownTotalLength } }

    public var position: Int64 { locked { offset } }

    public func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        guard maxLength > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { throw StreamByteReaderError.cancelled }
            if interrupted { throw StreamByteReaderError.interrupted }
            guard let tx = current else {
                if let reason = stickyFailure { throw StreamByteReaderError.transport(reason) }
                startLocked(at: offset, seekGeneration: claimSeekLocked())
                if current == nil { throw StreamByteReaderError.transport(failure ?? "no transaction") }
                continue
            }
            let action = GrowingFileReadRule.action(
                position: offset, base: tx.base, frontier: tx.frontier, totalLength: tx.totalLength,
                isComplete: tx.isComplete, isProbing: probing, rangeIgnored: rangeIgnored,
                downloadBytesPerSecond: downloadBytesPerSecondLocked()
            )
            switch action {
            case .serve:
                let count = Int(min(Int64(maxLength), tx.frontier - offset))
                let fileOffset = off_t(offset - tx.base)
                let landed = landSeekLocked()
                condition.unlock()
                if let landed { onEvent?(.seekLanded(seekGeneration: landed)) }
                var got: Int
                repeat { got = pread(tx.descriptor, buffer, count, fileOffset) } while got < 0 && errno == EINTR
                condition.lock()
                guard got > 0 else { throw StreamByteReaderError.transport("pread failed at \(fileOffset)") }
                offset += Int64(got)
                return got
            case .endOfStream:
                if let landed = landSeekLocked() {
                    condition.unlock()
                    onEvent?(.seekLanded(seekGeneration: landed))
                    condition.lock()
                }
                return 0
            case .restart:
                resetRetriesLocked()
                startLocked(at: offset, seekGeneration: claimSeekLocked())
            case .wait:
                if let reason = failure {
                    // The failed transaction goes with the error. The error stays until a seek
                    // (Play once the player shows it seeks to where it stopped), whose read opens
                    // a fresh one there with a fresh budget; the total length stays known.
                    retireLocked(tx)
                    current = nil
                    failure = nil
                    stickyFailure = reason
                    resetRetriesLocked()
                    throw StreamByteReaderError.transport(reason)
                }
                parks += 1
                scheduleRecheckLocked()
                condition.wait()
            }
        }
    }

    public func seek(to newOffset: Int64) throws {
        try locked {
            if cancelled { throw StreamByteReaderError.cancelled }
            if interrupted { throw StreamByteReaderError.interrupted }
            guard newOffset >= 0 else { throw StreamByteReaderError.unseekable }
            offset = newOffset
            unclaimedSeek?.sought = true
            stickyFailure = nil
        }
    }

    /// Ends the download and deletes the partial (a cached complete file stays): a new load or
    /// stop. Logs what was fetched and never read, the cost of whole-file fetches.
    public func cancel() {
        let observer: Int? = locked {
            defer { pathObserver = nil }
            return pathObserver
        }
        if let observer { pathMonitor.removeObserver(observer) }
        locked {
            guard !cancelled else { return }
            cancelled = true
            if let tx = current {
                let wasted = max(0, tx.frontier - max(offset, tx.base))
                let share = tx.totalLength.map { $0 > 0 ? Double(wasted) / Double($0) : 0 } ?? 0
                downloadLog.info("download: cancel bytes_wasted=\(wasted) share=\(share, format: .fixed(precision: 3))")
                retireLocked(tx)
            }
            condition.broadcast()
        }
    }

    /// ``cancel()`` after a load whose bytes the decoder could not open: the complete file the
    /// download may already have finished into leaves the cache too, so the next play fetches
    /// again instead of failing on the same file.
    public func cancelDiscardingCache() {
        cancel()
        locked {
            guard let tx = current, tx.isCached, let file = tx.fileURL else { return }
            store.discard(file)
            tx.fileURL = nil
            tx.isCached = false
        }
    }

    /// A backstop for a creator that never cancelled. Only reached once no task holds the source
    /// as its delegate, so what is left is the file.
    deinit {
        if let pathObserver { pathMonitor.removeObserver(pathObserver) }
        if let tx = current, !tx.isCached, let file = tx.fileURL { store.discard(file) }
    }

    public func interrupt() {
        locked {
            interrupted = true
            condition.broadcast()
        }
    }

    public func clearInterrupt() {
        locked { interrupted = false }
    }

    // MARK: - Transactions (all under `condition`)

    /// Retires the current transaction and opens one at `start` (0 once the host ignores ranges).
    /// When no file can be opened, `current` stays nil and `failure` says why.
    /// - Parameters:
    ///   - seekGeneration: the seek this transaction answers, nil when none asked for it.
    ///   - retrying: a retry's restart, whose request waits the shorter time (``targetLocked(retrying:)``).
    private func startLocked(at start: Int64, seekGeneration: Int?, retrying: Bool = false) {
        defer { condition.broadcast() }
        if let old = current { retireLocked(old) }
        current = nil
        failure = nil
        let base = rangeIgnored ? 0 : start
        let file = try? store.makePartial()
        let fd = file?.withUnsafeFileSystemRepresentation { $0.map { Foundation.open($0, O_RDWR) } ?? -1 } ?? -1
        guard let file, fd >= 0 else {
            if let file { store.discard(file) }
            failure = "cannot open a partial"
            return
        }
        generation += 1
        let tx = Transaction(
            generation: generation, seekGeneration: seekGeneration, descriptor: fd, fileURL: file,
            remembered: finalURL != nil, base: base
        )
        current = tx
        if startupValue.requestIssuedAt == nil { startupValue.requestIssuedAt = clock.now }
        let target = targetLocked(retrying: retrying)
        sendLocked(session.dataTask(with: request(for: target.url, from: base)), for: tx, timeout: target.timeout)
        downloadLog.info("download: open gen=\(tx.generation) base=\(base) host=\(self.url.host ?? "?", privacy: .public)")
    }

    /// The seek waiting for a read, taken by the read that answers it: its generation when the
    /// read is at the position that seek moved to, the tag for a transaction this read opens.
    private func claimSeekLocked() -> Int? {
        defer { unclaimedSeek = nil }
        guard let claim = unclaimedSeek, claim.sought else { return nil }
        return claim.generation
    }

    /// The seek waiting for a read, answered from the file: whether or not the decoder moved for
    /// it, no transaction will carry it.
    private func landSeekLocked() -> Int? {
        defer { unclaimedSeek = nil }
        return unclaimedSeek?.generation
    }

    /// Cancels the task and deletes the file unless it is the cache's now.
    private func retireLocked(_ tx: Transaction) {
        tx.ended = true
        tx.task?.cancel()
        if let file = tx.fileURL, !tx.isCached {
            store.discard(file)
            tx.fileURL = nil
        }
    }

    /// The transaction delivers no more. Retryable with retries left: after a backoff, a resume
    /// from the frontier or a restart at the decoder's position (``retryLocked(_:)``), the file
    /// still read until then. Otherwise the read reports
    /// `reason` at the frontier, and a failure no retry fixes (a page, a full disk) deletes the file.
    ///
    /// An outage the host never answered spends no attempt while the link window lasts: the read
    /// waits through it, which the player shows as buffering, instead of failing a second into it
    /// The window runs from when the link went quiet: `quietSince` when given (a silent
    /// body's last byte), else the start of the attempt nothing answered.
    ///
    /// `refused`: the host said no to this URL (a `4xx`, a page). That, or no answer at all, from
    /// the chain's remembered end forgets it: a signed hop may have expired. `pathChanged`: the
    /// source ended the request itself for a new network path, so no answer yet is not the end's.
    private func endLocked(
        _ tx: Transaction, _ reason: String, retryable: Bool, refused: Bool = false, pathChanged: Bool = false,
        quietSince: TimeInterval? = nil
    ) {
        tx.ended = true
        tx.task?.cancel()
        if tx.remembered, refused || (!tx.answered && !pathChanged), let end = finalURL {
            finalURL = nil
            // Without a chain there is nothing to walk again, so no longer wait for it either.
            chainEndForgotten = end != url
        }
        let decision = retry.failed(
            answered: tx.answered, retryable: retryable,
            quietSince: quietSince ?? (tx.answered ? nil : tx.attemptStartedAt), now: clock.now
        )
        guard case .retry(let backoff) = decision else {
            downloadLog.error("download: failed gen=\(tx.generation) \(reason, privacy: .public)")
            if !retryable { retireLocked(tx) }
            failure = reason
            condition.broadcast()
            return
        }
        downloadLog.error(
            "download: retry gen=\(tx.generation) attempt=\(self.retry.failuresInRow) answered=\(tx.answered) \(reason, privacy: .public)"
        )
        clock.schedule(after: backoff) { [weak self] in
            guard let self else { return }
            self.locked {
                guard !self.cancelled, self.current === tx else { return }
                self.retryLocked(tx)
            }
        }
    }

    /// The retry `endLocked` scheduled. A file that holds the decoder's position is resumed from
    /// its frontier, keeping every byte ahead of the decoder; anything else (nothing proven in it
    /// yet, a seek that left it, a host that ignores ranges) restarts at the decoder's position.
    /// Neither is the seek's: a restart carries no seek generation and claims none, and a resume
    /// keeps the one its transaction had.
    private func retryLocked(_ tx: Transaction) {
        let resumable = !rangeIgnored && tx.fileURL != nil && !tx.isCached && !tx.sniffPending
            && tx.written > 0 && offset >= tx.base && offset <= tx.frontier
        guard resumable else {
            startLocked(at: offset, seekGeneration: nil, retrying: true)
            return
        }
        let from = tx.frontier
        tx.ended = false
        tx.answered = false
        tx.resumeAt = from
        tx.remembered = finalURL != nil
        let target = targetLocked(retrying: true)
        var request = request(for: target.url, from: from)
        if let entityTag = tx.entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-Range") }
        sendLocked(session.dataTask(with: request), for: tx, timeout: target.timeout)
        downloadLog.info("download: resume gen=\(tx.generation) at=\(from) decoder=\(self.offset)")
    }

    /// Where the next request goes and how long it waits for its response: the chain's remembered
    /// end when there is one, else the requested URL. A retry waits ``retryRequestTimeoutSeconds``
    /// unless it walks the chain again because its end was just forgotten; that one, like a
    /// transaction's first request, waits ``requestTimeoutSeconds``. ``sendLocked(_:for:timeout:)``
    /// cuts either at the link window's end.
    private func targetLocked(retrying: Bool) -> (url: URL, timeout: TimeInterval) {
        defer { chainEndForgotten = false }
        let short = retrying && (finalURL != nil || !chainEndForgotten)
        return (finalURL ?? url, short ? Self.retryRequestTimeoutSeconds : Self.requestTimeoutSeconds)
    }

    /// Makes `task` `tx`'s request and sends it. A response that has not arrived `timeout` later
    /// on the clock, or by the link window's end if that comes first, ends the attempt as one
    /// nothing answered: the session's own timeout is real time, restarted on every hop, and longer.
    private func sendLocked(_ task: URLSessionDataTask, for tx: Transaction, timeout: TimeInterval) {
        tx.task = task
        tx.attemptStartedAt = clock.now
        task.delegate = self
        let wait = min(timeout, retry.linkWindowLeft(now: clock.now) ?? timeout)
        clock.schedule(after: wait) { [weak self, weak tx, weak task] in
            guard let self, let tx, let task else { return }
            self.locked {
                guard !self.cancelled, self.current === tx, tx.task === task, !tx.answered, !tx.ended else { return }
                self.endLocked(tx, "no_response_s=\(Int(self.clock.now - tx.attemptStartedAt))", retryable: true)
            }
        }
        task.resume()
    }

    /// A fresh budget: the decoder's position passed, or a restart nobody's failure caused.
    private func resetRetriesLocked() {
        retry.reset()
    }

    /// Wakes a parked read after ``recheckSeconds`` on the clock, whatever else does.
    private func scheduleRecheckLocked() {
        guard !recheckPending else { return }
        recheckPending = true
        clock.schedule(after: Self.recheckSeconds) { [weak self] in
            guard let self else { return }
            self.locked {
                self.recheckPending = false
                self.condition.broadcast()
            }
        }
    }

    /// Ends `tx` once its body has been silent for ``idleTimeoutSeconds`` on the clock: a failure
    /// like a drop, into the retry. Looks again when a chunk came in the meantime, and stops once
    /// the transaction is done with the network. The link went quiet at the last byte, so that is
    /// where the link window starts if nothing answers the retry. Nothing is checked before the
    /// response arrives: that wait is ``sendLocked(_:for:timeout:)``'s.
    private func scheduleIdleCheckLocked(_ tx: Transaction, after seconds: TimeInterval = idleTimeoutSeconds) {
        guard !tx.idleCheckPending else { return }
        tx.idleCheckPending = true
        clock.schedule(after: seconds) { [weak self, weak tx] in
            guard let self, let tx else { return }
            self.locked {
                tx.idleCheckPending = false
                guard !self.cancelled, self.current === tx, tx.answered, !tx.ended, !tx.isComplete else { return }
                let silent = self.clock.now - tx.lastByteAt
                guard silent >= Self.idleTimeoutSeconds else {
                    self.scheduleIdleCheckLocked(tx, after: Self.idleTimeoutSeconds - silent)
                    return
                }
                self.endLocked(tx, "idle_s=\(Int(silent)) at=\(tx.frontier)", retryable: true, quietSince: tx.lastByteAt)
            }
        }
    }

    /// A usable network path replaced the one the transaction's connection is on (Wi-Fi gone to
    /// cellular). That connection may never say another word, and the idle check would take
    /// ``idleTimeoutSeconds`` to notice; the transaction is ended now instead, like a drop, and
    /// ``DownloadRetry`` decides on it as on any other: a resume from the frontier after the
    /// backoff, from the same budget. A transaction done with the network, or whose every byte is
    /// in and only its completion is still on the way, is left alone.
    private func networkPathChanged() {
        locked {
            guard !cancelled, let tx = current, !tx.ended, !tx.isComplete, tx.frontier != tx.totalLength else { return }
            endLocked(tx, "path_changed at=\(tx.frontier)", retryable: true, pathChanged: true)
        }
    }

    private func request(for target: URL, from base: Int64) -> URLRequest {
        var request = URLRequest(url: target)
        request.setValue("bytes=\(base)-", forHTTPHeaderField: "Range")
        if target.hasSameOrigin(as: url) { applyServerHeaders(to: &request) }
        return request
    }

    /// The caller's auth headers, then the policy's: for `url`'s origin only.
    private func applyServerHeaders(to request: inout URLRequest) {
        for (field, value) in authHeaders { request.setValue(value, forHTTPHeaderField: field) }
        for (field, value) in policy?.headers ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
    }

    private func removeServerHeaders(from request: inout URLRequest) {
        for field in Array(authHeaders.keys) + Array(policy?.headers.keys ?? [:].keys) {
            request.setValue(nil, forHTTPHeaderField: field)
        }
    }

    /// The current transaction's task: what a test hands ``certificateRejected(task:)``.
    var currentTask: URLSessionTask? { locked { current?.task } }

    private func downloadBytesPerSecondLocked(now: TimeInterval? = nil) -> Double? {
        guard let firstSampleAt else { return nil }
        let now = now ?? clock.now
        samples.removeAll { now - $0.at > Self.throughputWindowSeconds }
        let span = min(Self.throughputWindowSeconds, max(0.25, now - firstSampleAt))
        return Double(samples.reduce(0) { $0 + $1.bytes }) / span
    }

    // MARK: - URLSessionDataDelegate (the session's serial delegate queue)

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Every hop carries the range and a resume's validator, whichever host it lands on. The
        // caller's and the policy's headers ride only the original origin's hops: URLSession carries
        // custom headers across a redirect, so another origin's hop has them taken off.
        var next = newRequest
        for field in ["Range", "If-Range"] {
            if let value = task.originalRequest?.value(forHTTPHeaderField: field) { next.setValue(value, forHTTPHeaderField: field) }
        }
        if let target = next.url, target.hasSameOrigin(as: url) {
            applyServerHeaders(to: &next)
        } else {
            removeServerHeaders(from: &next)
        }
        locked {
            if startupValue.firstResponseAt == nil, let host = next.url?.host { startupValue.hosts.append(host) }
        }
        completionHandler(next)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // As Shuttle2 does: the system's evaluation first, and only a chain it refuses is checked
        // against the leaves the user trusted, for the original origin only.
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, let policy, !policy.trustedLeafSHA256.isEmpty,
              isOrigin(space)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch policy.decision(for: trust) {
        case .systemDefault:
            completionHandler(.performDefaultHandling, nil)
        case .acceptTrustedLeaf:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .reject:
            certificateRejected(task: task)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func isOrigin(_ space: URLProtectionSpace) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return space.protocol?.lowercased() == scheme && space.host.lowercased() == host && space.port == port
    }

    /// The system refused the origin's certificate and the user trusted no such leaf: the read fails
    /// at once, with no retry.
    func certificateRejected(task: URLSessionTask) {
        locked {
            guard !cancelled, let tx = current, tx.task === task, !tx.ended else { return }
            endLocked(tx, GrowingFileConnectionPolicy.untrustedCertificateReason, retryable: false)
        }
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var events: [GrowingFileEvent] = []
        var roomFor: Int64?
        let disposition: URLSession.ResponseDisposition = locked {
            guard !cancelled, let tx = current, tx.task === dataTask, !tx.ended else { return .cancel }
            // The link is up, whatever the host says next.
            tx.answered = true
            retry.linkAnswered()
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
            let range = Self.contentRange(contentRange)
            if let resumeAt = tx.resumeAt {
                tx.resumeAt = nil
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
                    startLocked(at: offset, seekGeneration: nil, retrying: true)
                    return .cancel
                default:
                    endLocked(
                        tx, "status=\(status) content-range=\(contentRange ?? "-")", retryable: true,
                        refused: (400..<500).contains(status)
                    )
                    return .cancel
                }
                if Self.isMedia(mimeType: response.mimeType) == false {
                    endLocked(tx, "not audio: content-type=\(response.mimeType ?? "?")", retryable: tx.remembered, refused: true)
                    return .cancel
                }
                if tx.totalLength == nil { tx.totalLength = range?.total }
                lastKnownTotalLength = tx.totalLength
                roomFor = tx.totalLength.map { $0 - resumeAt }
                if finalURL == nil { finalURL = response.url }
                tx.lastByteAt = clock.now
                scheduleIdleCheckLocked(tx)
                condition.broadcast()
                return .allow
            }
            if let total = Self.totalEndingAt(tx.base, status: status, contentRange: contentRange),
               lastKnownTotalLength.map({ $0 == total }) ?? true {
                // The host says the resource ends exactly where this transaction starts: a `416`
                // with `bytes */N`, or a range clamped to the last byte, at position N. As media3
                // does, that is a zero-length open: the length is learned and the read is at its
                // end. A total that differs from the one already known (the file shrank) is
                // refused like any other answer.
                downloadLog.info("download: open_at_end gen=\(tx.generation) status=\(status) total=\(total)")
                tx.ended = true
                tx.isComplete = true
                tx.totalLength = total
                lastKnownTotalLength = total
                if finalURL == nil { finalURL = response.url }
                if startupValue.firstResponseAt == nil {
                    startupValue.firstResponseAt = clock.now
                    startupValue.status = status
                    startupValue.remembered = tx.remembered
                }
                events = [
                    .transaction(base: tx.base, generation: tx.generation, seekGeneration: tx.seekGeneration, httpStatus: status),
                    .download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecondLocked(), complete: true),
                ]
                condition.broadcast()
                return .cancel
            }
            switch status {
            case 200:
                if tx.base > 0 {
                    // The host ignored the range: this body is the file from byte 0, and the read
                    // waits for its position to arrive. Restarting would only get 200 again. A new
                    // base is a new generation, so a frontier never moves back within one.
                    if !rangeIgnored {
                        downloadLog.warning("download: range_ignored host=\(self.url.host ?? "?", privacy: .public) asked=\(tx.base)")
                    }
                    rangeIgnored = true
                    tx.base = 0
                    generation += 1
                    tx.generation = generation
                    // Byte 0 is not where the seek landed, so it is no anchor for it.
                    tx.seekGeneration = nil
                }
            case 206 where range?.start == tx.base:
                break
            default:
                endLocked(
                    tx, "status=\(status) content-range=\(contentRange ?? "-")", retryable: true,
                    refused: (400..<500).contains(status)
                )
                return .cancel
            }
            switch Self.isMedia(mimeType: response.mimeType) {
            case false?:
                // From the remembered end of the chain, the page may be its signature expiring.
                endLocked(tx, "not audio: content-type=\(response.mimeType ?? "?")", retryable: tx.remembered, refused: true)
                return .cancel
            case nil: tx.sniffPending = tx.base == 0
            case true?: break
            }
            tx.totalLength = range?.total
                ?? (response.expectedContentLength > 0 ? response.expectedContentLength + tx.base : nil)
            lastKnownTotalLength = tx.totalLength
            roomFor = tx.totalLength.map { $0 - tx.base }
            if let tag = http?.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") { tx.entityTag = tag }
            if finalURL == nil { finalURL = response.url }
            if startupValue.firstResponseAt == nil {
                startupValue.firstResponseAt = clock.now
                startupValue.status = status
                startupValue.remembered = tx.remembered
            }
            events = [.transaction(base: tx.base, generation: tx.generation, seekGeneration: tx.seekGeneration, httpStatus: status)]
            tx.lastByteAt = clock.now
            scheduleIdleCheckLocked(tx)
            condition.broadcast()
            return .allow
        }
        if let roomFor { store.makeRoom(forBytes: roomFor) }
        completionHandler(disposition)
        events.forEach { onEvent?($0) }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let claim = locked { () -> (tx: Transaction, fileOffset: Int64)? in
            guard !cancelled, let tx = current, tx.task === dataTask, !tx.ended else { return nil }
            return (tx, tx.written)
        }
        guard let tx = claim?.tx, let fileOffset = claim?.fileOffset else { return }
        let writeError = writeAll(data, to: tx.descriptor, at: fileOffset)
        var event: GrowingFileEvent?
        locked {
            // Still this task's: across the write, an idle check may have ended it and a resume
            // gone out from the frontier this chunk would move, under the same transaction.
            guard current === tx, tx.task === dataTask, !tx.ended else { return }
            if let writeError {
                endLocked(tx, "write failed errno=\(writeError)", retryable: false)
                return
            }
            tx.written += Int64(data.count)
            let now = clock.now
            tx.lastByteAt = now
            if tx.sniffPending, tx.written >= Self.sniffBytes {
                var head = [UInt8](repeating: 0, count: Self.sniffBytes)
                guard pread(tx.descriptor, &head, head.count, 0) == head.count,
                      Self.isMedia(mimeType: nil, head: head) == true else {
                    endLocked(tx, "not audio: body sniff", retryable: tx.remembered, refused: true)
                    return
                }
                tx.sniffPending = false
            }
            // Progress is the decoder's: a host that drops before the read position (a 200 from
            // byte 0, every time) spends its retries instead of looping.
            if tx.frontier > offset { resetRetriesLocked() }
            if firstSampleAt == nil { firstSampleAt = now }
            samples.append((now, data.count))
            if now - lastDownloadEventAt >= Self.downloadEventSeconds {
                lastDownloadEventAt = now
                event = .download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecondLocked(now: now), complete: false)
            }
            condition.broadcast()
        }
        if let event { onEvent?(event) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var event: GrowingFileEvent?
        var promoted = false
        locked {
            guard !cancelled, let tx = current, tx.task === task, !tx.ended else { return }
            if let error {
                endLocked(tx, "error=\((error as NSError).code)", retryable: true)
                return
            }
            if tx.sniffPending {
                endLocked(tx, "not audio: body of \(tx.written) bytes", retryable: tx.remembered, refused: true)
                return
            }
            if let total = tx.totalLength, tx.frontier < total {
                endLocked(tx, "short body ended=\(tx.frontier) total=\(total)", retryable: true)
                return
            }
            tx.ended = true
            tx.isComplete = true
            if tx.totalLength == nil { tx.totalLength = tx.frontier }
            lastKnownTotalLength = tx.totalLength
            if tx.base == 0, let file = tx.fileURL, let cached = store.promote(file, for: cacheKey) {
                tx.fileURL = cached
                tx.isCached = true
                promoted = true
            }
            downloadLog.info("download: complete gen=\(tx.generation) base=\(tx.base) frontier=\(tx.frontier) cached=\(tx.isCached)")
            event = .download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecondLocked(), complete: true)
            condition.broadcast()
        }
        if promoted { store.evict(excluding: cacheKey) }
        if let event { onEvent?(event) }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }

    /// Writes all of `data` through the store's seam; nil, or the `errno` it failed with.
    private func writeAll(_ data: Data, to descriptor: Int32, at fileOffset: Int64) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            guard let start = raw.baseAddress else { return nil }
            var done = 0
            while done < raw.count {
                let n = store.write(descriptor, start + done, raw.count - done, off_t(fileOffset + Int64(done)))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return n < 0 ? errno : EIO }
                done += n
            }
            return nil
        }
    }

    /// `X` and `Z` of `bytes X-Y/Z`; `Z` is nil for `*`.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst("bytes ".count).split(whereSeparator: { "-/".contains($0) })
        guard parts.count == 3, let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, Int64(parts[2].trimmingCharacters(in: .whitespaces)))
    }

    /// The resource's total when a fresh request's answer says it ends exactly at `base`: a `416`
    /// with `Content-Range: bytes */<base>`, or a `206` clamped to the last byte (`bytes X-Y/<base>`
    /// with `X` before `base`). Nil for any other answer.
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
    /// names nothing) the body's first ``sniffBytes`` decide when given: an mp3 or ADTS frame sync,
    /// an ID3 tag, or a container's magic, which a page never starts with. Nil: undecided.
    static func isMedia(mimeType: String?, head: [UInt8]? = nil) -> Bool? {
        let type = mimeType?.lowercased() ?? ""
        if type == "text/html" || type == "application/xhtml+xml" { return false }
        if type.hasPrefix("audio/") || type.hasPrefix("video/") || type == "application/ogg" { return true }
        guard let head else { return nil }
        guard head.count >= sniffBytes else { return false }
        if head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return true }
        let magic = String(decoding: head[0..<4], as: UTF8.self)
        return magic.hasPrefix("ID3") || ["OggS", "fLaC", "RIFF"].contains(magic)
            || String(decoding: head[4..<8], as: UTF8.self) == "ftyp"
    }
}
