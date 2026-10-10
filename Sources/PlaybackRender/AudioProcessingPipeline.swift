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
        var endQueued = false

        init(_ processor: AudioProcessor, outputFormat: PCMFormat) {
            self.processor = processor
            self.outputFormat = outputFormat
        }
    }

    private let processors: [AudioProcessor]
    /// The input each processor last accepted, to stage it again when a later one rejects a format.
    private var stagedInputs: [PCMFormat?]
    private var pendingActive: [(processor: AudioProcessor, output: PCMFormat)] = []
    private var pendingInput: PCMFormat?
    private var inputFormat: PCMFormat?
    private var stages: [Stage] = []
    /// Input held with no active stage, handed over unchanged.
    private var passThrough: [TaggedChunk] = []
    private var inputEnded = false

    init(_ processors: [AudioProcessor]) {
        self.processors = processors
        stagedInputs = Array(repeating: nil, count: processors.count)
    }

    /// Stages every processor for `input` and returns the chain's output format. Nothing changes
    /// until `flush`, so audio already queued keeps its old format. On a throw nothing is staged.
    @discardableResult
    func configure(_ input: PCMFormat) throws -> PCMFormat {
        var active: [(AudioProcessor, PCMFormat)] = []
        var inputs: [PCMFormat] = []
        var format = input
        do {
            for processor in processors {
                inputs.append(format)
                let output = try processor.configure(format)
                guard processor.isActive else { continue }
                guard output.sampleRate == format.sampleRate else {
                    throw AudioProcessingError.sampleRateChanged(from: format, to: output)
                }
                active.append((processor, output))
                format = output
            }
        } catch {
            // Processors only stage a format, so staging the old one again undoes it.
            for (processor, old) in zip(processors, stagedInputs).prefix(inputs.count) {
                if let old {
                    _ = try? processor.configure(old)
                } else {
                    processor.reset()
                }
            }
            throw error
        }
        stagedInputs = inputs
        pendingActive = active
        pendingInput = input
        return format
    }

    /// Applies the staged configuration and drops everything buffered.
    func flush() {
        inputFormat = pendingInput
        stages = pendingActive.map { Stage($0.processor, outputFormat: $0.output) }
        stages.forEach { $0.processor.flush() }
        passThrough = []
        inputEnded = false
    }

    /// False with no active stage: input then comes out of `getOutput` unchanged.
    var isOperational: Bool { !stages.isEmpty }

    func queueInput(_ chunk: TaggedChunk) {
        precondition(chunk.format == inputFormat, "input format changed without configure and flush")
        guard let first = stages.first else {
            passThrough.append(chunk)
            return
        }
        accept(chunk, into: first)
    }

    /// Runs every stage over what the one before produced; nil when nothing came out, not even a tag.
    func getOutput() -> TaggedChunk? {
        guard !stages.isEmpty else {
            return passThrough.isEmpty ? nil : passThrough.removeFirst()
        }
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
        inputEnded = true
        guard let first = stages.first, !first.endQueued else { return }
        first.endQueued = true
        first.processor.queueEndOfStream()
    }

    var isEnded: Bool {
        guard let last = stages.last else { return inputEnded && passThrough.isEmpty }
        return last.processor.isEnded
    }

    func reset() {
        processors.forEach { $0.reset() }
        stagedInputs = Array(repeating: nil, count: processors.count)
        pendingActive = []
        pendingInput = nil
        inputFormat = nil
        stages = []
        passThrough = []
        inputEnded = false
    }

    private func accept(_ chunk: TaggedChunk, into stage: Stage) {
        stage.pending.append(contentsOf: chunk.tags.map { ($0, false) })
        stage.processor.queueInput(chunk.samples)
    }

    private func drain(_ stage: Stage) -> TaggedChunk {
        let output = stage.processor.getOutput()
        let frames = Int64(output.samples.count / stage.outputFormat.channelCount)
        let tags = rewrite(stage, outputFrames: frames, dropped: output.dropped)
        if stage.processor.isEnded {
            precondition(stage.pending.isEmpty, "\(stage.processor) ended without handing over all its input")
        }
        return TaggedChunk(samples: output.samples, format: stage.outputFormat, tags: tags)
    }

    /// Output frames map one to one, in order, onto the stage's input minus the dropped runs. A
    /// zero-frame tag passes through where it falls, and a tag dropped whole leaves one at its end
    /// when its item has no frames in this output, so the item is still reported crossed.
    private func rewrite(_ stage: Stage, outputFrames: Int64, dropped: [DroppedFrames]) -> [SegmentTag] {
        var out: [SegmentTag] = []
        var droppedWhole: Set<Int> = []

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
                stage.pending.removeFirst()
                if !head.emitted, !(keep && taken > 0) {
                    if head.tag.frameCount > 0 { droppedWhole.insert(out.count) }
                    out.append(SegmentTag(item: tag.item, mediaStartFrame: tag.mediaStartFrame, frameCount: 0))
                }
            }
            precondition(remaining == 0, "\(stage.processor) output or dropped more frames than its input")
        }

        var cursor: Int64 = 0
        for drop in dropped {
            let at = Int64(drop.atOutputFrame)
            precondition(at >= cursor && at <= outputFrames && drop.inputFrames >= 0,
                         "\(stage.processor) reported a drop out of order or outside its output: \(drop)")
            consume(at - cursor, keep: true)
            cursor = at
            consume(drop.inputFrames, keep: false)
        }
        consume(outputFrames - cursor, keep: true)

        // An item with frames here is reported by them; one zero-frame tag per item otherwise.
        var reported = Set(out.filter { $0.frameCount > 0 }.map(\.item))
        return out.enumerated().compactMap { index, tag in
            droppedWhole.contains(index) && !reported.insert(tag.item).inserted ? nil : tag
        }
    }
}
