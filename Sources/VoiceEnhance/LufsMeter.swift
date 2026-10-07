import Foundation

/// **Streaming loudness, BS.1770, the number the makeup gain aims at.**
///
/// Ported from Android's `LufsMeter`. K-weighted energy is accumulated into 400 ms
/// non-overlapping blocks (the full spec's 75% overlap is not worth its cost at the ±1 LU accuracy
/// podcast normalisation needs, and Android made the same call, so the two platforms must make it
/// the same way or they aim at different targets).
///
/// ``shortTermLufs()`` — the last 30 blocks, ungated — is what drives the gain, exactly as on
/// Android. ``integratedLufs()`` applies the absolute (-70 LUFS) and relative (-10 LU) gates and is
/// the whole-stream figure.
public struct LufsMeter {

    /// The floor both readings return when nothing has passed the gates, and the level below which
    /// the processor holds unity gain rather than trying to lift silence.
    public static let gateFloorLufs: Float = -70

    private var kWeighting: KWeightingFilter
    private let blockSize: Int

    private var blockEnergyAccumulator: Double = 0
    private var blockSampleCount: Int = 0
    private var blockEnergies: [Double] = []

    /// Short-term window, in 400 ms blocks. 30 blocks is Android's number.
    private let shortTermWindowBlocks = 30
    private let absoluteGateThreshold = pow(10.0, -70.0 / 10.0)

    public init(sampleRate: Double) {
        kWeighting = KWeightingFilter(sampleRate: sampleRate)
        // A block of zero samples divides by zero and makes every reading NaN, which propagates
        // into the gain and then into silent output. Android guards the same case by refusing to
        // configure below 8 kHz; guard it here too so the type is safe on its own.
        blockSize = max(Int(sampleRate * 0.4), 1)
    }

    public mutating func process(_ samples: [Float], count: Int? = nil) {
        let length = count ?? samples.count
        for i in 0..<length {
            let weighted = Double(kWeighting.process(samples[i]))
            blockEnergyAccumulator += weighted * weighted
            blockSampleCount += 1
            if blockSampleCount >= blockSize {
                blockEnergies.append(blockEnergyAccumulator / Double(blockSize))
                blockEnergyAccumulator = 0
                blockSampleCount = 0
                // Bounded: an episode is hours long and every block is a Double kept forever
                // otherwise. Only the last `shortTermWindowBlocks` drive the gain, and the
                // integrated figure over a rolling hour is as good as over the whole file.
                if blockEnergies.count > Self.maxRetainedBlocks {
                    blockEnergies.removeFirst(blockEnergies.count - Self.maxRetainedBlocks)
                }
            }
        }
    }

    /// 9000 blocks is one hour at 400 ms.
    private static let maxRetainedBlocks = 9000

    /// Gated whole-stream loudness: absolute gate at -70 LUFS, then relative gate 10 LU below the
    /// ungated mean.
    public func integratedLufs() -> Float {
        guard !blockEnergies.isEmpty else { return Self.gateFloorLufs }

        let aboveAbsolute = blockEnergies.filter { $0 >= absoluteGateThreshold }
        guard !aboveAbsolute.isEmpty else { return Self.gateFloorLufs }

        let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeThreshold = ungatedMean * pow(10.0, -10.0 / 10.0)

        let aboveRelative = aboveAbsolute.filter { $0 >= relativeThreshold }
        guard !aboveRelative.isEmpty else { return Self.gateFloorLufs }

        let gatedMean = aboveRelative.reduce(0, +) / Double(aboveRelative.count)
        return Float(-0.691 + 10.0 * log10(max(gatedMean, .leastNormalMagnitude)))
    }

    /// Ungated loudness over the last 30 blocks (~12 s). This is what the gain follows.
    public func shortTermLufs() -> Float {
        guard !blockEnergies.isEmpty else { return Self.gateFloorLufs }
        let recent = blockEnergies.suffix(shortTermWindowBlocks)
        let meanSquare = recent.reduce(0, +) / Double(recent.count)
        guard meanSquare > 0 else { return Self.gateFloorLufs }
        return Float(-0.691 + 10.0 * log10(meanSquare))
    }

    public mutating func reset() {
        kWeighting.reset()
        blockEnergyAccumulator = 0
        blockSampleCount = 0
        blockEnergies.removeAll(keepingCapacity: true)
    }
}
