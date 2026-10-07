import Foundation
import PlaybackDecode

/// The three switches of media3's `FakeExtractorInput`, over a file. Whatever the switches do, the
/// bytes that eventually arrive are the file's, so a decode through any combination must equal the
/// clean decode.
struct FaultSwitches: OptionSet, CustomStringConvertible {
    let rawValue: Int
    /// Each read returns 1 byte, unless that position was already served once.
    static let partialReads = FaultSwitches(rawValue: 1)
    /// The first read or seek in each `ioErrorBlockBytes` block fails with `.interrupted`; the
    /// position is unchanged and the retry succeeds.
    static let ioErrorOncePerPosition = FaultSwitches(rawValue: 2)
    /// `totalLength` is nil.
    static let unknownLength = FaultSwitches(rawValue: 4)

    static let allCombinations: [FaultSwitches] = (1...7).map { FaultSwitches(rawValue: $0) }

    var description: String {
        var names: [String] = []
        if contains(.partialReads) { names.append("partial") }
        if contains(.ioErrorOncePerPosition) { names.append("ioError") }
        if contains(.unknownLength) { names.append("unknownLength") }
        return names.isEmpty ? "clean" : names.joined(separator: "+")
    }
}

final class FaultyByteReader: StreamByteReader {
    /// "Position" for the once-only I/O error is a block, so a 1-byte-per-read decode is not 100 000
    /// failures.
    static let ioErrorBlockBytes: Int64 = 4096

    private let inner: FileByteReader
    private let switches: FaultSwitches
    private let lock = NSLock()
    private var served = Set<Int64>()
    private var failedBlocks = Set<Int64>()
    private var bytes: Int64 = 0
    private var seeks: [Int64] = []
    private var errors = 0

    init(url: URL, switches: FaultSwitches = []) throws {
        self.inner = try FileByteReader(url: url)
        self.switches = switches
    }

    // MARK: Accounting (what `CountingByteReader` records in the decoder's own tests)

    var bytesRead: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    var seekOffsets: [Int64] { lock.lock(); defer { lock.unlock() }; return seeks }
    var injectedErrors: Int { lock.lock(); defer { lock.unlock() }; return errors }

    // MARK: StreamByteReader

    var totalLength: Int64? { switches.contains(.unknownLength) ? nil : inner.totalLength }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let at = inner.position
        try failOnce(at: at)
        var limit = maxLength
        lock.lock()
        if switches.contains(.partialReads), !served.contains(at) { limit = min(limit, 1) }
        lock.unlock()
        let n = try inner.read(into: buffer, maxLength: limit)
        lock.lock()
        bytes += Int64(n)
        for p in at..<(at + Int64(n)) { served.insert(p) }
        lock.unlock()
        return n
    }

    func seek(to offset: Int64) throws {
        try failOnce(at: offset)
        lock.lock(); seeks.append(offset); lock.unlock()
        try inner.seek(to: offset)
    }

    /// Back to byte 0 for a fresh decoder over the same reader, keeping which positions have already
    /// been served or failed. Not counted as a seek.
    func rewind() { try? inner.seek(to: 0) }

    func cancel() { inner.cancel() }
    func interrupt() { inner.interrupt() }
    func clearInterrupt() { inner.clearInterrupt() }

    private func failOnce(at offset: Int64) throws {
        guard switches.contains(.ioErrorOncePerPosition) else { return }
        lock.lock()
        let first = failedBlocks.insert(offset / Self.ioErrorBlockBytes).inserted
        if first { errors += 1 }
        lock.unlock()
        if first { throw StreamByteReaderError.interrupted }
    }
}
