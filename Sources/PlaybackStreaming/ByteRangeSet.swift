import Foundation

/// **Which bytes of a resource a session's file holds** (ADR-0014): sorted, disjoint ranges, no
/// two touching, so a read inside one is served whole and the gap after it is one hole.
struct ByteRangeSet: Equatable, Sendable {

    private(set) var ranges: [Range<Int64>] = []

    /// Bytes covered.
    var count: Int64 { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    /// Adds `range`, merging it with every range it overlaps or touches.
    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        ranges.removeAll { other in
            guard other.lowerBound <= merged.upperBound, other.upperBound >= merged.lowerBound else { return false }
            merged = min(merged.lowerBound, other.lowerBound)..<max(merged.upperBound, other.upperBound)
            return true
        }
        let index = ranges.firstIndex { $0.lowerBound > merged.lowerBound } ?? ranges.endIndex
        ranges.insert(merged, at: index)
    }

    /// Every byte of `range` is covered.
    func covers(_ range: Range<Int64>) -> Bool {
        range.isEmpty || run(containing: range.lowerBound).map { $0.upperBound >= range.upperBound } == true
    }

    /// The covered range holding `offset`, nil when `offset` is in a hole.
    func run(containing offset: Int64) -> Range<Int64>? {
        ranges.first { $0.contains(offset) }
    }

    /// The first byte at or after `offset` that is not covered.
    func firstHole(atOrAfter offset: Int64) -> Int64 {
        run(containing: offset)?.upperBound ?? offset
    }

    /// Where the next covered range after `offset` starts; nil when none does.
    func nextCoveredStart(after offset: Int64) -> Int64? {
        ranges.first { $0.lowerBound > offset }?.lowerBound
    }

    /// Drops every byte before `offset`; the ranges that held them, which a caller may free.
    @discardableResult
    mutating func remove(below offset: Int64) -> [Range<Int64>] {
        var dropped: [Range<Int64>] = []
        while let first = ranges.first, first.lowerBound < offset {
            dropped.append(first.lowerBound..<min(first.upperBound, offset))
            if first.upperBound > offset {
                ranges[0] = offset..<first.upperBound
            } else {
                ranges.removeFirst()
            }
        }
        return dropped
    }
}
