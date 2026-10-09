import XCTest
@testable import PlaybackStreaming

/// **The covered ranges of a session's file**, pinned with literals.
final class ByteRangeSetTests: XCTestCase {

    private func set(_ ranges: Range<Int64>...) -> ByteRangeSet {
        var set = ByteRangeSet()
        for range in ranges { set.insert(range) }
        return set
    }

    func testInsertKeepsRangesSortedAndApart() {
        XCTAssertEqual(set(500..<600, 0..<100, 200..<300).ranges, [0..<100, 200..<300, 500..<600])
        XCTAssertEqual(set(0..<100, 50..<50).ranges, [0..<100], "an empty range adds nothing")
    }

    func testInsertMergesTouchingAndOverlappingRanges() {
        XCTAssertEqual(set(0..<100, 100..<200).ranges, [0..<200], "touching")
        XCTAssertEqual(set(0..<100, 50..<150).ranges, [0..<150], "overlapping")
        XCTAssertEqual(set(0..<100, 200..<300, 400..<500, 90..<410).ranges, [0..<500], "bridging several")
        XCTAssertEqual(set(0..<500, 100..<200).ranges, [0..<500], "inside one")
        XCTAssertEqual(set(0..<100, 300..<400, 100..<300).count, 400)
    }

    func testCovers() {
        let covered = set(0..<100, 200..<300)
        XCTAssertTrue(covered.covers(0..<100))
        XCTAssertTrue(covered.covers(210..<300))
        XCTAssertFalse(covered.covers(0..<101))
        XCTAssertFalse(covered.covers(50..<250), "a hole in between")
        XCTAssertFalse(covered.covers(100..<101))
        XCTAssertTrue(covered.covers(150..<150))
    }

    func testRunAndHoles() {
        let covered = set(0..<100, 200..<300)
        XCTAssertEqual(covered.run(containing: 99), 0..<100)
        XCTAssertNil(covered.run(containing: 100))
        XCTAssertEqual(covered.firstHole(atOrAfter: 50), 100)
        XCTAssertEqual(covered.firstHole(atOrAfter: 150), 150)
        XCTAssertEqual(covered.firstHole(atOrAfter: 200), 300)
        XCTAssertEqual(covered.nextCoveredStart(after: 100), 200)
        XCTAssertEqual(covered.nextCoveredStart(after: 0), 200, "the range holding the offset is not next")
        XCTAssertNil(covered.nextCoveredStart(after: 200))
    }

    func testRemoveBelowDropsAndTrims() {
        var covered = set(0..<100, 200..<300, 400..<500)
        XCTAssertEqual(covered.remove(below: 250), [0..<100, 200..<250])
        XCTAssertEqual(covered.ranges, [250..<300, 400..<500])
        XCTAssertEqual(covered.remove(below: 300), [250..<300])
        XCTAssertEqual(covered.remove(below: 350), [])
        XCTAssertEqual(covered.ranges, [400..<500])
    }
}
