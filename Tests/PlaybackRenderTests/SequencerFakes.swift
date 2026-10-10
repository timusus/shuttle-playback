import Foundation
@testable import PlaybackRender
import XCTest

/// Holds the sequencer's jobs until the test runs them, so every interleaving is chosen, not raced.
final class ManualExecutor: SequencerExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []

    var queued: Int { lock.withLock { jobs.count } }

    func run(_ job: @escaping @Sendable () -> Void) {
        lock.withLock { jobs.append(job) }
    }

    @discardableResult
    func runNext() -> Bool {
        guard let job = lock.withLock({ jobs.isEmpty ? nil : jobs.removeFirst() }) else { return false }
        job()
        return true
    }

    func runUntilIdle() {
        while runNext() {}
    }
}

/// An item whose sample at frame f, channel c is `base + f * channels + c`, so any slice says where
/// it came from. Seeks are exact.
final class FakeItemSource: ItemSource, @unchecked Sendable {
    let format: PCMFormat
    private let frameCount: Int64
    private let chunkFrames: Int64
    private let base: Float
    private var position: Int64 = 0
    private let lock = NSLock()
    private var _interrupts = 0
    /// Runs inside `nextChunk()`, as if the decode were still in flight there.
    var duringRead: (() -> Void)?

    var interrupts: Int { lock.withLock { _interrupts } }

    init(format: PCMFormat, frames: Int64, chunkFrames: Int64 = 100, base: Float = 0) {
        self.format = format
        frameCount = frames
        self.chunkFrames = chunkFrames
        self.base = base
    }

    func samples(from: Int64, to: Int64) -> [Float] {
        let channels = Int64(format.channelCount)
        return (from * channels..<to * channels).map { base + Float($0) }
    }

    func begin(epoch: UInt64) {}

    func open() throws -> PCMFormat { format }

    func seek(toFrame frame: Int64) throws -> Int64 {
        position = min(frame, frameCount)
        return position
    }

    func nextChunk() throws -> [Float]? {
        if let duringRead {
            self.duringRead = nil
            duringRead()
        }
        guard position < frameCount else { return nil }
        let end = min(position + chunkFrames, frameCount)
        defer { position = end }
        return samples(from: position, to: end)
    }

    func interrupt(through epoch: UInt64) {
        lock.withLock { _interrupts += 1 }
    }
}

/// What a run of pulls produced: the chunks in order, and how the run stopped.
struct Drained {
    var chunks: [TaggedChunk] = []
    var ended = false

    var samples: [Float] { chunks.flatMap(\.samples) }
    var tags: [SegmentTag] { chunks.flatMap(\.tags) }

    func samples(of item: Int) -> [Float] {
        chunks.filter { $0.tags.contains { $0.item == item } }.flatMap(\.samples)
    }
}

/// Pulls until the sequencer ends, running a job whenever it is pending; at most `limit` chunks.
func drain(_ sequencer: Sequencer, _ executor: ManualExecutor, limit: Int = .max,
           file: StaticString = #filePath, line: UInt = #line) -> Drained {
    var drained = Drained()
    while drained.chunks.count < limit {
        switch sequencer.pull() {
        case let .chunk(chunk):
            drained.chunks.append(chunk)
        case .pending:
            guard executor.runNext() else {
                XCTFail("pending with no job queued", file: file, line: line)
                return drained
            }
        case .ended:
            drained.ended = true
            return drained
        case let .failed(item, error):
            XCTFail("item \(item) failed: \(error)", file: file, line: line)
            return drained
        }
    }
    return drained
}
