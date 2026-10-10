import Foundation

enum UpstreamSupply: Sendable {
    case chunk(TaggedChunk)
    /// Nothing ready yet; the feeder asks again on its next pump.
    case pending
    case ended
}

/// What the feeder pulls from: the pipeline, later. Called on the feeder's queue.
protocol FeederUpstream: AnyObject {
    func pull() -> UpstreamSupply
    /// Drop everything buffered and supply again from this media frame, sample-accurately (ADR-0009).
    func resupply(from position: MediaPositionMap.Position)
}

enum FeederStatus: Equatable, Sendable {
    case paused
    case buffering
    case playing
    case ended
}

enum FeederEvent {
    case crossed(item: Int)
    case position(MediaPositionMap.Position)
    case status(FeederStatus)
    /// The output refused a chunk. The feeder has paused and pulls nothing more until the next flush
    /// or seek.
    case failed(any Error)
}

/// Moves tagged chunks from upstream into an `AudioOutput`: stamps them contiguously, keeps
/// `targetDepth` written ahead of the playhead, pauses through an underrun and re-feeds after any
/// flush (ADR-0018). It knows nothing of items beyond the tags.
///
/// Threading: confined to the caller's one serial queue; output events, on any thread, wait in an inbox
/// that the next `pump()` drains.
final class Feeder {
    let targetDepth: TimeInterval
    /// Depth at which a buffering output starts again; well under `targetDepth` so a slow upstream
    /// still resumes promptly.
    let resumeDepth: TimeInterval

    private let output: AudioOutput
    private let upstream: FeederUpstream
    private let onEvent: (FeederEvent) -> Void
    private let inbox = RestartInbox()

    private var map = MediaPositionMap()
    private var rate: Double = 1
    private var playWhenReady = false
    private var outputRunning = false
    private var upstreamEnded = false
    private var failed = false
    // Where the last restart asked upstream to start, the position until audio of that epoch is written.
    private var restartPosition: MediaPositionMap.Position?
    private var reportedPosition: MediaPositionMap.Position?
    private var status = FeederStatus.paused

    init(
        output: AudioOutput,
        upstream: FeederUpstream,
        targetDepth: TimeInterval = 2,
        resumeDepth: TimeInterval = 0.5,
        onEvent: @escaping (FeederEvent) -> Void
    ) {
        precondition(resumeDepth > 0 && resumeDepth <= targetDepth)
        self.output = output
        self.upstream = upstream
        self.targetDepth = targetDepth
        self.resumeDepth = resumeDepth
        self.onEvent = onEvent
        // The map's first epoch starts at 0, so the clock must too.
        output.setRate(0, at: 0)
        let inbox = inbox
        output.setEventHandler { [output] event in
            switch event {
            case let .autoFlushed(at: time): inbox.post(time)
            // A stalled clock stops tracking what is heard, so take the time it stalled at now.
            case .stalled: inbox.post(output.currentTime())
            }
        }
    }

    // MARK: Transport

    func play() {
        playWhenReady = true
        if status == .paused { setStatus(.buffering) }
        pump()
    }

    func pause() {
        playWhenReady = false
        if outputRunning {
            output.setRate(0, at: nil)
            outputRunning = false
        }
        if status != .ended { setStatus(.paused) }
    }

    /// Speed. The map needs no checkpoint: the output plays media time at any rate.
    func setRate(_ rate: Double) {
        precondition(rate > 0, "pause() stops playback")
        self.rate = rate
        if outputRunning { output.setRate(rate, at: nil) }
    }

    func seek(to position: MediaPositionMap.Position) {
        restart(from: position)
        pump()
    }

    /// Re-feeds from the heard position, e.g. so a reconfigured pipeline applies to what is queued.
    func flush() {
        restart(from: currentPosition(at: playhead()))
        pump()
    }

    // MARK: Tick

    /// All the feeder's work; the caller calls it on its queue from a timer or the output's
    /// ready-for-more callback, often enough that `resumeDepth` outlasts the gap between calls.
    func pump() {
        if let time = inbox.drain() {
            restart(from: currentPosition(at: map.playhead(currentTime: time, outputLatency: output.outputLatency)))
        }

        // Pause before refilling: audio stamped behind a running clock never plays.
        if outputRunning, playhead() >= map.writtenEnd {
            output.setRate(0, at: map.writtenEnd)
            outputRunning = false
            if !upstreamEnded { setStatus(.buffering) }
        }

        fill()

        let depth = map.writtenEnd - playhead()
        if playWhenReady, !outputRunning, !failed, status == .buffering,
           upstreamEnded ? depth > 0 : depth >= resumeDepth {
            output.setRate(rate, at: nil)
            outputRunning = true
            setStatus(.playing)
        }

        report()
    }

    // MARK: Private

    private func playhead() -> TimeInterval {
        map.playhead(currentTime: output.currentTime(), outputLatency: output.outputLatency)
    }

    private func currentPosition(at playhead: TimeInterval) -> MediaPositionMap.Position? {
        map.position(at: playhead) ?? restartPosition
    }

    /// The one recovery path: an auto-flush, a stall, a transport flush and a seek all land here.
    private func restart(from position: MediaPositionMap.Position?) {
        // Events already posted predate this flush, which covers them.
        _ = inbox.drain()
        output.flush()
        // Held at rate 0 until `resumeDepth` is written, so the first audio is not stamped behind the clock.
        let anchor = output.currentTime()
        output.setRate(0, at: anchor)
        outputRunning = false
        map.reset(at: anchor)
        upstreamEnded = false
        failed = false
        restartPosition = position
        // With no position nothing was consumed, so upstream's next chunk is still the right one.
        if let position { upstream.resupply(from: position) }
        setStatus(playWhenReady ? .buffering : .paused)
    }

    private func fill() {
        while !failed, !upstreamEnded, map.writtenEnd - playhead() < targetDepth {
            switch upstream.pull() {
            case let .chunk(chunk): write(chunk)
            case .pending: return
            case .ended: upstreamEnded = true
            }
        }
    }

    private func write(_ chunk: TaggedChunk) {
        if chunk.frameCount > 0 {
            do {
                try output.enqueue(chunk.samples, format: chunk.format, at: map.writtenEnd)
            } catch {
                failed = true
                pause()
                onEvent(.failed(error))
                return
            }
        }
        for tag in chunk.tags { map.append(tag, sampleRate: chunk.format.sampleRate) }
    }

    private func report() {
        let playhead = playhead()
        for item in map.advance(to: playhead) { onEvent(.crossed(item: item)) }
        if let position = currentPosition(at: playhead), position != reportedPosition {
            reportedPosition = position
            onEvent(.position(position))
        }
        if upstreamEnded, playhead >= map.writtenEnd, status != .ended {
            setStatus(.ended)
        }
    }

    private func setStatus(_ status: FeederStatus) {
        guard status != self.status else { return }
        self.status = status
        onEvent(.status(status))
    }
}

/// Output events reduced to the output time to restart from; the earliest wins.
private final class RestartInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval?

    func post(_ time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.time = min(self.time ?? time, time)
    }

    func drain() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        defer { time = nil }
        return time
    }
}
