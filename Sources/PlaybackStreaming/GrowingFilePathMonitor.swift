import Foundation
import Network

/// **When the network path changes under the growing-file source**: a usable path replaces
/// another (Wi-Fi gone to cellular, the link back after none). A transaction on the old path can
/// then sit silent until the body's idle timeout; the source reopens it from the frontier at once
/// instead, as one more failure of its one recovery layer (``GrowingFileByteSource``).
///
/// Paths go in through ``update(_:)`` and out to the observers, each marked whether it is a change.
/// The path's cost (``Path/isExpensive``, ``Path/isConstrained``) is what a source's read-ahead cap
/// follows (ADR-0013); a change in cost alone is no change. ``shared`` is fed by one
/// `NWPathMonitor` for every source; a test makes its own and feeds it.
final class GrowingFilePathMonitor: @unchecked Sendable {

    /// What a change is measured on.
    struct Path: Equatable, Sendable {
        /// The path can be used.
        var satisfied: Bool
        /// The interface the path prefers (`en0`, `pdp_ip0`), nil when there is none.
        var interface: String?
        /// `NWPath.isExpensive`: cellular, or a hotspot.
        var isExpensive = false
        /// `NWPath.isConstrained`: Low Data Mode.
        var isConstrained = false
    }

    /// One `NWPathMonitor` for every source, started with the first.
    static let shared: GrowingFilePathMonitor = {
        let monitor = GrowingFilePathMonitor()
        let system = NWPathMonitor()
        system.pathUpdateHandler = { path in
            monitor.update(Path(
                satisfied: path.status == .satisfied, interface: path.availableInterfaces.first?.name,
                isExpensive: path.isExpensive, isConstrained: path.isConstrained
            ))
        }
        system.start(queue: DispatchQueue(label: "audio.growing-file.path", qos: .utility))
        monitor.system = system
        return monitor
    }()

    private let lock = NSLock()
    private var system: NWPathMonitor?
    private var last: Path?
    private var observers: [Int: (_ path: Path, _ isChange: Bool) -> Void] = [:]
    private var nextToken = 0

    /// A usable path that replaces another: never the first path seen (`NWPathMonitor` reports
    /// the current one on start), never one on the same interface as the last, never one that
    /// cannot be used (a link that goes away is the idle timeout's and the link window's). Only
    /// `satisfied` and `interface` count: the connection survives a change in cost.
    static func isChange(from old: Path?, to new: Path) -> Bool {
        guard let old, new.satisfied else { return false }
        return old.satisfied != new.satisfied || old.interface != new.interface
    }

    /// The last path seen, nil before the first: where a new source's read-ahead cap starts.
    var path: Path? { lock.withLock { last } }

    /// The path now; observers hear of it, on this thread.
    func update(_ path: Path) {
        let (notify, isChange): ([(Path, Bool) -> Void], Bool) = lock.withLock {
            defer { last = path }
            return (Array(observers.values), Self.isChange(from: last, to: path))
        }
        notify.forEach { $0(path, isChange) }
    }

    /// Calls `onUpdate` with each path and its ``isChange(from:to:)`` until ``removeObserver(_:)``
    /// with what this returns.
    func addObserver(_ onUpdate: @escaping (_ path: Path, _ isChange: Bool) -> Void) -> Int {
        lock.withLock {
            nextToken += 1
            observers[nextToken] = onUpdate
            return nextToken
        }
    }

    func removeObserver(_ token: Int) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }
}
