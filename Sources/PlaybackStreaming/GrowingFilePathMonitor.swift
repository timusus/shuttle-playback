import Foundation
import Network

/// **When the network path changes under the growing-file source**: a usable path replaces
/// another (Wi-Fi gone to cellular, the link back after none). A transaction on the old path can
/// then sit silent until the body's idle timeout; the source reopens it from the frontier at once
/// instead, as one more failure of its one recovery layer (``GrowingFileByteSource``).
///
/// Paths go in through ``update(_:)``, changes come out to the observers. ``shared`` is fed by one
/// `NWPathMonitor` for every source; a test makes its own and feeds it.
final class GrowingFilePathMonitor: @unchecked Sendable {

    /// What a change is measured on.
    struct Path: Equatable, Sendable {
        /// The path can be used.
        var satisfied: Bool
        /// The interface the path prefers (`en0`, `pdp_ip0`), nil when there is none.
        var interface: String?
    }

    /// One `NWPathMonitor` for every source, started with the first.
    static let shared: GrowingFilePathMonitor = {
        let monitor = GrowingFilePathMonitor()
        let system = NWPathMonitor()
        system.pathUpdateHandler = { path in
            monitor.update(Path(satisfied: path.status == .satisfied, interface: path.availableInterfaces.first?.name))
        }
        system.start(queue: DispatchQueue(label: "audio.growing-file.path", qos: .utility))
        monitor.system = system
        return monitor
    }()

    private let lock = NSLock()
    private var system: NWPathMonitor?
    private var last: Path?
    private var observers: [Int: () -> Void] = [:]
    private var nextToken = 0

    /// A usable path that replaces another: never the first path seen (`NWPathMonitor` reports
    /// the current one on start), never one the same as the last, never one that cannot be used
    /// (a link that goes away is the idle timeout's and the link window's).
    static func isChange(from old: Path?, to new: Path) -> Bool {
        guard let old, new.satisfied else { return false }
        return old != new
    }

    /// The path now; observers hear of it, on this thread, when it is a change.
    func update(_ path: Path) {
        let notify: [() -> Void] = lock.withLock {
            defer { last = path }
            return Self.isChange(from: last, to: path) ? Array(observers.values) : []
        }
        notify.forEach { $0() }
    }

    /// Calls `onChange` on each change until ``removeObserver(_:)`` with what this returns.
    func addObserver(_ onChange: @escaping () -> Void) -> Int {
        lock.withLock {
            nextToken += 1
            observers[nextToken] = onChange
            return nextToken
        }
    }

    func removeObserver(_ token: Int) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }
}
