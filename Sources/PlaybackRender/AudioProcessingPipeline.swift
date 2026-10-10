import Foundation

/// An ordered chain of processors over `TaggedChunk`s, modelled on media3 `AudioProcessingPipeline`.
/// It is the one place tags are rewritten: each stage's dropped frames become a jump in
/// `mediaStartFrame`, so the tags of every output chunk still sum to its frame count (ADR-0018).
final class AudioProcessingPipeline {
    private final class Stage {
        let processor: AudioProcessor
        let outputFormat: PCMFormat
        /// Input tags not yet matched to output, with whether any of their frames came out.
        var pending: [(tag: SegmentTag, emitted: Bool)] = []
        /// Where the last consumed tag ended, for frames a stage adds beyond its input.
        var lastEnd: SegmentTag?
        var endQueued = false

        init(_ processor: AudioProcessor, outputFormat: PCMFormat) {
            self.processor = processor
            self.outputFormat = outputFormat
        }
    }

    private let processors: [AudioProcessor]
    private var pendingActive: [(processor: AudioProcessor, output: PCMFormat)] = []
    private var pendingInput: PCMFormat?
    private var inputFormat: PCMFormat?
    private var stages: [Stage] = []

    init(_ processors: [AudioProcessor]) {
        self.processors = processors
    }

    /// Stages every processor for `input` and returns the chain's output format. Nothing changes
    /// until `flush`, so audio already queued keeps its old format.
    @discardableResult
    func configure(_ input: PCMFormat) throws -> PCMFormat {
        var active: [(AudioProcessor, PCMFormat)] = []
        var format = input
        for processor in processors {
            let output = try processor.configure(format)
            guard processor.isActive else { continue }
            guard output.sampleRate == format.sampleRate else {
                throw AudioProcessingError.sampleRateChanged(from: format, to: output)
            }
            active.append((processor, output))
            format = output
        }
        pendingActive = active
        pendingInput = input
        return format
    }

    /// Applies the staged configuration and drops everything buffered.
    func flush() {
        inputFormat = pendingInput
        stages = pendingActive.map { Stage($0.processor, outputFormat: $0.output) }
        stages.forEach { $0.processor.flush() }
    }

    /// False with no active stage: the caller then writes input straight to the output.
    var isOperational: Bool { !stages.isEmpty }

    func queueInput(_ chunk: TaggedChunk) {
        guard let first = stages.first else { return }
        precondition(chunk.format == inputFormat, "input format changed without configure and flush")
        accept(chunk, into: first)
    }

    /// Runs every stage over what the one before produced; nil when nothing came out, not even a tag.
    func getOutput() -> TaggedChunk? {
        var carried: TaggedChunk?
        for (index, stage) in stages.enumerated() {
            if let carried, index > 0 { accept(carried, into: stage) }
            if index > 0, stages[index - 1].processor.isEnded, !stage.endQueued {
                stage.endQueued = true
                stage.processor.queueEndOfStream()
            }
            carried = drain(stage)
        }
        guard let carried, !carried.tags.isEmpty || !carried.samples.isEmpty else { return nil }
        return carried
    }

    func queueEndOfStream() {
        guard let first = stages.first, !first.endQueued else { return }
        first.endQueued = true
        first.processor.queueEndOfStream()
    }

    var isEnded: Bool { stages.last?.processor.isEnded ?? false }

    func reset() {
        processors.forEach { $0.reset() }
        pendingActive = []
        pendingInput = nil
        inputFormat = nil
        stages = []
    }

    private func accept(_ chunk: TaggedChunk, into stage: Stage) {
        stage.pending.append(contentsOf: chunk.tags.map { ($0, false) })
        stage.processor.queueInput(chunk.samples)
    }

    private func drain(_ stage: Stage) -> TaggedChunk {
        let output = stage.processor.getOutput()
        let frames = Int64(output.samples.count / stage.outputFormat.channelCount)
        let tags = rewrite(stage, outputFrames: frames, dropped: output.dropped)
        return TaggedChunk(samples: output.samples, format: stage.outputFormat, tags: tags)
    }

    /// Output frames map one to one, in order, onto the stage's input minus the dropped runs. A
    /// zero-frame tag passes through where it falls, and a tag dropped whole leaves one at its end
    /// so its item is still reported crossed.
    private func rewrite(_ stage: Stage, outputFrames: Int64, dropped: [DroppedFrames]) -> [SegmentTag] {
        var out: [SegmentTag] = []

        func consume(_ count: Int64, keep: Bool) {
            var remaining = count
            while let head = stage.pending.first, remaining > 0 || head.tag.frameCount == 0 {
                var tag = head.tag
                let taken = min(remaining, tag.frameCount)
                remaining -= taken
                if keep, taken > 0 {
                    if let last = out.last, last.item == tag.item, last.mediaStartFrame + last.frameCount == tag.mediaStartFrame {
                        out[out.count - 1].frameCount += taken
                    } else {
                        out.append(SegmentTag(item: tag.item, mediaStartFrame: tag.mediaStartFrame, frameCount: taken))
                    }
                    stage.pending[0].emitted = true
                }
                tag.mediaStartFrame += taken
                tag.frameCount -= taken
                if tag.frameCount > 0 {
                    stage.pending[0].tag = tag
                    return
                }
                let emitted = stage.pending[0].emitted
                stage.pending.removeFirst()
                stage.lastEnd = tag
                if !emitted {
                    out.append(SegmentTag(item: tag.item, mediaStartFrame: tag.mediaStartFrame, frameCount: 0))
                }
            }
            // Frames the stage added: credited to where the last input ended.
            if keep, remaining > 0, stage.pending.isEmpty, let end = stage.lastEnd {
                if let last = out.last, last.item == end.item, last.mediaStartFrame + last.frameCount == end.mediaStartFrame {
                    out[out.count - 1].frameCount += remaining
                } else {
                    out.append(SegmentTag(item: end.item, mediaStartFrame: end.mediaStartFrame, frameCount: remaining))
                }
                stage.lastEnd?.mediaStartFrame += remaining
            }
        }

        var cursor: Int64 = 0
        for drop in dropped.sorted(by: { $0.atOutputFrame < $1.atOutputFrame }) {
            let at = Int64(drop.atOutputFrame)
            consume(at - cursor, keep: true)
            cursor = at
            consume(drop.inputFrames, keep: false)
        }
        consume(outputFrames - cursor, keep: true)
        return out
    }
}
