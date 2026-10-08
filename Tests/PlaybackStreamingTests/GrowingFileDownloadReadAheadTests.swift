import Foundation
import Testing

@testable import PlaybackStreaming

/// **The read-ahead cap (ADR-0013), driven event by event with no server**: on an expensive path
/// the request is cancelled once the frontier is the read-ahead ahead of the decoder, and resumed
/// from the frontier through the ADR-0004 resume once the decoder is within half of it. A pause is
/// no failure. A 1 MB resource and a 100 kB read-ahead throughout.
struct GrowingFileDownloadReadAheadTests {

    static let readAhead: Int64 = 100_000
    static let range = "bytes 0-999999/1000000"

    /// A transaction at 0 on an expensive path, answered half a second after it went out (the
    /// response latency the read rule weighs), with `bytes` of body in one chunk.
    private func started(bytes: Int, expensive: Bool = true) -> Harness {
        let h = Harness(readAhead: Self.readAhead)
        h.pathCost(isExpensive: expensive)
        h.read()
        h.clock.advance(by: 0.5)
        h.respond(206, range: Self.range, etag: "\"v1\"")
        h.body(bytes)
        return h
    }

    @Test("(a) the request is cancelled at the read-ahead and resumed with If-Range at half of it; idle, nothing is asked")
    func pausesAtTheReadAheadAndResumesAtHalf() {
        let h = started(bytes: 60_000)
        #expect(!h.log.contains(.cancelTask))
        h.body(40_000)
        #expect(h.log.last(where: { $0 != .wake }) == .cancelTask)
        #expect(h.machine.current?.paused == true)
        h.body(10_000)
        #expect(h.machine.current?.frontier == 100_000, "a chunk in flight at the cancel is dropped")

        h.clock.advance(by: 60)
        #expect(h.requests.count == 1, "a source nobody reads asks for nothing")
        #expect(h.read(50_000) == .serve(fileOffset: 0, count: 50_000, landed: nil))
        #expect(h.requests.count == 1, "the read began more than half the read-ahead behind the frontier")

        #expect(h.read(1_000) == .serve(fileOffset: 50_000, count: 1_000, landed: nil))
        #expect(h.requests.last == h.request(2, from: 100_000, ifRange: "\"v1\""))
        #expect(h.machine.current?.paused == false)
        #expect(h.respond(206, range: "bytes 100000-999999/1000000"))
        #expect(h.transactionEvents == 1, "a resume is no new transaction")
        #expect(h.opens == 1)
        h.body(40_000)
        #expect(h.machine.current?.paused == false, "still within the read-ahead")
        h.body(20_000)
        #expect(h.machine.current?.paused == true, "160 000 is 109 000 ahead of the decoder")
    }

    @Test("(b) after a 120 s pause the resume waits its full time, spends no attempt, and the link window starts at it")
    func aLongPauseIsNoFailure() {
        let h = started(bytes: 100_000)
        let paused = h.log.count
        let pausedAt = h.now
        h.clock.advance(by: 120)
        #expect(!h.log[paused...].contains { if case .schedule = $0 { true } else { false } }, "the pause started a timer")
        #expect(h.machine.retry == GrowingFileDownload.Retry())

        h.read(50_000)
        h.read(1)
        let resumedAt = h.now
        #expect(resumedAt - pausedAt == 120)
        #expect(h.requests.last == h.request(2, from: 100_000, ifRange: "\"v1\""))
        #expect(h.log.contains(.schedule(.response(attempt: 2), after: GrowingFileByteSource.retryRequestTimeoutSeconds)))

        // Nothing answers the resume: the link went quiet when it went out, not at the last byte.
        h.clock.advance(by: GrowingFileByteSource.retryRequestTimeoutSeconds)
        #expect(h.machine.retry.attempts == 0)
        #expect(h.machine.retry.linkDownSince == resumedAt)
        #expect(h.machine.retry.failuresInRow == 1)
    }

    @Test("a seek just past a paused frontier resumes on the rate from before the pause instead of restarting")
    func aPausedSourceKeepsItsRate() {
        // 100 000 bytes in 0.25 s (the window's floor) is 400 000 B/s; a 50 000-byte gap is then
        // 0.125 s against a 0.5 s response.
        let h = started(bytes: 100_000)
        h.clock.advance(by: 120)
        #expect(h.machine.downloadBytesPerSecond(now: h.now) == 0, "the measured rate has decayed")
        #expect(throws: Never.self) { try h.machine.seek(to: 150_000) }
        #expect(h.read() == .park)
        #expect(h.opens == 1, "the seek restarted")
        #expect(h.requests.last == h.request(2, from: 100_000, ifRange: "\"v1\""))
    }

    @Test("(e) on a cheap path the file downloads whole; a move to a cheap path resumes a pause at once")
    func aCheapPathIsUncapped() {
        let cheap = started(bytes: 500_000, expensive: false)
        #expect(!cheap.log.contains(.cancelTask))

        let h = started(bytes: 100_000)
        #expect(h.machine.current?.paused == true)
        #expect(h.machine.pathChanged(now: h.now).isEmpty, "a pause is not on the network")
        h.pathCost(isExpensive: true)
        #expect(h.requests.count == 1)
        h.pathCost(isExpensive: false)
        #expect(h.requests.last == h.request(2, from: 100_000, ifRange: "\"v1\""))
        h.respond(206, range: "bytes 100000-999999/1000000")
        h.body(400_000)
        #expect(h.machine.current?.paused == false)
    }

    @Test("(f) a host that ignores ranges is never capped, even answering bytes=0- with a 200")
    func aRangeIgnoredHostDownloadsWhole() {
        let fromZero = Harness(readAhead: Self.readAhead)
        fromZero.pathCost(isExpensive: true)
        fromZero.read()
        fromZero.respond(200, length: 1_000_000)
        fromZero.body(500_000)
        #expect(!fromZero.log.contains(.cancelTask))

        let h = Harness(readAhead: Self.readAhead)
        h.pathCost(isExpensive: true)
        #expect(throws: Never.self) { try h.machine.seek(to: 5_000) }
        h.read()
        h.respond(200, length: 1_000_000)
        #expect(h.machine.rangeIgnored)
        h.body(500_000)
        #expect(!h.log.contains(.cancelTask))
        #expect(h.machine.current?.paused == false)
    }

    @Test("(f) a resume answered with a changed ETag or total restarts at the decoder's position, as a retry's does")
    func aChangedResourceOnResumeRestarts() {
        for answer in [(200, nil), (206, "bytes 100000-1999999/2000000")] as [(Int, String?)] {
            let h = started(bytes: 100_000)
            h.read(50_000)
            h.read(10_000)
            #expect(h.requests.last == h.request(2, from: 100_000, ifRange: "\"v1\""))
            #expect(h.respond(answer.0, range: answer.1, length: 1_000_000) == false)
            #expect(h.opens == 2)
            #expect(h.log.contains(.retire(discardFile: true)))
            #expect(h.requests.last == h.request(3, from: 60_000))
        }
    }
}
