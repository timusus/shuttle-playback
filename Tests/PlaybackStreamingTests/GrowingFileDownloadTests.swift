import Foundation
import PlaybackDecode
import Testing

@testable import PlaybackStreaming

/// **The transaction lifecycle, driven event by event with no server**: each test feeds
/// ``GrowingFileDownload`` reads, seeks, responses, body chunks, ends and path changes on a
/// ``ManualGrowingFileClock``, and checks the requests, events and read steps it answers with.
/// The loopback tests in `GrowingFileByteSourceTests` stay as the adapter's contract tests.
struct GrowingFileDownloadTests {

    @Test("a dropped body resumes from the frontier, in the same transaction and file, with If-Range")
    func aDropResumesFromTheFrontier() {
        let h = Harness()
        #expect(h.read() == .park)
        #expect(h.requests == [h.request(1, from: 0)])
        #expect(h.respond(206, range: "bytes 0-9999/10000", etag: "\"v1\""))
        #expect(h.events == [.transaction(base: 0, generation: 1, seekGeneration: nil, httpStatus: 206)])
        h.body(4000)
        #expect(h.read(1000) == .serve(fileOffset: 0, count: 1000, landed: nil))

        h.end(error: -1005)
        #expect(h.log.contains(.schedule(.retry(transaction: 1), after: 0.1)))
        #expect(h.machine.retry.attempts == 1)
        // The file is still read during the backoff.
        #expect(h.read() == .serve(fileOffset: 1000, count: 3000, landed: nil))
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 4000, ifRange: "\"v1\""))
        #expect(h.opens == 1)
        #expect(h.machine.generation == 1)

        #expect(h.respond(206, range: "bytes 4000-9999/10000"))
        #expect(h.transactionEvents == 1, "a resume is no new transaction")
        h.body(6000)
        h.end()
        #expect(h.read() == .serve(fileOffset: 4000, count: 6000, landed: nil))
        #expect(h.read() == .endOfStream(landed: nil))
        #expect(h.machine.current?.isCached == true)
    }

    @Test("a parked read is reported from its first park, through rechecks and a retry, until it is served")
    func aParkedReadIsReportedUntilServed() {
        let h = Harness()
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == nil)
        let parkedAt = h.now
        #expect(h.read() == .park)
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == parkedAt)

        h.respond(206, range: "bytes 0-9999/10000")
        h.clock.advance(by: 2.5)
        #expect(h.read() == .park)
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == parkedAt, "the second park keeps the first time")

        h.body(1000)
        #expect(h.read(100) == .serve(fileOffset: 0, count: 100, landed: nil))
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == nil)
    }

    @Test("a parked read keeps its first time through the restart its wake opens, as the source's one read does")
    func aParkedReadKeepsItsTimeThroughARestart() throws {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-99999/100000")
        h.body(100)
        #expect(h.read(100) == .serve(fileOffset: 0, count: 100, landed: nil))
        let parkedAt = h.now
        #expect(h.read() == .park)

        h.clock.advance(by: 2)
        try h.machine.seek(to: 90000)
        #expect(h.read() == .park, "the wake restarted at the new position and parked again")
        #expect(h.opens == 2)
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == parkedAt)
    }

    @Test("a read parked at the frontier of a body of unknown length ends its wait at the end of the stream")
    func aParkedReadEndsAtTheEndOfTheStream() {
        let h = Harness()
        h.read()
        #expect(h.respond(200))
        h.body(1000)
        #expect(h.read(1000) == .serve(fileOffset: 0, count: 1000, landed: nil))
        let parkedAt = h.now
        #expect(h.read() == .park)
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == parkedAt)

        h.clock.advance(by: 1)
        h.end()
        #expect(h.read() == .endOfStream(landed: nil))
        #expect(h.machine.snapshot(fileURL: nil, now: h.now).readWaitingSince == nil)
    }

    @Test("a resume answered from another start restarts at the decoder's position, into a new file")
    func aRefusedResumeRestarts() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000")
        h.body(4000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 4000))

        #expect(h.respond(206, range: "bytes 0-9999/10000") == false)
        #expect(h.opens == 2)
        #expect(h.log.contains(.retire(discardFile: true)))
        #expect(h.requests.last == h.request(3, from: 0))
        #expect(h.machine.generation == 2)
    }

    @Test("a 200 to a ranged request rebases the transaction at 0 under a new generation, and the read waits")
    func aRangeIgnoredResponseIsReadFromZero() {
        let h = Harness()
        h.machine.willSeek(generation: 7)
        #expect(throws: Never.self) { try h.machine.seek(to: 5000) }
        #expect(h.read() == .park)
        #expect(h.requests == [h.request(1, from: 5000)])

        #expect(h.respond(200, length: 10000))
        #expect(h.machine.rangeIgnored)
        #expect(h.events == [.transaction(base: 0, generation: 2, seekGeneration: nil, httpStatus: 200)])
        #expect(h.machine.totalLength == 10000)
        #expect(h.read() == .park, "a restart would only be answered from 0 again")
        #expect(h.opens == 1)

        h.body(6000)
        #expect(h.read() == .serve(fileOffset: 5000, count: 1000, landed: nil))

        // Every later transaction starts at 0.
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.opens == 2)
        #expect(h.log.contains(.retire(discardFile: true)))
        #expect(h.requests.last == h.request(2, from: 0))
    }

    @Test("a seek read during a pending retry restarts there carrying the seek; the old retry then does nothing")
    func aSeekDuringAPendingRetryWins() {
        let h = Harness()
        h.startWithDrop()
        h.machine.willSeek(generation: 3)
        #expect(throws: Never.self) { try h.machine.seek(to: 90000) }
        #expect(h.read() == .park)
        #expect(h.requests.last == h.request(2, from: 90000))
        #expect(h.machine.current?.id == 2)
        #expect(h.machine.current?.seekGeneration == 3)

        h.clock.advance(by: 1)
        #expect(h.requests.count == 2, "the first transaction's retry is stale")

        h.respond(206, range: "bytes 90000-99999/100000")
        #expect(h.events.last == .transaction(base: 90000, generation: 2, seekGeneration: 3, httpStatus: 206))
        h.body(500)
        #expect(h.read() == .serve(fileOffset: 0, count: 500, landed: nil))
    }

    @Test("a retry that fires after a seek but before its read restarts untagged; the read reports the landing")
    func aRetryBeforeTheSeeksReadCarriesNoSeek() {
        let h = Harness()
        h.startWithDrop()
        h.machine.willSeek(generation: 3)
        #expect(throws: Never.self) { try h.machine.seek(to: 90000) }
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 90000))
        #expect(h.machine.current?.seekGeneration == nil)

        h.respond(206, range: "bytes 90000-99999/100000")
        #expect(h.events.last == .transaction(base: 90000, generation: 2, seekGeneration: nil, httpStatus: 206))
        h.body(500)
        #expect(h.read() == .serve(fileOffset: 0, count: 500, landed: 3))
    }

    @Test("a body silent for 6 s ends like a drop, spends an attempt, and resumes from the frontier")
    func anIdleBodyEndsAndResumes() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000", etag: "\"v1\"")
        #expect(h.log.contains(.schedule(.idle(transaction: 1), after: 6)))
        h.clock.advance(by: 4)
        h.body(1000)
        h.clock.advance(by: 2)
        #expect(h.log.contains(.schedule(.idle(transaction: 1), after: 4)), "a late chunk moves the check")
        #expect(!h.log.contains(.cancelTask))

        h.clock.advance(by: 4)
        #expect(h.log.contains(.cancelTask))
        #expect(h.machine.retry.attempts == 1)
        #expect(h.machine.retry.linkDownSince == 1004, "the link went quiet at the last byte")

        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 1000, ifRange: "\"v1\""))
        #expect(h.log.contains(.schedule(.response(attempt: 2), after: 8)))
    }

    @Test("a new network path ends a body at once and resumes from the frontier, from the same budget")
    func aPathChangeMidBodyResumes() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000")
        h.body(2000)
        h.pathChanged()
        #expect(h.log.contains(.cancelTask))
        #expect(h.machine.retry.attempts == 1)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 2000))
        #expect(h.opens == 1)
    }

    @Test("a new network path leaves a transaction whose every byte is in, or that completed, alone")
    func aPathChangeAfterTheBodyDoesNothing() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000")
        h.body(10000)
        #expect(h.machine.pathChanged(now: h.now).isEmpty)
        h.end()
        #expect(h.machine.pathChanged(now: h.now).isEmpty)
        #expect(h.machine.current?.isComplete == true)
    }

    @Test("a path change before a response keeps the chain's remembered end; a response timeout forgets it")
    func aPathChangeKeepsTheRememberedEnd() {
        let h = Harness()
        let end = URL(string: "https://cdn.example/signed/episode.mp3")!
        h.read()
        h.respond(206, range: "bytes 0-9999/10000", url: end)
        h.body(1000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 1000, url: end))
        #expect(h.log.contains(.schedule(.response(attempt: 2), after: 8)))

        h.pathChanged()
        #expect(h.machine.finalURL == end)
        #expect(h.machine.retry.attempts == 1, "nothing answered: the link window, not another attempt")
        h.clock.advance(by: 0.2)
        #expect(h.requests.last == h.request(3, from: 1000, url: end))

        h.clock.advance(by: 8)
        #expect(h.machine.finalURL == nil)
        h.clock.advance(by: 0.4)
        #expect(h.requests.last == h.request(4, from: 1000))
        #expect(h.log.contains(.schedule(.response(attempt: 4), after: 20)), "walking the chain again waits the full time")
    }

    @Test("three answered failures in a row fail the read, again on the next read, until a seek")
    func answeredFailuresFailTheReadUntilASeek() {
        let h = Harness()
        #expect(h.read() == .park)
        for attempt in 1...3 {
            #expect(h.respond(503) == false)
            #expect(h.machine.retry.attempts == attempt)
            h.clock.advance(by: 1)
        }
        #expect(h.requests.count == 4)
        #expect(h.respond(503) == false)
        let failed = GrowingFileDownload.ReadStep.Action.fail(.transport("status=503 content-range=-"))
        #expect(h.read() == failed)
        #expect(h.read() == failed, "no transaction nobody asked for")
        #expect(h.opens == 4)

        h.machine.willSeek(generation: 1)
        #expect(h.read() == .park)
        #expect(h.opens == 5)
        #expect(h.requests.last == h.request(5, from: 0))
    }

    /// Issue #68: the read rule weighs the latency of the last accepted response, measured from
    /// its request going out, on the resume path and on the normal one alike.
    @Test("the response latency is recorded per accepted response and decides a seek ahead: wait, or a new request")
    func responseLatencyDecidesASeekAhead() throws {
        let h = Harness()
        #expect(h.machine.responseLatency == nil)
        h.read()
        h.clock.advance(by: 0.3)
        h.respond(206, range: "bytes 0-999999/1000000", etag: "\"v1\"")
        #expect(abs(h.machine.responseLatency! - 0.3) < 1e-9)
        h.body(1000)
        h.read(1000)

        // A drop, and the resume goes out 0.1 s later: its answer 0.2 s after that replaces it.
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 1000, ifRange: "\"v1\""))
        h.clock.advance(by: 0.2)
        h.respond(206, range: "bytes 1000-999999/1000000")
        #expect(abs(h.machine.responseLatency! - 0.2) < 1e-9, "a resume's response is measured from its own request")
        h.body(1000)
        h.read(1000)

        // 0.15 s of the download's rate ahead beats a 0.2 s request; 0.25 s does not.
        let rate = h.machine.downloadBytesPerSecond(now: h.now)!
        #expect(rate > 0)
        let frontier = h.machine.current!.frontier
        h.machine.willSeek(generation: nil)
        try h.machine.seek(to: frontier + Int64(rate * 0.15))
        #expect(h.read() == .park)
        #expect(h.requests.count == 2, "a gap the download closes in 0.15 s waits")
        try h.machine.seek(to: frontier + Int64(rate * 0.25))
        #expect(h.read() == .park)
        #expect(h.requests.count == 3, "a gap the download closes in 0.25 s is a new request")
        #expect(h.requests.last == h.request(3, from: frontier + Int64(rate * 0.25)))

        // The normal path, 0.5 s to answer: the same 0.25 s gap now waits.
        h.clock.advance(by: 0.5)
        h.respond(206, range: "bytes \(h.requests.last!.from)-999999/1000000")
        #expect(abs(h.machine.responseLatency! - 0.5) < 1e-9)
        h.body(1000)
        h.read(1000)
        let rate2 = h.machine.downloadBytesPerSecond(now: h.now)!
        let frontier2 = h.machine.current!.frontier
        try h.machine.seek(to: frontier2 + Int64(rate2 * 0.25))
        #expect(h.read() == .park)
        #expect(h.requests.count == 3, "against a 0.5 s response the same gap waits")
    }

    /// Issue #68 follow-up, ADR-0004: a failure that deleted the file is the read's at a position
    /// the source still owes bytes; at or past the known total length there is nothing owed, so the
    /// read is the end of the stream, as it was before the early failure return.
    @Test("after a file-deleting failure a read below the total fails, and at the total it is the end")
    func aDeletedFileFailsReadsOnlyBelowTheTotal() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000", etag: "\"v1\"")
        h.body(4000)
        h.read(4000)
        h.run(h.machine.certificateRejected(attempt: h.requests.last!.attempt, now: h.now))
        #expect(h.machine.current?.hasFile == false)

        try? h.machine.seek(to: 10_000)
        #expect(h.read() == .endOfStream(landed: nil), "nothing is owed at the total length")

        // The end read changed nothing: a byte below the total is still owed, and fails.
        let failed = GrowingFileDownload.ReadStep.Action.fail(.transport(GrowingFileConnectionPolicy.untrustedCertificateReason))
        try? h.machine.seek(to: 9999)
        #expect(h.read() == failed)
    }
}

/// Carries out ``GrowingFileDownload``'s effects as the adapter would, minus the lock, files and
/// network: an open always succeeds, a timer goes on the manual clock, requests and events are
/// recorded, and every effect lands in `log`.
final class Harness {
    static let url = URL(string: "https://host.example/episode.mp3")!

    let clock = ManualGrowingFileClock()
    var machine: GrowingFileDownload

    init(readAhead: Int64? = nil) {
        machine = GrowingFileDownload(url: Harness.url, readAhead: readAhead)
    }
    private(set) var requests: [GrowingFileDownload.Request] = []
    private(set) var events: [GrowingFileEvent] = []
    private(set) var log: [GrowingFileDownload.Effect] = []

    var now: TimeInterval { clock.now }
    var opens: Int { log.filter { $0 == .openFile }.count }
    var transactionEvents: Int {
        events.filter { if case .transaction = $0 { true } else { false } }.count
    }

    func request(_ attempt: Int, from: Int64, ifRange: String? = nil, url: URL = Harness.url) -> GrowingFileDownload.Request {
        GrowingFileDownload.Request(attempt: attempt, url: url, from: from, ifRange: ifRange)
    }

    func run(_ effects: [GrowingFileDownload.Effect]) {
        for effect in effects {
            log.append(effect)
            switch effect {
            case .openFile:
                run(machine.opened(fileReady: true, now: now))
            case .schedule(let timer, let seconds):
                clock.schedule(after: seconds) { [unowned self] in self.run(self.machine.fire(timer, now: self.now)) }
            case .send(let request):
                requests.append(request)
            case .emit(let event):
                events.append(event)
            case .promote:
                machine.promoted()
            case .retire, .release, .cancelTask, .wake, .makeRoom:
                break
            }
        }
    }

    /// One decoder read, through any transaction it opens, to the action it ends in.
    @discardableResult
    func read(_ maxLength: Int = 1 << 20) -> GrowingFileDownload.ReadStep.Action {
        while true {
            let step = machine.read(maxLength: maxLength, now: now)
            run(step.effects)
            switch step.action {
            case .again: continue
            case .serve(_, let count, _): machine.advance(by: count)
            default: break
            }
            if step.action != .park { machine.endRead() }
            return step.action
        }
    }

    /// The latest request's response: whether its body is taken.
    @discardableResult
    func respond(
        _ status: Int, range: String? = nil, length: Int64 = -1, etag: String? = nil, url: URL? = nil
    ) -> Bool {
        let request = requests.last!
        let response = GrowingFileDownload.Response(
            status: status, contentRange: range, mimeType: "audio/mpeg", expectedContentLength: length,
            entityTag: etag, url: url ?? request.url
        )
        let answer = machine.received(response, attempt: request.attempt, now: now)
        run(answer.effects)
        return answer.allow
    }

    func body(_ count: Int) {
        let attempt = requests.last!.attempt
        guard machine.chunkOffset(attempt: attempt) != nil else { return }
        run(machine.chunkWritten(count, attempt: attempt, now: now) { Array("ID3".utf8) + Array(repeating: 0, count: 9) })
    }

    /// The latest request's task ends: whole, or with a URL error code.
    func end(error: Int? = nil) {
        run(machine.completed(attempt: requests.last!.attempt, errorCode: error, now: now))
    }

    func pathChanged() {
        run(machine.pathChanged(now: now))
    }

    func pathCost(isExpensive: Bool) {
        run(machine.pathCost(isExpensive: isExpensive, now: now))
    }

    /// A transaction at 0 of a 100000-byte resource, 100 bytes read, then dropped: its retry is
    /// pending for 0.1 s.
    func startWithDrop() {
        read()
        respond(206, range: "bytes 0-99999/100000")
        body(100)
        read(100)
        end(error: -1005)
    }
}
