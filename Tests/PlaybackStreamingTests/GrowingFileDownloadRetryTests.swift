import Foundation
import Testing

@testable import PlaybackStreaming

/// **The download's retry budget, pinned without a network**: answered failures spend
/// attempts, unanswered ones spend the link window, the backoff doubles to its cap, and only a
/// response or a reset gives anything back. Times are literal seconds.
struct GrowingFileDownloadRetryTests {

    @Test("a host's answered failures get three retries, then the read fails")
    func answeredFailuresSpendAttempts() {
        var retry = GrowingFileDownload.Retry()
        #expect(retry.failed(answered: true, retryable: true, now: 0) == .retry(after: 0.1))
        #expect(retry.failed(answered: true, retryable: true, now: 1) == .retry(after: 0.2))
        #expect(retry.failed(answered: true, retryable: true, now: 2) == .retry(after: 0.4))
        #expect(retry.attempts == 3)
        #expect(retry.failed(answered: true, retryable: true, now: 3) == .fail)
    }

    @Test("a failure no retry fixes fails at once and spends nothing")
    func notRetryableFailsAtOnce() {
        var retry = GrowingFileDownload.Retry()
        #expect(retry.failed(answered: true, retryable: false, now: 0) == .fail)
        #expect(retry.attempts == 0)
        #expect(retry.failuresInRow == 0)
    }

    @Test("an unanswered link is retried while the next attempt starts inside the window, then fails")
    func unansweredFailuresSpendTheWindow() {
        var retry = GrowingFileDownload.Retry()
        // By the eighth failure the backoff is at its 2 s cap, so 128 s is the last that can retry.
        for second in 0..<28 {
            guard case .retry = retry.failed(answered: false, retryable: true, now: 100 + Double(second)) else {
                Issue.record("failed at \(second) s, inside the window")
                return
            }
        }
        #expect(retry.attempts == 0, "the link being down is not the host saying no")
        #expect(retry.linkDownSince == 100, "a retry moved the window's start")
        #expect(retry.failed(answered: false, retryable: true, now: 128) == .fail, "the next attempt starts at the window's end")
    }

    @Test("the window runs from when the link went quiet, and the attempt's wait stops at its end")
    func theWindowRunsFromWhenTheLinkWentQuiet() {
        var retry = GrowingFileDownload.Retry()
        #expect(retry.linkWindowLeft(now: 0) == nil, "the link is up")
        // A body silent since 60 s, ended by the idle check at 66 s: answered, but the link is quiet.
        #expect(retry.failed(answered: true, retryable: true, quietSince: 60, now: 66) == .retry(after: 0.1))
        #expect(retry.attempts == 1)
        #expect(retry.linkDownSince == 60)
        #expect(abs((retry.linkWindowLeft(now: 66.1) ?? 0) - 23.9) < 1e-9)
        // The resume nothing answered, sent at 66.1 s: it does not move the start.
        #expect(retry.failed(answered: false, retryable: true, quietSince: 66.1, now: 74.1) == .retry(after: 0.2))
        #expect(retry.linkDownSince == 60)
        #expect(retry.linkWindowLeft(now: 95) == 0, "past the end, no wait at all")
        #expect(retry.failed(answered: false, retryable: true, quietSince: 82.7, now: 90) == .fail)
    }

    @Test("an unanswered attempt's window starts when it was sent, not when it gave up")
    func anUnansweredAttemptStartsTheWindowWhenSent() {
        var retry = GrowingFileDownload.Retry()
        #expect(retry.failed(answered: false, retryable: true, quietSince: 0, now: 20) == .retry(after: 0.1))
        #expect(retry.linkDownSince == 0)
        #expect(abs((retry.linkWindowLeft(now: 20.1) ?? 0) - 9.9) < 1e-9)
    }

    @Test("the backoff doubles from 0.1 s and stops at 2 s")
    func backoffDoublesToItsCap() {
        var retry = GrowingFileDownload.Retry()
        let backoffs = (0..<8).map { _ -> TimeInterval? in
            guard case .retry(let after) = retry.failed(answered: false, retryable: true, now: 0) else { return nil }
            return after
        }
        #expect(backoffs == [0.1, 0.2, 0.4, 0.8, 1.6, 2, 2, 2])
    }

    @Test("a response ends the outage: the next unanswered failure starts a fresh window")
    func aResponseRestartsTheWindow() {
        var retry = GrowingFileDownload.Retry()
        _ = retry.failed(answered: false, retryable: true, now: 0)
        retry.linkAnswered()
        #expect(retry.linkDownSince == nil)
        #expect(retry.failed(answered: false, retryable: true, now: 29) != .fail)
        #expect(retry.linkDownSince == 29)
        #expect(retry.failed(answered: false, retryable: true, now: 58) != .fail, "the window ran from before the response")
        #expect(retry.failed(answered: false, retryable: true, now: 59) == .fail)
    }

    @Test("a response does not give answered attempts back; a reset gives everything back")
    func resetIsTheOnlyRefund() {
        var retry = GrowingFileDownload.Retry(linkWindow: 5)
        for _ in 0..<3 { _ = retry.failed(answered: true, retryable: true, now: 0) }
        retry.linkAnswered()
        #expect(retry.failed(answered: true, retryable: true, now: 0) == .fail)
        retry.reset()
        #expect(retry == GrowingFileDownload.Retry(linkWindow: 5))
        #expect(retry.failed(answered: true, retryable: true, now: 0) == .retry(after: 0.1))
    }

    @Test("mixed failures share one backoff run")
    func mixedFailuresShareTheBackoff() {
        var retry = GrowingFileDownload.Retry()
        #expect(retry.failed(answered: false, retryable: true, now: 0) == .retry(after: 0.1))
        #expect(retry.failed(answered: true, retryable: true, now: 1) == .retry(after: 0.2))
        #expect(retry.failed(answered: false, retryable: true, now: 2) == .retry(after: 0.4))
        #expect(retry.attempts == 1)
    }
}
