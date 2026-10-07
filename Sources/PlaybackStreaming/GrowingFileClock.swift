import Foundation

/// **The growing-file source's time**: what it reads as now, and how it runs work later. The retry
/// backoff, the link window, the throughput window, the body's idle check and a parked read's
/// recheck all go through it, so a test steps through an outage instead of sleeping through one.
protocol GrowingFileClock: AnyObject {
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }
    /// Runs `work` once, `seconds` from now on this clock, on a thread of the clock's choosing.
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void)
}

/// `systemUptime`, and a serial queue's `asyncAfter`.
final class SystemGrowingFileClock: GrowingFileClock {
    static let shared = SystemGrowingFileClock()

    private let queue = DispatchQueue(label: "audio.growing-file.clock", qos: .userInitiated)

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
