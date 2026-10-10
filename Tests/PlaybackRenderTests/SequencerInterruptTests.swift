import Foundation
import PlaybackDecode
@testable import PlaybackRender
import XCTest

/// The interrupt race on real threads: `FFmpegItemSource` over a reader whose interrupt flag the
/// decoder clears at the start of each seek, as a network reader's is.
final class SequencerInterruptTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/wav_s16.wav")

    override func setUpWithError() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    /// The second seek interrupts the first just before the decoder clears the flags; the first
    /// must still stop, not stall on its dead read until it times out.
    func testAnInterruptLandingJustBeforeASeekClearsTheFlagsStillStopsThatSeek() throws {
        let reader = try StallingReader(url: Self.fixture)
        let sequencer = Sequencer(executor: SerialQueueExecutor())
        sequencer.setCurrent(item: 1, source: FFmpegItemSource(reader: reader))
        XCTAssertEqual(firstChunk(sequencer)?.tags.first?.mediaStartFrame, 0)

        reader.beforeNextClear {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                sequencer.seek(item: 1, mediaFrame: 44100)
                done.signal()
            }
            done.wait()
        }
        let start = Date()
        // Far past what the open buffered, so the seek has to go to the reader.
        sequencer.seek(item: 1, mediaFrame: 80000)
        let chunk = firstChunk(sequencer)

        XCTAssertEqual(chunk?.tags.first?.mediaStartFrame, 44100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "the interrupted seek ran on to its stall")
    }

    private func firstChunk(_ sequencer: Sequencer, file: StaticString = #filePath, line: UInt = #line) -> TaggedChunk? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            switch sequencer.pull() {
            case let .chunk(chunk): return chunk
            case .pending: usleep(1000)
            case .ended:
                XCTFail("ended", file: file, line: line)
                return nil
            case let .failed(item, error):
                XCTFail("item \(item) failed: \(error)", file: file, line: line)
                return nil
            }
        }
        XCTFail("no chunk in 10 s", file: file, line: line)
        return nil
    }
}

/// A file reader with its own latched interrupt flag. A hook can run once just before the next
/// clear, and the read or seek after that clear stalls, as on a dead connection, until it is interrupted
/// or `stall` passes.
private final class StallingReader: StreamByteReader, @unchecked Sendable {
    private let file: FileByteReader
    private let condition = NSCondition()
    private let stall: TimeInterval = 3
    private var interrupted = false
    private var stallsNextCall = false
    private var hook: (() -> Void)?

    init(url: URL) throws {
        file = try FileByteReader(url: url)
    }

    func beforeNextClear(_ hook: @escaping () -> Void) {
        condition.withLock { self.hook = hook }
    }

    var totalLength: Int64? { file.totalLength }
    var position: Int64 { file.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        try waitOutStall()
        return try file.read(into: buffer, maxLength: maxLength)
    }

    func seek(to offset: Int64) throws {
        try waitOutStall()
        try file.seek(to: offset)
    }

    private func waitOutStall() throws {
        try condition.withLock {
            if stallsNextCall {
                stallsNextCall = false
                let deadline = Date().addingTimeInterval(stall)
                while !interrupted, condition.wait(until: deadline) {}
            }
            if interrupted { throw StreamByteReaderError.interrupted }
        }
    }

    func cancel() { file.cancel() }

    func interrupt() {
        condition.withLock {
            interrupted = true
            condition.broadcast()
        }
    }

    func clearInterrupt() {
        let hook = condition.withLock {
            defer { self.hook = nil }
            return self.hook
        }
        hook?()
        condition.withLock {
            interrupted = false
            if hook != nil { stallsNextCall = true }
        }
    }
}
