import Foundation

/// **ITU BS.1770 K-weighting, two cascaded biquads.**
///
/// Ported from Android's `KWeightingFilter`, coefficients unchanged (they come from libebur128 /
/// BS.1770-4 and are derived per sample rate, not hard-coded for 48 kHz).
///
/// - Stage 1: head-model high shelf, about +4 dB above 1.7 kHz.
/// - Stage 2: RLB high-pass, rolling off below ~40 Hz, so infrasonic energy does not count as
///   loudness.
public struct KWeightingFilter {

    private var stage1: Biquad
    private var stage2: Biquad

    public init(sampleRate: Double) {
        // Stage 1 — head-model shelving filter.
        let f0Stage1 = 1681.974450955533
        let gainDb = 3.999843853973347
        let qStage1 = 0.7071752369554196

        let k1 = tan(Double.pi * f0Stage1 / sampleRate)
        let vh = pow(10.0, gainDb / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0Stage1 = 1.0 + k1 / qStage1 + k1 * k1

        stage1 = Biquad(
            b0: (vh + vb * k1 / qStage1 + k1 * k1) / a0Stage1,
            b1: 2.0 * (k1 * k1 - vh) / a0Stage1,
            b2: (vh - vb * k1 / qStage1 + k1 * k1) / a0Stage1,
            a1: 2.0 * (k1 * k1 - 1.0) / a0Stage1,
            a2: (1.0 - k1 / qStage1 + k1 * k1) / a0Stage1
        )

        // Stage 2 — RLB high-pass filter.
        let f0Stage2 = 38.13547087602444
        let qStage2 = 0.5003270373238773

        let k2 = tan(Double.pi * f0Stage2 / sampleRate)
        let a0Stage2 = 1.0 + k2 / qStage2 + k2 * k2

        stage2 = Biquad(
            b0: 1.0 / a0Stage2,
            b1: -2.0 / a0Stage2,
            b2: 1.0 / a0Stage2,
            a1: 2.0 * (k2 * k2 - 1.0) / a0Stage2,
            a2: (1.0 - k2 / qStage2 + k2 * k2) / a0Stage2
        )
    }

    public mutating func process(_ sample: Float) -> Float {
        stage2.process(stage1.process(sample))
    }

    public mutating func reset() {
        stage1.reset()
        stage2.reset()
    }
}
