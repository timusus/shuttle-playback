import Foundation

/// **What the growing file looks like right now**: the only thing outside the byte source that
/// may read it (plan `docs/plans/2026-10-06-growing-file-playback.md` §2 "Published state";
/// architecture doc §3). The controller's buffering and stall rules, and any reader a host puts
/// beside the player through ``GrowingFileListener``, read this and never the source itself.
///
/// The file holds `[base, frontier)` of the resource, from ONE transaction: a restart is a new
/// file, a new `base` and a new ``transactionGeneration`` (plan §4). A retry that resumes the file
/// from its frontier keeps all three, and only when the host answered with the same range start
/// and total (and `If-Range` when it gave an ETag); a reader of one file sees the bytes that were
/// played.
public struct GrowingFileSnapshot: Equatable, Sendable {
    /// The resource offset of the file's first byte.
    public var base: Int64
    /// One past the last byte on disk and readable.
    public var frontier: Int64
    /// From `Content-Range` (or `Content-Length + base`); nil while unknown.
    public var totalLength: Int64?
    /// This transaction's body arrived whole: no more bytes are coming to this file.
    public var isComplete: Bool
    /// Where the file is: a `.partial`, or the cache's `.audio` once a body from byte 0 has completed.
    /// Nil before the first transaction.
    public var fileURL: URL?
    /// Counts transactions, from 1. A change means a new file and possibly a different stitch.
    public var transactionGeneration: Int
    /// The player's seek generation when the transaction was opened by that seek's read: the
    /// pairing a reader uses to anchor a restart's base byte at the seek's landed time. Nil for a
    /// transaction no seek opened (the probe's, a retry's, the one after a failed read), which has no anchor.
    public var seekGeneration: Int?
    /// Body bytes per second over the last 2 s, nil until the first byte.
    public var downloadBytesPerSecond: Double?

    public init(
        base: Int64,
        frontier: Int64,
        totalLength: Int64?,
        isComplete: Bool,
        fileURL: URL?,
        transactionGeneration: Int,
        seekGeneration: Int?,
        downloadBytesPerSecond: Double?
    ) {
        self.base = base
        self.frontier = frontier
        self.totalLength = totalLength
        self.isComplete = isComplete
        self.fileURL = fileURL
        self.transactionGeneration = transactionGeneration
        self.seekGeneration = seekGeneration
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }
}

/// Anything that publishes a ``GrowingFileSnapshot``: the byte source, or a fake in a test.
public protocol GrowingFileSnapshotSource: AnyObject {
    /// Thread-safe; a copy, never a live view.
    var snapshot: GrowingFileSnapshot { get }
}

/// The byte layer's two structured events, `transaction` and `download` in the architecture doc's
/// fixed set (§4), with the same fields. `PlaybackEventLog` (architecture step A) does not exist
/// yet: until it does these go to whoever constructed the source, and step A turns the handler into
/// a call that writes them as `{t_ms, out_frame, type, gen, …}` lines. Every transaction is a fresh
/// stitch, so the table's `isContinuation` is always false and is not carried.
public enum GrowingFileEvent: Equatable, Sendable {
    /// A transaction's response was accepted. `base` is where its file starts: 0 when the host
    /// ignored the `Range` and answered `200`.
    /// `seekGeneration` is nil unless the seek of that generation opened it; see
    /// ``GrowingFileSnapshot/seekGeneration``.
    case transaction(base: Int64, generation: Int, seekGeneration: Int?, httpStatus: Int)
    /// The download moved: at most once a second while bytes arrive, and once at completion.
    case download(frontier: Int64, downloadBytesPerSecond: Double?, complete: Bool)
    /// The seek of `seekGeneration` was answered from the file already there: no transaction
    /// carries it, so a target waiting for one is done with.
    case seekLanded(seekGeneration: Int)
}
