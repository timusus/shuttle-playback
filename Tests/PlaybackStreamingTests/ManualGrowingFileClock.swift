import Foundation
@testable import PlaybackStreaming

/// A ``GrowingFileClock`` that moves only when a test says so. Scheduled work runs on the
/// advancing thread, in time order, each at its own time; work it schedules that falls due inside
/// the same advance runs too.
final class ManualGrowingFileClock: GrowingFileClock, @unchecked Sendable {

    private let lock = NSLock()
    private var current: TimeInterval = 1_000
    private var pending: [(at: TimeInterval, order: Int, work: () -> Void)] = []
    private var scheduled = 0

    var now: TimeInterval { lock.withLock { current } }

    /// Work waiting for its time.
    var pendingCount: Int { lock.withLock { pending.count } }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        lock.withLock {
            scheduled += 1
            pending.append((current + seconds, scheduled, work))
        }
    }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while true {
            lock.lock()
            let due = pending.enumerated()
                .filter { $0.element.at <= end }
                .min { ($0.element.at, $0.element.order) < ($1.element.at, $1.element.order) }
            guard let due else {
                current = end
                lock.unlock()
                return
            }
            pending.remove(at: due.offset)
            current = max(current, due.element.at)
            lock.unlock()
            due.element.work()
        }
    }

    /// Steps the clock `step` at a time, letting the real network answer between steps, until
    /// `condition` holds or `timeout` real seconds pass. It steps only while `source` owes the
    /// network nothing, so a loaded machine's slow loopback is never taken for a response timeout;
    /// nil steps regardless, for a link the test has made silent on purpose.
    func drive(
        _ source: GrowingFileByteSource?, step: TimeInterval = 0.5, timeout: TimeInterval = 20,
        until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if source?.awaitsNetworkForTest != true { advance(by: step) }
            // Kept: the loopback server answers on its own thread and raises no signal.
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}
