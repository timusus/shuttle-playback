import Foundation
import PlaybackDecode

/// **Every transaction of a session writes into one sparse file at each byte's resource offset;
/// the decoder reads the file and waits at the frontier** (ADR-0014). Unthrottled, no run cache,
/// no redirect cache.
///
/// - A transaction is `GET` with `Range: bytes=<base>-` and the caller's auth headers (on every hop
///   too), bounded (`bytes=<base>-<end>`) when the file already holds a range after `base`, so
///   nothing on disk is fetched again. Each body chunk is written at its resource offset and the
///   frontier advances. A read inside a range on disk needs no transaction. A `200` to a ranged
///   request re-declares the transaction as starting at byte 0, under a new generation, and the
///   read waits for its position. Once `[0, total)` is on disk, whichever transactions wrote it,
///   the file is renamed into ``GrowingFileStore``'s cache. A new transaction whose total or
///   strong ETag differs from the session's deletes the file. With no known total, a range more
///   than ``GrowingFileDownload/unknownLengthWindowBytes`` behind the reader is dropped and its
///   blocks punched out.
/// - A dropped connection, a silent body or a refused status is tried again after the backoff
///   ``GrowingFileDownload/Retry`` decides, until it says the read fails with `.transport`: a few
///   attempts for failures the host answered, the link window for ones nothing answered. A request
///   nothing answers in time (``requestTimeoutSeconds`` for a transaction's first, the shorter
///   ``retryRequestTimeoutSeconds`` for a retry, neither past the link window's end) is ended as
///   one nothing answered, so a dead link fails about 30 s after it went quiet. A retry whose
///   transaction holds the decoder's position resumes it: `Range: bytes=<frontier>-` (with `If-Range`
///   when the host gave a strong ETag), appended to the same file under the same generation, so
///   nothing already on disk is fetched again. A resume the host answers with anything but a `206`
///   from the frontier with the same total (a `200`, or a body the server has changed between
///   requests) deletes the file for a restart at the decoder's position; a retry whose
///   transaction does not hold that position restarts there, keeping the file.
///   Retries and resumes go straight to the redirect chain's remembered end, so a slow chain is
///   not walked again inside a retry's short wait. A request there that is refused (a `4xx`, a
///   page) or unanswered forgets it, a signed hop may have expired, and the next request walks the
///   chain from the requested URL once with the generous wait.
/// - A new network path (``GrowingFilePathMonitor``) ends a transaction still on the network at
///   once, as a drop the retry above decides on, instead of leaving it to the idle timeout.
/// - With a ``GrowingFileReadAhead``, on an expensive or constrained path, the request is cancelled
///   once the frontier is that far ahead of the decoder and resumed as above, with nothing spent,
///   when the decoder is within half of it (ADR-0013).
/// - A transaction whose answer says the resource ends exactly at its base or resume point (`416` with
///   `bytes */N`, or a range clamped to the last byte) is a zero-length open, as in media3: the
///   length is learned and the read is at its end (``GrowingFileDownload/totalEndingAt(_:status:contentRange:)``).
/// - ``snapshot`` is the only read surface for anyone but the decoder; ``GrowingFileEvent``s
///   go to `onEvent`, on the session's delegate queue or the decoder's thread. A read that
///   parks for bytes reports ``GrowingFileEvent/readWaiting(since:)`` and, when it ends,
///   ``GrowingFileEvent/readResumed``, both on the decoder's thread outside the lock.
///
/// Every rule above is ``GrowingFileDownload``'s, a state machine with no lock, task, file or
/// clock. This class is its adapter: it feeds the machine the decoder's calls, the session's
/// callbacks, the clock's timers and the path monitor's changes, and carries out the effects it
/// answers with.
///
/// Threading: the decoder's thread calls the ``StreamByteReader`` methods, and they block; the
/// session's serial delegate queue writes. Both meet under `condition`, which guards the machine.
/// File I/O runs outside it, each side holding the ``Transaction`` it works on, which owns the
/// descriptor: a restart can retire a transaction mid-`pread` and its descriptor stays open until
/// the read lets go. Time (the backoff, the link window, the throughput window, the recheck, the
/// body's idle check) is the ``GrowingFileClock``'s.
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
    /// ends the transaction itself (on the clock). A connection that falls silent (a dead Wi-Fi, a
    /// host that stops sending without closing) is then an ordinary failure that
    /// ``GrowingFileDownload/Retry`` decides on. This is the player's only network recovery; with
    /// URLSession's default 60 s a silent link held the read that long. A constant consumers may
    /// read, in seconds.
    public static let idleTimeoutSeconds: TimeInterval = 6
    /// How long a transaction's first request waits for its response, on the clock; also the
    /// session's `timeoutIntervalForRequest`, a backstop restarted on every redirect hop. Generous,
    /// so a cold origin or a long chain of redirects (5.3 s to the first byte on a real host) is
    /// waited for rather than failed; the body's silence is ``idleTimeoutSeconds``'s alone.
    static let requestTimeoutSeconds: TimeInterval = 20
    /// How long a retry or resume waits for its response. Short: the host was just talking to
    /// this source or the link just went quiet, the request goes to the chain's remembered end
    /// rather than through the chain, and each wait the link window must cover is one of these, so
    /// a dead link fails about ``GrowingFileDownload/Retry/linkWindowSeconds`` after it went quiet
    /// instead of after three ``requestTimeoutSeconds``. The one retry that walks the chain again
    /// after its end was refused or unanswered waits ``requestTimeoutSeconds``, within the window.
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

    /// The session's file, which the machine knows only by its effects. Mutable state is behind the
    /// source's `condition`.
    private final class SessionFile {
        let descriptor: Int32
        /// Moves when the file is promoted into the cache.
        var fileURL: URL

        init(descriptor: Int32, fileURL: URL) {
            self.descriptor = descriptor
            self.fileURL = fileURL
        }

        deinit { Foundation.close(descriptor) }
    }

    /// What waits until `condition` is released.
    private enum Deferred {
        case makeRoom(Int64)
        case evict
        case emit(GrowingFileEvent)
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
    private var machine: GrowingFileDownload
    /// The session's file; nil before the first transaction and once deleted.
    private var file: SessionFile?
    /// The current transaction's task.
    private var task: URLSessionDataTask?
    /// The machine's name for `task`'s request.
    private var attempt = 0
    private var requestsSent = 0

    /// Requests issued so far: a test asserts "nothing was sent" on this, at once, instead of
    /// waiting to see whether the server hears one.
    var requestsSentForTest: Int { locked { requestsSent } }

    /// - Parameters:
    ///   - authHeaders: resolved by the caller before construction; values are never logged.
    ///   - cacheKey: names the resource in the store's completed-file cache, for a `url` that carries a
    ///     token or session id which changes between plays. Pass the URL without them, and ask the
    ///     store for `completedFile(for:)` with the same key. The requests still go to `url`. Nil
    ///     (the default) keys the cache by `url`.
    ///   - connectionPolicy: extra headers and the leaf certificates the user trusted for `url`'s origin; nil
    ///     (the default) is the system's trust and no extra headers. Like `authHeaders`, its headers
    ///     are sent only to that origin, never to another one a redirect lands on.
    ///   - readAhead: how far the download may run ahead of the decoder while the network path is
    ///     expensive or constrained (ADR-0013); nil (the default) downloads the whole file on any path.
    ///   - onEvent: the `transaction`/`download` events.
    public convenience init(
        url: URL,
        authHeaders: [String: String],
        cacheKey: URL? = nil,
        connectionPolicy: GrowingFileConnectionPolicy? = nil,
        readAhead: GrowingFileReadAhead? = nil,
        store: GrowingFileStore = .shared,
        session: URLSession = GrowingFileByteSource.sharedSession,
        onEvent: ((GrowingFileEvent) -> Void)? = nil
    ) {
        self.init(
            url: url, authHeaders: authHeaders, cacheKey: cacheKey, connectionPolicy: connectionPolicy,
            readAhead: readAhead, store: store, session: session, clock: SystemGrowingFileClock.shared, onEvent: onEvent
        )
    }

    /// - Parameters:
    ///   - clock: a test's steps through backoffs and windows; the system's otherwise.
    ///   - pathMonitor: a test's paths; the shared `NWPathMonitor`'s otherwise.
    ///   - unknownLengthWindow: a test's small window for a body of unknown length.
    init(
        url: URL,
        authHeaders: [String: String],
        cacheKey: URL? = nil,
        connectionPolicy: GrowingFileConnectionPolicy? = nil,
        readAhead: GrowingFileReadAhead? = nil,
        store: GrowingFileStore = .shared,
        session: URLSession = GrowingFileByteSource.sharedSession,
        clock: GrowingFileClock,
        pathMonitor: GrowingFilePathMonitor = .shared,
        unknownLengthWindow: Int64 = GrowingFileDownload.unknownLengthWindowBytes,
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
        self.machine = GrowingFileDownload(url: url, readAhead: readAhead?.bytes, unknownLengthWindow: unknownLengthWindow)
        self.onEvent = onEvent
        super.init()
        let observer = pathMonitor.addObserver { [weak self] path, isChange in
            self?.networkPathUpdated(path, isChange: isChange)
        }
        locked {
            pathObserver = observer
            if let path = pathMonitor.path, path.satisfied { _ = machine.pathCost(isExpensive: Self.costs(path), now: clock.now) }
        }
    }

    // MARK: - Published state

    public var snapshot: GrowingFileSnapshot {
        locked { machine.snapshot(fileURL: file?.fileURL, now: clock.now) }
    }

    /// Set around the decoder's `open()`; see ``GrowingFileDownload/ReadRule``.
    public var isProbing: Bool {
        get { locked { machine.isProbing } }
        set { locked { machine.isProbing = newValue } }
    }

    /// The player's seek of `generation` is about to be issued. The transaction the decoder's next
    /// read opens carries it; a read the current file answers reports it landed instead. No other
    /// transaction (the probe's, a retry's, the one after a failed read) carries a seek generation.
    /// Nil is a seek that anchors nothing: it only drops a claim no read has taken.
    public func willSeek(generation: Int?) {
        locked { machine.willSeek(generation: generation) }
    }

    /// Reads that have parked at the frontier so far: what a test waits on instead of a clock.
    var parkCount: Int { locked { machine.parks } }

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

    public var startup: Startup { locked { machine.startup } }

    // MARK: - StreamByteReader

    /// The current transaction's, nil until its response. Known before `AVSEEK_SIZE` is first
    /// asked: the decoder's first call is a read (`probe_id3_offset`), which waits for a byte.
    public var totalLength: Int64? { locked { machine.totalLength } }

    public var position: Int64 { locked { machine.offset } }

    public func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        guard maxLength > 0 else { return 0 }
        var announcedWait = false
        // After the lock is released, so a handler may read the snapshot or call back in.
        defer { if announcedWait { onEvent?(.readResumed) } }
        return try readLocked(into: buffer, maxLength: maxLength, announcedWait: &announcedWait)
    }

    private func readLocked(into buffer: UnsafeMutableRawPointer, maxLength: Int, announcedWait: inout Bool) throws -> Int {
        condition.lock()
        defer { condition.unlock() }
        defer { machine.endRead() }
        var isRecheck = false
        while true {
            let step = machine.read(maxLength: maxLength, now: clock.now, isRecheck: isRecheck)
            isRecheck = false
            // A read step's effects never defer work today. If one did, performUnlocked would drop
            // the lock between this decision and condition.wait(), and a .park could miss its wake.
            performUnlocked(runLocked(step.effects))
            switch step.action {
            case .serve(let fileOffset, let count, let landed):
                guard let file else { throw StreamByteReaderError.transport("no file") }
                condition.unlock()
                if let landed { onEvent?(.seekLanded(seekGeneration: landed)) }
                var got: Int
                repeat { got = pread(file.descriptor, buffer, count, off_t(fileOffset)) } while got < 0 && errno == EINTR
                condition.lock()
                guard got > 0 else { throw StreamByteReaderError.transport("pread failed at \(fileOffset)") }
                machine.advance(by: got)
                return got
            case .endOfStream(let landed):
                if let landed { performUnlocked([Deferred.emit(.seekLanded(seekGeneration: landed))]) }
                return 0
            case .park:
                if !announcedWait, let since = machine.readWaitingSince {
                    announcedWait = true
                    performUnlocked([Deferred.emit(.readWaiting(since: since))])
                    // Bytes may have landed while the lock was down, and their wake with it.
                    isRecheck = true
                    continue
                }
                condition.wait()
            case .again:
                continue
            case .fail(let error):
                throw error
            }
        }
    }

    public func seek(to newOffset: Int64) throws {
        try locked { try machine.seek(to: newOffset) }
    }

    /// Ends the download and deletes the partial (a cached complete file stays): a new load or
    /// stop. Logs what was fetched and never read, the cost of whole-file fetches.
    public func cancel() {
        let observer: Int? = locked {
            defer { pathObserver = nil }
            return pathObserver
        }
        if let observer { pathMonitor.removeObserver(observer) }
        perform(locked { runLocked(machine.cancel()) })
    }

    /// ``cancel()`` after a load whose bytes the decoder could not open: the complete file the
    /// download may already have finished into leaves the cache too, so the next play fetches
    /// again instead of failing on the same file.
    public func cancelDiscardingCache() {
        cancel()
        locked {
            guard let cached = file, machine.dropCachedFile() else { return }
            store.discard(cached.fileURL)
            file = nil
        }
    }

    /// A backstop for a creator that never cancelled. Only reached once no task holds the source
    /// as its delegate, so what is left is the file.
    deinit {
        if let pathObserver { pathMonitor.removeObserver(pathObserver) }
        if let file, !machine.file.isCached { store.discard(file.fileURL) }
    }

    public func interrupt() {
        perform(locked { runLocked(machine.interrupt()) })
    }

    public func clearInterrupt() {
        locked { machine.clearInterrupt() }
    }

    // MARK: - Carrying out the machine's effects

    /// Does `effects` in order, under `condition`; what must wait until it is released comes back.
    private func runLocked(_ effects: [GrowingFileDownload.Effect]) -> [Deferred] {
        var deferred: [Deferred] = []
        for effect in effects {
            switch effect {
            case .retire(let discardFile):
                task?.cancel()
                if discardFile, let discarded = file {
                    store.discard(discarded.fileURL)
                    file = nil
                }
            case .release:
                task = nil
            case .openFile:
                if file == nil { file = makeFile() }
                deferred += runLocked(machine.opened(fileReady: file != nil, now: clock.now))
            case .cancelTask:
                task?.cancel()
            case .send(let send):
                var request = request(for: send.url, from: send.from, end: send.end)
                if let entityTag = send.ifRange { request.setValue(entityTag, forHTTPHeaderField: "If-Range") }
                let task = session.dataTask(with: request)
                self.task = task
                attempt = send.attempt
                task.delegate = self
                requestsSent += 1
                task.resume()
            case .schedule(let timer, let seconds):
                clock.schedule(after: seconds) { [weak self] in
                    guard let self else { return }
                    self.perform(self.locked { self.runLocked(self.machine.fire(timer, now: self.clock.now)) })
                }
            case .wake:
                condition.broadcast()
            case .promote:
                if let file, let cached = store.promote(file.fileURL, for: cacheKey) {
                    file.fileURL = cached
                    machine.promoted()
                    deferred.append(.evict)
                }
            case .punchHole(let range):
                if let file { Self.punchHole(range, in: file.descriptor) }
            case .makeRoom(let bytes):
                deferred.append(.makeRoom(bytes))
            case .emit(let event):
                deferred.append(.emit(event))
            }
        }
        return deferred
    }

    /// A new partial and its descriptor; nil when none can be opened.
    private func makeFile() -> SessionFile? {
        let file = try? store.makePartial()
        let fd = file?.withUnsafeFileSystemRepresentation { $0.map { Foundation.open($0, O_RDWR) } ?? -1 } ?? -1
        guard let file, fd >= 0 else {
            if let file { store.discard(file) }
            return nil
        }
        return SessionFile(descriptor: fd, fileURL: file)
    }

    /// Frees the whole blocks of `range`. Its start rounds down, since every byte before a dropped
    /// range is dropped too; its end rounds down, keeping the block it shares with bytes still kept.
    /// A failure only keeps the blocks.
    private static func punchHole(_ range: Range<Int64>, in descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_blksize > 0 else { return }
        let block = Int64(info.st_blksize)
        let start = range.lowerBound / block * block, end = range.upperBound / block * block
        guard end > start else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(descriptor, F_PUNCHHOLE, &hole)
    }

    /// Outside `condition`.
    private func perform(_ deferred: [Deferred]) {
        for item in deferred {
            switch item {
            case .makeRoom(let bytes): store.makeRoom(forBytes: bytes)
            case .evict: store.evict(excluding: cacheKey)
            case .emit(let event): onEvent?(event)
            }
        }
    }

    /// ``perform(_:)`` from inside `condition`, which is released around it.
    private func performUnlocked(_ deferred: [Deferred]) {
        guard !deferred.isEmpty else { return }
        condition.unlock()
        perform(deferred)
        condition.lock()
    }

    /// A change reopens a transaction still on the network; every satisfied path sets whether the read-ahead
    /// cap applies.
    private func networkPathUpdated(_ path: GrowingFilePathMonitor.Path, isChange: Bool) {
        perform(locked {
            let changed = isChange ? runLocked(machine.pathChanged(now: clock.now)) : []
            // An unsatisfied path reports no cost; it would lift a pause into a request that
            // cannot be answered.
            guard path.satisfied else { return changed }
            return changed + runLocked(machine.pathCost(isExpensive: Self.costs(path), now: clock.now))
        })
    }

    private static func costs(_ path: GrowingFilePathMonitor.Path) -> Bool {
        path.isExpensive || path.isConstrained
    }

    private func request(for target: URL, from base: Int64, end: Int64?) -> URLRequest {
        var request = URLRequest(url: target)
        request.setValue("bytes=\(base)-\(end.map { String($0 - 1) } ?? "")", forHTTPHeaderField: "Range")
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
    var currentTask: URLSessionTask? { locked { task } }

    /// The machine's name for `task`'s request, when it is the current one's.
    private func attemptLocked(_ task: URLSessionTask) -> Int? {
        guard self.task === task else { return nil }
        return attempt
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
        locked { machine.redirected(toHost: next.url?.host) }
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
        perform(locked { () -> [Deferred] in
            guard let attempt = attemptLocked(task) else { return [] }
            return runLocked(machine.certificateRejected(attempt: attempt, now: clock.now))
        })
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let answer = GrowingFileDownload.Response(
            status: http?.statusCode ?? 0,
            contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
            mimeType: response.mimeType,
            expectedContentLength: response.expectedContentLength,
            entityTag: http?.value(forHTTPHeaderField: "ETag"),
            url: response.url
        )
        let (allow, deferred) = locked { () -> (Bool, [Deferred]) in
            guard let attempt = attemptLocked(dataTask) else { return (false, []) }
            let decision = machine.received(answer, attempt: attempt, now: clock.now)
            return (decision.allow, runLocked(decision.effects))
        }
        // The store makes room before the body is let in; the events follow it.
        perform(deferred.filter { if case .makeRoom = $0 { return true } else { return false } })
        completionHandler(allow ? .allow : .cancel)
        perform(deferred.filter { if case .makeRoom = $0 { return false } else { return true } })
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let claim = locked { () -> (file: SessionFile, attempt: Int, fileOffset: Int64)? in
            guard let attempt = attemptLocked(dataTask), let file,
                  let fileOffset = machine.chunkOffset(attempt: attempt) else { return nil }
            return (file, attempt, fileOffset)
        }
        guard let claim else { return }
        let writeError = writeAll(data, to: claim.file.descriptor, at: claim.fileOffset)
        perform(locked { () -> [Deferred] in
            guard file === claim.file else { return [] }
            let effects = machine.chunkWritten(data.count, attempt: claim.attempt, writeError: writeError, now: clock.now) {
                var head = [UInt8](repeating: 0, count: Self.sniffBytes)
                return pread(claim.file.descriptor, &head, head.count, 0) == head.count ? head : nil
            }
            return runLocked(effects)
        })
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        perform(locked { () -> [Deferred] in
            guard let attempt = attemptLocked(task) else { return [] }
            let code = error.map { ($0 as NSError).code }
            return runLocked(machine.completed(attempt: attempt, errorCode: code, now: clock.now))
        })
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
}
