import Foundation

/// **What the growing file looks like right now**: the only thing outside the byte source that
/// may read it. A host player's buffering and stall rules, and any reader a host puts
/// beside the player through ``GrowingFileListener``, read this and never the source itself.
///
/// The session's one file holds ranges of the resource at their own offsets, written by any of
/// its transactions (ADR-0014). `[base, frontier)` is the range on disk the reader is in, or the
/// current transaction's while the reader is in a hole. A restart is a new transaction and a new
/// ``transactionGeneration``; a retry that resumes from the frontier keeps it, and only when the
/// host answered with the same range start and total (and `If-Range` when it gave an ETag).
public struct GrowingFileSnapshot: Equatable, Sendable {
    /// The resource offset where the reader's range on disk starts.
    public var base: Int64
    /// One past the last byte of that range: on disk and readable.
    public var frontier: Int64
    /// From `Content-Range` (or `Content-Length + base`); nil while unknown.
    public var totalLength: Int64?
    /// The reader's range on disk reaches the total: nothing up to the end is still owed.
    public var isComplete: Bool
    /// The session's file: a `.partial`, or the cache's `.audio` once every byte is in it.
    /// Nil before the first transaction.
    public var fileURL: URL?
    /// Counts transactions, from 1. A change means a new request, possibly answered with a different body.
    public var transactionGeneration: Int
    /// The player's seek generation when the transaction was opened by that seek's read: the
    /// pairing a reader uses to anchor a restart's base byte at the seek's landed time. Nil for a
    /// transaction no seek opened (the probe's, a retry's, the one after a failed read), which has no anchor.
    public var seekGeneration: Int?
    /// Body bytes per second over the last 2 s, nil until the first byte.
    public var downloadBytesPerSecond: Double?
    /// When the decoder's read parked for bytes not yet on disk, on the source's clock
    /// (`systemUptime` seconds outside a test); nil while no read waits. It spans the whole read,
    /// through retries and restarts, so `now - readWaitingSince` is how long the read has stalled.
    public var readWaitingSince: TimeInterval?

    public init(
        base: Int64,
        frontier: Int64,
        totalLength: Int64?,
        isComplete: Bool,
        fileURL: URL?,
        transactionGeneration: Int,
        seekGeneration: Int?,
        downloadBytesPerSecond: Double?,
        readWaitingSince: TimeInterval? = nil
    ) {
        self.base = base
        self.frontier = frontier
        self.totalLength = totalLength
        self.isComplete = isComplete
        self.fileURL = fileURL
        self.transactionGeneration = transactionGeneration
        self.seekGeneration = seekGeneration
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.readWaitingSince = readWaitingSince
    }
}

/// Anything that publishes a ``GrowingFileSnapshot``: the byte source, or a fake in a test.
public protocol GrowingFileSnapshotSource: AnyObject {
    /// Thread-safe; a copy, never a live view.
    var snapshot: GrowingFileSnapshot { get }
}

/// The byte layer's two structured events, `transaction` and `download`. They go to whoever
/// constructed the source, which may log them as it likes. Every transaction is a fresh body, so
/// a continuation flag would always be false and is not carried.
public enum GrowingFileEvent: Equatable, Sendable {
    /// A transaction's response was accepted. `base` is where its bytes start: 0 when the host
    /// ignored the `Range` and answered `200`.
    /// `seekGeneration` is nil unless the seek of that generation opened it; see
    /// ``GrowingFileSnapshot/seekGeneration``.
    case transaction(base: Int64, generation: Int, seekGeneration: Int?, httpStatus: Int)
    /// The download moved: at most once a second while bytes arrive, and once at completion.
    case download(frontier: Int64, downloadBytesPerSecond: Double?, complete: Bool)
    /// The seek of `seekGeneration` was answered from the file already there: no transaction
    /// carries it, so a target waiting for one is done with.
    case seekLanded(seekGeneration: Int)
    /// The decoder's read parked for bytes, `since` on the source clock (``GrowingFileSnapshot/readWaitingSince``).
    /// Once per stall: retries and rechecks inside it do not repeat it.
    case readWaiting(since: TimeInterval)
    /// That read ended: served, failed, cancelled or interrupted. Always follows a ``readWaiting(since:)``.
    case readResumed
}
