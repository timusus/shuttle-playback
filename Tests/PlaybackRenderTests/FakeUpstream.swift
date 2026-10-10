@testable import PlaybackRender

/// Items of ramp PCM, so a test can read back exactly which frames were heard: frame `f` of item `i`
/// is `sample(i, f)` on every channel. A zero-frame item supplies an empty chunk with its tag.
final class FakeUpstream: FeederUpstream {
    struct Item {
        var id: Int
        var frames: Int64
        var format: PCMFormat
    }

    let items: [Item]
    let chunkFrames: Int64
    /// Chunks it supplies before answering `.pending`; nil is unlimited.
    var available: Int?
    private(set) var pulls = 0
    private(set) var resupplies: [MediaPositionMap.Position] = []
    private var index = 0
    private var frame: Int64 = 0

    init(_ items: [Item], chunkFrames: Int64) {
        self.items = items
        self.chunkFrames = chunkFrames
    }

    static func sample(_ item: Int, _ frame: Int64) -> Float { Float(item * 1000) + Float(frame) }

    func pull() -> UpstreamSupply {
        pulls += 1
        if let available {
            guard available > 0 else { return .pending }
            self.available = available - 1
        }
        guard index < items.count else { return .ended }
        let item = items[index]
        let count = min(chunkFrames, item.frames - frame)
        let samples = (frame..<(frame + count)).flatMap {
            [Float](repeating: Self.sample(item.id, $0), count: item.format.channelCount)
        }
        let tag = SegmentTag(item: item.id, mediaStartFrame: frame, frameCount: count)
        frame += count
        if frame >= item.frames { (index, frame) = (index + 1, 0) }
        return .chunk(TaggedChunk(samples: samples, format: item.format, tags: [tag]))
    }

    func resupply(from position: MediaPositionMap.Position) {
        resupplies.append(position)
        index = items.firstIndex { $0.id == position.item }!
        frame = position.mediaFrame
        if frame >= items[index].frames { (index, frame) = (index + 1, 0) }
    }
}
