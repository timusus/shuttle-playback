import Foundation
@testable import PlaybackRender

/// An `AudioOutput` on a manual clock, with the renderer's measured timing (ADR-0018): a timestamp
/// hole plays as silence, an overlap trims the later audio, audio stamped behind the clock never
/// plays, and the clock runs on through an underrun with no event.
final class FakeAudioOutput: AudioOutput, @unchecked Sendable {
    struct Enqueue: Equatable {
        var samples: [Float]
        var format: PCMFormat
        var time: TimeInterval
    }

    enum Played: Equatable {
        case audio(start: TimeInterval, format: PCMFormat, samples: [Float])
        case silence(start: TimeInterval, duration: TimeInterval)
    }

    private struct Buffer {
        var start: TimeInterval
        var format: PCMFormat
        var samples: [Float]
        var end: TimeInterval { start + Double(samples.count / format.channelCount) / format.sampleRate }
    }

    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var _rate: Double = 0
    private var _outputLatency: TimeInterval = 0
    private var queue: [Buffer] = []
    // End of everything enqueued since the last flush, played or not: an overlap is trimmed to it.
    private var timelineEnd: TimeInterval?
    private var stalled = false
    private var rejected: Set<PCMFormat> = []
    private var handler: (@Sendable (AudioOutputEvent) -> Void)?
    private var _enqueues: [Enqueue] = []
    private var _flushes: [TimeInterval] = []
    private var _played: [Played] = []
    private var _events: [AudioOutputEvent] = []

    /// Ready for more while less than this much is queued ahead of the clock.
    let readyAhead: TimeInterval

    init(readyAhead: TimeInterval = 1) {
        self.readyAhead = readyAhead
    }

    var enqueues: [Enqueue] { locked { _enqueues } }
    /// The clock time of each flush, injected auto-flushes included.
    var flushes: [TimeInterval] { locked { _flushes } }
    var played: [Played] { locked { _played } }
    var events: [AudioOutputEvent] { locked { _events } }
    var rate: Double { locked { _rate } }

    var outputLatency: TimeInterval {
        get { locked { _outputLatency } }
        set { locked { _outputLatency = newValue } }
    }

    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        try locked {
            guard !rejected.contains(format) else { throw AudioOutputError.formatRejected(format) }
            _enqueues.append(Enqueue(samples: samples, format: format, time: time))
            var buffer = Buffer(start: time, format: format, samples: samples)
            if let end = timelineEnd, time < end {
                let trimmed = min(frameCount(end - time, format), samples.count / format.channelCount)
                buffer.samples.removeFirst(trimmed * format.channelCount)
                buffer.start += Double(trimmed) / format.sampleRate
            }
            timelineEnd = max(timelineEnd ?? buffer.end, buffer.end)
            if !buffer.samples.isEmpty { queue.append(buffer) }
        }
    }

    func flush() {
        locked {
            _flushes.append(clock)
            queue = []
            timelineEnd = nil
            stalled = false
        }
    }

    func setRate(_ rate: Double, at time: TimeInterval?) {
        locked {
            _rate = rate
            if let time { clock = time }
        }
    }

    func currentTime() -> TimeInterval { locked { clock } }

    var isReadyForMoreData: Bool {
        locked { (timelineEnd ?? clock) - clock < readyAhead }
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void) {
        locked { self.handler = handler }
    }

    // MARK: Test controls

    /// Moves wall time on by `seconds`; the clock moves `rate` times as far, playing what is queued.
    func advance(by seconds: TimeInterval) {
        locked {
            let from = clock, to = clock + seconds * _rate
            guard to > from else { return }
            clock = to
            guard !stalled else { return record(.silence(start: from, duration: to - from)) }
            var cursor = from
            while let buffer = queue.first, buffer.start < to {
                let start = max(cursor, buffer.start), end = min(buffer.end, to)
                if start < end {
                    if start > cursor { record(.silence(start: cursor, duration: start - cursor)) }
                    let first = frameCount(start - buffer.start, buffer.format)
                    let last = frameCount(end - buffer.start, buffer.format)
                    let channels = buffer.format.channelCount
                    record(.audio(
                        start: buffer.start + Double(first) / buffer.format.sampleRate,
                        format: buffer.format,
                        samples: Array(buffer.samples[(first * channels)..<(last * channels)])
                    ))
                    cursor = end
                }
                guard buffer.end <= to else { break }
                queue.removeFirst()
            }
            if cursor < to { record(.silence(start: cursor, duration: to - cursor)) }
        }
    }

    /// The route-change auto-flush: drops everything queued and reports the flush time.
    func injectAutoFlush() {
        let (time, handler) = locked {
            _flushes.append(clock)
            queue = []
            timelineEnd = nil
            _events.append(.autoFlushed(at: clock))
            return (clock, self.handler)
        }
        handler?(.autoFlushed(at: time))
    }

    /// The output plays silence until the next `flush()`, with its clock still running.
    func injectStall() {
        let handler = locked {
            stalled = true
            _events.append(.stalled)
            return self.handler
        }
        handler?(.stalled)
    }

    func reject(_ format: PCMFormat) {
        locked { _ = rejected.insert(format) }
    }

    private func frameCount(_ seconds: TimeInterval, _ format: PCMFormat) -> Int {
        Int((seconds * format.sampleRate).rounded())
    }

    // Coalesces with the previous span when contiguous, so a test compares what was heard, not
    // how `advance` was sliced.
    private func record(_ span: Played) {
        switch (_played.last, span) {
        case let (.audio(start, format, samples)?, .audio(next, nextFormat, more))
            where format == nextFormat
            && abs(start + Double(samples.count / format.channelCount) / format.sampleRate - next) < 1e-9:
            _played[_played.count - 1] = .audio(start: start, format: format, samples: samples + more)
        case let (.silence(start, duration)?, .silence(next, more)) where abs(start + duration - next) < 1e-9:
            _played[_played.count - 1] = .silence(start: start, duration: duration + more)
        default:
            _played.append(span)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
