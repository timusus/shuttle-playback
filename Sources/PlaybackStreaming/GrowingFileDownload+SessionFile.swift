import Foundation

// MARK: - The session's file

extension GrowingFileDownload {

    /// **The one file every transaction of a session writes into, at each byte's resource offset**
    /// (ADR-0014), and which of its bytes are there. A restart retires a transaction and keeps its
    /// bytes; only a changed resource, a failure no retry fixes, or the end of the session deletes it.
    struct SessionFile: Equatable {
        /// How far behind the reader a range of a resource with no known total is kept.
        let unknownLengthWindow: Int64
        /// The bytes on disk and readable: recorded only by the current transaction's chunks.
        private(set) var ranges = ByteRangeSet()
        /// The adapter has the file open; false before the first transaction and once deleted.
        var exists = false
        /// The file is the cache's now, renamed: complete, and never deleted with the session.
        var isCached = false
        /// The first strong ETag a response gave; a later transaction's that differs is a changed resource.
        var entityTag: String?

        init(unknownLengthWindow: Int64) {
            self.unknownLengthWindow = unknownLengthWindow
        }

        mutating func record(_ range: Range<Int64>) {
            ranges.insert(range)
        }

        /// `[0, total)` is on disk and the file is not yet the cache's.
        func isWhole(totalLength: Int64?) -> Bool {
            guard exists, !isCached, let totalLength else { return false }
            return ranges.covers(0..<totalLength)
        }

        /// With no known total, drops what lies more than ``unknownLengthWindow`` behind `offset`:
        /// the ranges whose blocks may be freed.
        mutating func dropBehind(_ offset: Int64, totalLength: Int64?) -> [Range<Int64>] {
            guard totalLength == nil, !isCached else { return [] }
            return ranges.remove(below: offset - unknownLengthWindow)
        }

        /// The file is gone: nothing of it is readable, and the next transaction opens a new one.
        mutating func deleted() {
            self = SessionFile(unknownLengthWindow: unknownLengthWindow)
        }
    }
}
