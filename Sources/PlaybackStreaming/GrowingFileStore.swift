import CryptoKit
import Foundation
import OSLog

private let downloadLog = Logger(subsystem: "com.simplecityapps.shuttle-playback", category: "download")

/// **Where the growing files live** (plan `docs/plans/2026-10-06-growing-file-playback.md` §7).
///
/// One directory under `Caches`, so iOS may purge it, excluded from backup. Two kinds of file, and
/// the name is the whole state, so there is no sidecar:
/// - `<uuid>.partial`: one per transaction of a ``GrowingFileByteSource``. Deleted on a restart,
///   on a new load and stop (the source's `cancel()`), and by ``sweepPartials()`` at launch.
///   Never reused by a later session (owner decision 1).
/// - `<sha256(url)>.audio`: a transaction that completed from byte 0, renamed. Kept up to
///   ``budgetBytes`` (owner decision 3), least recently played first out; the modification date is
///   the recency and is touched on every play. Not adopted into Downloads.
///
/// `write` is the one seam: the source writes every body byte through it, so a test can fail a
/// write with `ENOSPC` at the byte it chooses.
public final class GrowingFileStore {

    /// The complete-file cache's ceiling, as the removed `CachedRunStore` had. A constant, not a setting.
    public static let budgetBytes: Int64 = 1024 * 1024 * 1024
    /// Free space a transaction leaves beyond its own bytes before the cache is evicted to make room.
    static let headroomBytes: Int64 = 200 * 1024 * 1024

    /// `pwrite`'s shape: bytes written, or -1 with `errno` set.
    public typealias WriteFunction = (_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ offset: off_t) -> Int

    public static let shared: GrowingFileStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return GrowingFileStore(directory: caches.appendingPathComponent("growing", isDirectory: true))
    }()

    /// A store of its own under the temporary directory: nothing in it was played before, and
    /// nothing played into it is found by another store.
    public static func temporary() -> GrowingFileStore {
        GrowingFileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("growing-\(UUID().uuidString)", isDirectory: true))
    }

    public let directory: URL
    let write: WriteFunction
    private let availableCapacity: () -> Int64?

    /// - Parameters:
    ///   - write: how body bytes reach the disk; `pwrite` but in a test.
    ///   - availableCapacity: free bytes for important usage on the volume; the real query when nil.
    public init(
        directory: URL,
        write: @escaping WriteFunction = { Foundation.pwrite($0, $1, $2, $3) },
        availableCapacity: (() -> Int64?)? = nil
    ) {
        self.directory = directory
        self.write = write
        self.availableCapacity = availableCapacity ?? {
            let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
        prepareDirectory()
    }

    // MARK: - Partials

    /// A new, empty `.partial`, owned by the caller until ``discard(_:)`` or ``promote(_:for:)``.
    func makePartial() throws -> URL {
        prepareDirectory()
        let file = directory.appendingPathComponent("\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return file
    }

    /// Deletes a partial. An open descriptor on it keeps reading until it is closed.
    func discard(_ partial: URL) {
        try? FileManager.default.removeItem(at: partial)
    }

    /// Renames a partial that holds `url` from byte 0 to its end into the cache, then evicts the
    /// cache to budget around it. Nil when the rename failed (the partial is then left as it was).
    func promote(_ partial: URL, for url: URL) -> URL? {
        let complete = completedURL(for: url)
        try? FileManager.default.removeItem(at: complete)
        do {
            try FileManager.default.moveItem(at: partial, to: complete)
        } catch {
            downloadLog.error("download: promote failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
        touch(complete)
        return complete
    }

    /// The launch sweep: deletes every partial, so call it once at launch, before any source
    /// exists; a live source's partial would go too. Returns how many were deleted.
    @discardableResult
    public func sweepPartials() -> Int {
        let partials = files(withExtension: "partial")
        for file in partials { try? FileManager.default.removeItem(at: file.url) }
        return partials.count
    }

    // MARK: - Retired run cache

    /// The removed `CachedRunStore`'s folder: up to ``budgetBytes`` under
    /// `Application Support/streamed-runs`, which iOS never purges and, its writer gone, nothing
    /// else touches either. Housekeeping for the launch path: call once, off the main thread (the
    /// delete can touch a gigabyte); a missing folder is a no-op, and any error is logged and
    /// swallowed rather than allowed to disturb a launch.
    public static func removeRetiredRunCache(applicationSupport: URL) {
        let retired = applicationSupport.appendingPathComponent("streamed-runs", isDirectory: true)
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: retired.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let bytes = directoryBytes(retired)
        do {
            try files.removeItem(at: retired)
            if bytes > 0 {
                downloadLog.info("download: removed the retired streamed-runs cache bytes=\(bytes)")
            }
        } catch {
            downloadLog.error("download: removing the retired streamed-runs cache failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What ``removeRetiredRunCache(applicationSupport:)`` frees, for the one log line. Zero when
    /// the folder cannot be read: the delete still goes ahead.
    private static func directoryBytes(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Complete files

    /// The cached complete file for `url`, touched as just played; nil when there is none. A
    /// later play reads it as a local file (`FileByteReader`), as a download is.
    public func completedFile(for url: URL) -> URL? {
        let complete = completedURL(for: url)
        guard FileManager.default.fileExists(atPath: complete.path) else { return nil }
        touch(complete)
        return complete
    }

    /// Deletes the least recently played complete files until the rest fit `budget`, never the
    /// one for `excluding`. Returns how many were deleted.
    @discardableResult
    public func evict(toBudget budget: Int64 = GrowingFileStore.budgetBytes, excluding: URL? = nil) -> Int {
        let kept = excluding.map { completedURL(for: $0).lastPathComponent }
        let cached = files(withExtension: "audio").sorted { $0.modified < $1.modified }
        var total = cached.reduce(0) { $0 + $1.bytes }
        var evicted = 0
        for file in cached where total > budget && file.url.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.bytes
            evicted += 1
        }
        return evicted
    }

    /// Before a transaction of `bytes`: when the volume cannot take them plus the headroom, the
    /// cache goes first, all of it. A play outranks a cache of earlier plays.
    func makeRoom(forBytes bytes: Int64) {
        guard let free = availableCapacity(), free < bytes + Self.headroomBytes else { return }
        let evicted = evict(toBudget: 0)
        downloadLog.info("download: low_disk free=\(free) need=\(bytes) evicted=\(evicted)")
    }

    // MARK: - Helpers

    func completedURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).audio")
    }

    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private func files(withExtension ext: String) -> [(url: URL, bytes: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == ext }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Created again whenever a partial is made: iOS may have purged `Caches` under us.
    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }
}
