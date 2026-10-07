import Foundation

/// **Whether a failed download transaction is tried again, and after how long**.
///
/// The growing-file source's whole network recovery, without the source: it reports each failure
/// and whether anything answered it, and does what the ``Decision`` says. Nothing here touches a
/// lock, a task or a clock, so every branch is pinned with literal numbers.
///
/// - A failure the host answered (a refused status, a body cut short) spends one of
///   ``maxAttempts``.
/// - A failure nothing answered (no network, a refused connect, no response in time) spends none:
///   the link is down, not the host saying no. Those go on while the next attempt can start inside
///   ``linkWindow``, measured from when the link went quiet: the start of the first attempt nothing
///   answered, or the last byte of a body that fell silent. A retry does not move that start; only
///   a response does. The source cuts each attempt's wait at the window's end
///   (``linkWindowLeft(now:)``), so a dead link fails about ``linkWindow`` after it went quiet.
/// - Each failure in a row doubles the backoff, from ``firstBackoffSeconds`` up to
///   ``maxBackoffSeconds``.
/// - Progress (the frontier passing the decoder's position), or a restart no failure caused,
///   ``reset()``s the lot.
struct DownloadRetry: Equatable, Sendable {

    /// Failures the host answered, in a row without progress, before the read fails.
    static let maxAttempts = 3
    /// How long a link that answers nothing is retried before the read fails: long enough for
    /// airplane mode, a lift or a tunnel, short enough that a dead network becomes an error.
    static let linkWindowSeconds: Double = 30
    static let firstBackoffSeconds: Double = 0.1
    /// The backoff doubles up to this, so a long outage is asked about every couple of seconds
    /// and the first request after it comes back goes out soon after.
    static let maxBackoffSeconds: Double = 2

    enum Decision: Equatable, Sendable {
        /// Ask again after this many seconds: resume the file from its frontier, or restart at the
        /// decoder's position when the file does not hold it.
        case retry(after: TimeInterval)
        /// The read fails at the frontier.
        case fail
    }

    let linkWindow: TimeInterval
    /// Answered failures spent; see ``maxAttempts``.
    private(set) var attempts = 0
    /// Failures in a row, answered or not: what the backoff grows with.
    private(set) var failuresInRow = 0
    /// When the link went quiet: the first quiet failure's `quietSince` since the last response.
    private(set) var linkDownSince: TimeInterval?

    init(linkWindow: TimeInterval = DownloadRetry.linkWindowSeconds) {
        self.linkWindow = linkWindow
    }

    /// A transaction failed at `now`. `retryable` false (a full disk, a page where audio should
    /// be) fails at once and spends nothing.
    /// - Parameter quietSince: when the link last said anything to this attempt, if it went quiet
    ///   rather than answering with a refusal or a close: the attempt's start when nothing answered
    ///   it (`now` when not given), the last byte when its body fell silent. The first one since the
    ///   last response starts the link window.
    mutating func failed(answered: Bool, retryable: Bool, quietSince: TimeInterval? = nil, now: TimeInterval) -> Decision {
        if linkDownSince == nil, let since = quietSince ?? (answered ? nil : now) { linkDownSince = since }
        let backoff = min(Self.firstBackoffSeconds * pow(2.0, Double(failuresInRow)), Self.maxBackoffSeconds)
        let left = answered
            ? attempts < Self.maxAttempts
            : now + backoff - (linkDownSince ?? now) < linkWindow
        guard retryable, left else { return .fail }
        if answered { attempts += 1 }
        failuresInRow += 1
        return .retry(after: backoff)
    }

    /// How long an attempt starting at `now` may wait for its response before the link window
    /// ends; nil while the link is up. The source never lets an attempt's wait run past it.
    func linkWindowLeft(now: TimeInterval) -> TimeInterval? {
        linkDownSince.map { max(0, $0 + linkWindow - now) }
    }

    /// A response arrived: the link is up, whatever the host said.
    mutating func linkAnswered() {
        linkDownSince = nil
    }

    /// A fresh budget.
    mutating func reset() {
        self = DownloadRetry(linkWindow: linkWindow)
    }
}
