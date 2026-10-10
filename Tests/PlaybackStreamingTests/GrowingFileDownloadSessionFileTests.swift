import Foundation
import Testing

@testable import PlaybackStreaming

/// **The session's one file** (ADR-0014): promotion once `[0, total)` is covered, whichever
/// transactions wrote it, and the window that bounds a resource of unknown length.
struct GrowingFileDownloadSessionFileTests {

    @Test("tail, then middle, then head: the transaction closing the last hole promotes the file once, mid-body")
    func transactionsCoveringTheFilePromoteIt() throws {
        let h = Harness()
        try h.machine.seek(to: 8000)
        h.read()
        #expect(h.requests.last == h.request(1, from: 8000))
        h.respond(206, range: "bytes 8000-9999/10000")
        h.body(2000)
        h.end()
        #expect(!h.machine.file.isCached)

        try h.machine.seek(to: 4000)
        h.read()
        #expect(h.requests.last == h.request(2, from: 4000, end: 8000))
        h.respond(206, range: "bytes 4000-7999/10000")
        h.body(4000)
        h.end()
        #expect(!h.machine.file.isCached)

        try h.machine.seek(to: 0)
        h.read()
        #expect(h.requests.last == h.request(3, from: 0, end: 4000))
        h.respond(206, range: "bytes 0-3999/10000")
        h.body(3999)
        #expect(!h.machine.file.isCached)
        h.body(1)
        #expect(h.machine.file.isCached, "promoted on the chunk that closed the hole, before the body's end")
        h.end()
        #expect(h.log.filter { $0 == .promote }.count == 1)

        // Read to the end from disk, with no request.
        while case .serve = h.read() {}
        #expect(h.machine.offset == 10_000)
        #expect(h.requests.count == 3)
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).isComplete)

        h.run(h.machine.cancel())
        #expect(h.log.last { if case .retire = $0 { true } else { false } } == .retire(discardFile: false))
    }

    @Test("a full body answering a bounded request ends once its bytes close the file, and is promoted")
    func aFullBodyEndsOnceTheFileIsWhole() throws {
        let h = Harness()
        try h.machine.seek(to: 6000)
        h.read()
        h.respond(206, range: "bytes 6000-9999/10000")
        h.body(4000)
        h.end()

        try h.machine.seek(to: 0)
        h.read()
        #expect(h.requests.last == h.request(2, from: 0, end: 6000))
        // A host that ignores the bound: the whole file from byte 0.
        h.respond(200, length: 10_000)
        h.body(6000)
        #expect(h.machine.file.isCached)
        #expect(h.log.contains(.cancelTask), "the rest of the body is already on disk")
        h.body(1000)
        #expect(h.log.filter { $0 == .promote }.count == 1)
        #expect(h.machine.current?.written == 6000, "nothing written once the file is the cache's")
    }

    @Test("with no known total, a range more than the window behind the reader is dropped and punched; never promoted")
    func anUnknownLengthIsBoundedByTheWindow() throws {
        let h = Harness(unknownLengthWindow: 1000)
        h.read()
        h.respond(200)
        h.body(3000)
        h.read(2500)
        #expect(!h.log.contains { if case .punchHole = $0 { true } else { false } })

        h.read(100)
        #expect(h.log.contains(.punchHole(0..<1500)))
        #expect(h.machine.file.ranges.ranges == [1500..<3000])

        h.end()
        #expect(h.machine.totalLength == 3000)
        #expect(!h.machine.file.isCached, "the window dropped its head: never whole")

        // A seek back behind the window fetches again, up to what is still on disk.
        try h.machine.seek(to: 0)
        h.read()
        #expect(h.requests.last == h.request(2, from: 0, end: 1500))
    }

    @Test("a bounded 206 whose total is '*' keeps the known total, so a later response with another total is caught")
    func aStarTotalKeepsTheKnownTotal() throws {
        let h = Harness()
        try h.machine.seek(to: 8000)
        h.read()
        h.respond(206, range: "bytes 8000-9999/10000")
        h.body(2000)
        h.end()

        try h.machine.seek(to: 4000)
        h.read()
        #expect(h.requests.last == h.request(2, from: 4000, end: 8000))
        #expect(h.respond(206, range: "bytes 4000-7999/*"))
        #expect(h.machine.totalLength == 10_000)
        h.body(4000)
        h.end()

        try h.machine.seek(to: 0)
        h.read()
        #expect(h.requests.last == h.request(3, from: 0, end: 4000))
        #expect(!h.respond(206, range: "bytes 0-3999/20000"), "the file changed behind the URL")
        #expect(h.machine.file.ranges.ranges.isEmpty)
    }

    @Test("a 416 that reveals the total of a body of unknown length promotes a file that is already whole")
    func aLateTotalFromA416Promotes() {
        let h = Harness()
        h.read()
        h.respond(200)
        h.body(3000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 3000))
        #expect(!h.machine.file.isCached)

        #expect(!h.respond(416, range: "bytes */3000"))
        #expect(h.machine.totalLength == 3000)
        #expect(h.machine.file.isCached, "promoted when the total became known")
        #expect(h.log.filter { $0 == .promote }.count == 1)
    }

    @Test("a body of unknown length that ends cleanly plays to its end but is never cached")
    func anUnknownLengthIsNeverPromoted() {
        let h = Harness(unknownLengthWindow: 1000)
        h.read()
        h.respond(200)
        h.body(3000)
        h.end()
        #expect(h.machine.totalLength == 3000, "the reader still sees the end")
        #expect(!h.machine.file.isCached)
        #expect(!h.log.contains(.promote))
    }
}
