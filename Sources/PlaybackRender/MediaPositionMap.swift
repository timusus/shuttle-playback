import Foundation

/// Which item and media frames a run of output frames carries. A chunk crosses every layer as PCM
/// plus these tags, and a layer that drops or adds frames rewrites them (ADR-0018).
struct SegmentTag: Equatable, Sendable {
    var item: Int
    var mediaStartFrame: Int64
    var frameCount: Int64
}

/// Maps the played output time back to (item, media frame), modelled on media3
/// `DefaultAudioSink.applyMediaPositionParameters` and `applySkipping`.
///
/// Tags are appended in output order, each starting where the last ended, and a tag counts only once
/// the playhead reaches it. Dropped frames and decoder timestamp jumps are a jump in media start
/// between tags, so the position moves when they would have played. media3 credits dropped frames
/// when the processor drops them (`getSkippedOutputFrameCount`), a buffer-depth early.
///
/// Speed is the output's rate over this same timeline (the synchronizer plays media time), so an
/// output second always carries one second of its tag's frames and, unlike media3, there are no
/// speed checkpoints.
///
/// Output time is in seconds rather than frames because each item keeps its native rate across a
/// join. An item id names a queue entry, not a track: a repeated track needs a new id to be reported.
struct MediaPositionMap: Sendable {
    struct Position: Equatable, Sendable {
        var item: Int
        /// At the item's own sample rate.
        var mediaFrame: Int64
    }

    private struct Segment: Sendable {
        var tag: SegmentTag
        var sampleRate: Double
        var start: TimeInterval
        var end: TimeInterval { start + Double(tag.frameCount) / sampleRate }
    }

    private(set) var epochStart: TimeInterval
    private(set) var writtenEnd: TimeInterval
    private var segments: [Segment] = []
    private var reportedItem: Int?

    init(epochStart: TimeInterval = 0) {
        self.epochStart = epochStart
        writtenEnd = epochStart
    }

    /// A flush, seek or auto-flush: everything written is gone and writing restarts at `time`. The
    /// reported item is kept, so re-anchoring inside an item does not report it again.
    mutating func reset(at time: TimeInterval) {
        segments = []
        epochStart = time
        writtenEnd = time
    }

    mutating func append(_ tag: SegmentTag, sampleRate: Double) {
        if let last = segments.last, last.tag.item == tag.item, last.sampleRate == sampleRate,
           last.tag.mediaStartFrame + last.tag.frameCount == tag.mediaStartFrame {
            segments[segments.count - 1].tag.frameCount += tag.frameCount
        } else {
            segments.append(Segment(tag: tag, sampleRate: sampleRate, start: writtenEnd))
        }
        writtenEnd = segments[segments.count - 1].end
    }

    /// The output time being heard, by the `AudioOutput` rule. It never precedes the epoch: just
    /// after a re-anchor the clock reads the anchor while flushed audio is still leaving the hardware.
    func playhead(currentTime: TimeInterval, outputLatency: TimeInterval) -> TimeInterval {
        max(epochStart, currentTime - outputLatency)
    }

    /// Nil until something of this epoch is written. Past the written end it holds there: a starved
    /// output's clock runs on, the position must not.
    func position(at playhead: TimeInterval) -> Position? {
        guard let index = segmentIndex(at: playhead) else { return nil }
        let segment = segments[index]
        let played = Int64(((min(playhead, writtenEnd) - segment.start) * segment.sampleRate).rounded())
        return Position(
            item: segment.tag.item,
            mediaFrame: segment.tag.mediaStartFrame + min(max(played, 0), segment.tag.frameCount)
        )
    }

    /// Moves to `playhead` and returns the items it entered since the last call, in order, a
    /// zero-frame item included. Positions behind `playhead` are forgotten.
    mutating func advance(to playhead: TimeInterval) -> [Int] {
        guard let index = segmentIndex(at: playhead) else { return [] }
        var entered: [Int] = []
        for segment in segments[...index] where segment.tag.item != reportedItem {
            entered.append(segment.tag.item)
            reportedItem = segment.tag.item
        }
        segments.removeFirst(index)
        return entered
    }

    // A segment counts from half a frame before its start, the nearest frame, so clock rounding
    // never reports a join a frame late.
    private func segmentIndex(at playhead: TimeInterval) -> Int? {
        segments.lastIndex { playhead >= $0.start - 0.5 / $0.sampleRate } ?? segments.indices.first
    }
}
