import Foundation

/// **Feed-forward wideband compressor with a soft knee.**
///
/// Ported from Android's `Compressor`. Works in the dB domain with a per-sample envelope follower
/// and separate attack/release constants, so reduction builds fast and recovers slowly — the shape
/// speech wants.
///
/// The envelope starts at -96 dB rather than 0. That is Android's initial value and it means the
/// first few milliseconds of a stream are heavily attenuated while the envelope releases up to
/// unity. It is inaudible in place (the limiter's lookahead and the gain smoothing cover it) but it
/// is why a test must warm the compressor before asserting that a quiet signal passes untouched.
public struct Compressor {

    private let thresholdDb: Double
    private let ratio: Double
    private let kneeDb: Double
    private let attackCoeff: Double
    private let releaseCoeff: Double

    private var envelopeDb: Double = -96

    public init(thresholdDb: Float, ratio: Float, attackMs: Float, releaseMs: Float, kneeDb: Float, sampleRate: Double) {
        self.thresholdDb = Double(thresholdDb)
        self.ratio = Double(ratio)
        self.kneeDb = Double(kneeDb)
        attackCoeff = exp(-1.0 / (Double(attackMs) / 1000.0 * sampleRate))
        releaseCoeff = exp(-1.0 / (Double(releaseMs) / 1000.0 * sampleRate))
    }

    public mutating func process(_ input: Float) -> Float {
        let magnitude = abs(input)
        // log10(0) is -inf; silence needs no compression anyway.
        guard magnitude >= 1e-8 else { return input }

        let inputDb = 20.0 * log10(Double(magnitude))
        let halfKnee = kneeDb / 2.0

        let gainReduction: Double
        if kneeDb > 0, inputDb > thresholdDb - halfKnee, inputDb < thresholdDb + halfKnee {
            // In-knee: quadratic interpolation between no reduction and the full ratio.
            let x = inputDb - thresholdDb + halfKnee
            gainReduction = (1.0 / ratio - 1.0) * x * x / (2.0 * kneeDb)
        } else if inputDb > thresholdDb + halfKnee {
            gainReduction = (thresholdDb + (inputDb - thresholdDb) / ratio) - inputDb
        } else {
            gainReduction = 0
        }

        // Branching envelope: attack when the demanded reduction deepens, release when it eases.
        let coeff = gainReduction < envelopeDb ? attackCoeff : releaseCoeff
        envelopeDb = gainReduction + coeff * (envelopeDb - gainReduction)

        return Float(Double(input) * pow(10.0, envelopeDb / 20.0))
    }

    public mutating func reset() {
        envelopeDb = -96
    }
}
