import Foundation
@testable import PlaybackRender

/// Stages the format at `configure` and applies it at `flush`, like media3 `BaseAudioProcessor`.
/// Subclasses override `outputFormat(for:)` and `process`.
class TestProcessor: AudioProcessor {
    var enabled = true
    /// Samples handed over per `getOutput`, the rest stays held (media3's small-limit processors).
    var maxOutputSamples = Int.max
    private(set) var appliedInput: PCMFormat?
    private var stagedInput: PCMFormat?
    private var held: [Float] = []
    private var ended = false
    private var endQueued = false
    private var pendingDropped: [DroppedFrames] = []

    func outputFormat(for input: PCMFormat) -> PCMFormat { input }
    func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput { ProcessorOutput(samples: samples) }

    var isActive: Bool { enabled }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        stagedInput = input
        return outputFormat(for: input)
    }

    func queueInput(_ samples: [Float]) {
        guard let format = appliedInput else { return }
        let output = process(samples, format: format)
        let heldFrames = held.count / outputFormat(for: format).channelCount
        held += output.samples
        pendingDropped += output.dropped.map {
            DroppedFrames(atOutputFrame: $0.atOutputFrame + heldFrames, inputFrames: $0.inputFrames)
        }
    }

    func getOutput() -> ProcessorOutput {
        let count = min(held.count, maxOutputSamples)
        let dropped = pendingDropped
        precondition(count == held.count || dropped.isEmpty, "drops need unlimited output")
        defer {
            held.removeFirst(count)
            pendingDropped = []
            if endQueued, held.isEmpty { ended = true }
        }
        return ProcessorOutput(samples: Array(held.prefix(count)), dropped: dropped)
    }

    func queueEndOfStream() { endQueued = true; if held.isEmpty { ended = true } }
    var isEnded: Bool { ended }

    func flush() {
        appliedInput = stagedInput
        held = []
        pendingDropped = []
        ended = false
        endQueued = false
        onFlush()
    }

    func reset() {
        flush()
        stagedInput = nil
        appliedInput = nil
    }

    func onFlush() {}
}

final class DuplicatingProcessor: TestProcessor {
    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        ProcessorOutput(samples: samples.flatMap { [$0, $0] })
    }
}

final class RateDoublingProcessor: TestProcessor {
    override func outputFormat(for input: PCMFormat) -> PCMFormat {
        PCMFormat(sampleRate: input.sampleRate * 2, channelCount: input.channelCount)
    }
}

/// Averages each frame down to one channel; the frame count is unchanged.
final class MonoProcessor: TestProcessor {
    override func outputFormat(for input: PCMFormat) -> PCMFormat {
        PCMFormat(sampleRate: input.sampleRate, channelCount: 1)
    }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        let channels = format.channelCount
        let frames = samples.count / channels
        return ProcessorOutput(samples: (0..<frames).map { frame in
            samples[frame * channels..<(frame + 1) * channels].reduce(0, +) / Float(channels)
        })
    }
}

/// Drops the input frames in `ranges`, counted from the last flush, and reports them like a
/// skip-silence processor would.
final class DropRangesProcessor: TestProcessor {
    let ranges: [Range<Int>]
    private var consumed = 0

    init(_ ranges: [Range<Int>]) {
        self.ranges = ranges
    }

    override func onFlush() { consumed = 0 }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        let channels = format.channelCount
        var output: [Float] = []
        var dropped: [DroppedFrames] = []
        for frame in 0..<samples.count / channels {
            let index = consumed + frame
            if ranges.contains(where: { $0.contains(index) }) {
                let outputFrames = output.count / channels
                if let last = dropped.last, last.atOutputFrame == outputFrames {
                    dropped[dropped.count - 1].inputFrames += 1
                } else {
                    dropped.append(DroppedFrames(atOutputFrame: outputFrames, inputFrames: 1))
                }
            } else {
                output += samples[frame * channels..<(frame + 1) * channels]
            }
        }
        consumed += samples.count / channels
        return ProcessorOutput(samples: output, dropped: dropped)
    }
}
