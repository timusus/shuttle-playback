import Foundation

/// **Voice Boost: Android's DSP chain, not a system effect.**
///
/// The Android processor (`playback/.../audio/VoiceEnhanceAudioProcessor.kt`) is the spec, and every
/// number below is taken from it rather than chosen here:
///
/// ```
/// LufsMeter -> gain(smoothed, toward -14 LUFS) -> highpass 80 Hz Q 0.707
///           -> peaking 2500 Hz +3.5 dB Q 1.0
///           -> Compressor(-18 dB, 3:1, 5 ms, 100 ms, 6 dB knee)
///           -> LookaheadLimiter(-1 dBFS, 5 ms, 100 ms)
/// ```
///
/// An `AVAudioUnitEQ` plus a system dynamics processor would have been less code and a different
/// sound: the two platforms would then diverge on the one feature listeners describe by ear. Porting
/// the chain is the only way "Voice Boost" means the same thing on both.
///
/// # Interleaved in, interleaved out
///
/// Same block interface as ``SilenceGate`` — `[Float]` in, `[Float]` out, no engine, no session, no
/// clock — for the same reason: it is the only way any of this is testable on a machine whose
/// CoreAudio cannot open an output device.
///
/// The chain is **mono internally**, exactly as Android's is: frames are downmixed, processed once,
/// and the result written back to every channel. Podcast speech is centre-panned and a per-channel
/// chain would have two independently-moving compressors wandering the image; Android collapses it
/// and so does this. A stereo input therefore comes out dual-mono when Voice Boost is on. That is
/// the feature, not a bug, and it is why the toggle exists.
///
/// # Bypass
///
/// ``process(_:)`` is only reached when the stage is on. Off, the caller does not call it at all, so
/// bypass is bit-exact by construction; ``reset()`` clears every filter's memory so re-enabling
/// mid-episode starts clean rather than with a delay line full of pre-bypass audio. A seek uses
/// ``flush()`` instead, which spares the loudness history — the same split Android draws between
/// its `onReset` and its `onFlush`.
public final class VoiceEnhanceProcessor {

    /// The loudness the makeup gain aims at.
    public static let targetLufs: Float = -14
    /// Gain bounds. Shared by the running gain and any seed so the two cannot drift apart.
    public static let minGainDb: Float = -20
    public static let maxGainDb: Float = 30
    /// Per-sample smoothing of the gain toward its target. 0.999 is Android's; at 48 kHz it is a
    /// ~21 ms time constant, fast enough to follow a level change and slow enough not to pump.
    public static let gainSmoothingFactor: Double = 0.999
    /// Lowest sample rate the chain is built for. Below it the meter's 400 ms block and the
    /// limiter's lookahead window both degenerate. Android refuses the same way.
    public static let minimumSampleRate: Double = 8000

    public private(set) var sampleRate: Double = 0
    public private(set) var channelCount: Int = 0

    /// False when ``configure(sampleRate:channelCount:)`` was handed a format the chain cannot
    /// process. ``process(_:)`` then passes audio through untouched: inert beats silent.
    public private(set) var isConfigurationValid = false

    private var lufsMeter: LufsMeter?
    private var highPass: Biquad?
    private var presenceEq: Biquad?
    private var compressor: Compressor?
    private var limiter: LookaheadLimiter?

    /// Linear gain currently applied, smoothed toward the target every sample.
    private var currentGain: Float = 1.0

    /// Last short-term loudness measured, for the diagnostics line. `-70` before the first block.
    public private(set) var measuredLufs: Float = LufsMeter.gateFloorLufs
    /// Last gain actually applied, in dB, for the diagnostics line.
    public private(set) var appliedGainDb: Float = 0

    private var monoScratch: [Float] = []

    public init(sampleRate: Double, channelCount: Int) {
        configure(sampleRate: sampleRate, channelCount: channelCount)
    }

    /// Build (or rebuild) the chain for a format. Every coefficient depends on the sample rate, so
    /// this is the only place they are computed and a format change must come back through here.
    public func configure(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        isConfigurationValid = sampleRate >= Self.minimumSampleRate && channelCount > 0
        guard isConfigurationValid else {
            lufsMeter = nil
            highPass = nil
            presenceEq = nil
            compressor = nil
            limiter = nil
            return
        }

        lufsMeter = LufsMeter(sampleRate: sampleRate)
        highPass = .highPass(frequency: 80, sampleRate: sampleRate, q: 0.707)
        presenceEq = .peaking(frequency: 2500, sampleRate: sampleRate, gainDb: 3.5, q: 1.0)
        compressor = Compressor(
            thresholdDb: -18,
            ratio: 3,
            attackMs: 5,
            releaseMs: 100,
            kneeDb: 6,
            sampleRate: sampleRate
        )
        limiter = LookaheadLimiter(ceilingDb: -1, attackMs: 5, releaseMs: 100, sampleRate: sampleRate)
        currentGain = 1.0
        measuredLufs = LufsMeter.gateFloorLufs
        appliedGainDb = 0
    }

    /// Push one buffer of interleaved samples through the chain. Output is the same length as input.
    ///
    /// A sample count that is not a whole number of frames is returned untouched rather than
    /// half-processed: a malformed buffer must never be able to mangle playback.
    public func process(_ samples: [Float]) -> [Float] {
        // Force-unwrapped rather than bound with `guard var`: binding copies each struct, and a
        // copy of the meter's block history is a memcpy per buffer on the decode queue. `isReady`
        // is only true when all five exist.
        guard isReady, !samples.isEmpty, samples.count % channelCount == 0 else { return samples }

        let frameCount = samples.count / channelCount

        if monoScratch.count < frameCount {
            monoScratch = [Float](repeating: 0, count: frameCount)
        }
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var sum: Float = 0
            for channel in 0..<channelCount { sum += samples[base + channel] }
            monoScratch[frame] = sum / Float(channelCount)
        }

        lufsMeter!.process(monoScratch, count: frameCount)
        let shortTerm = lufsMeter!.shortTermLufs()

        let targetGain: Float
        if !shortTerm.isFinite {
            // Defence in depth. `configure` should make this impossible; if it ever happens, unity
            // keeps audio audible rather than letting NaN reach the PCM, where it becomes silence.
            targetGain = 1.0
        } else if shortTerm <= LufsMeter.gateFloorLufs {
            // Nothing worth lifting: gating silence up would raise the noise floor between words.
            targetGain = 1.0
        } else {
            let gainDb = min(max(Self.targetLufs - shortTerm, Self.minGainDb), Self.maxGainDb)
            targetGain = pow(10, gainDb / 20)
        }

        var output = samples
        let smoothing = Self.gainSmoothingFactor
        for frame in 0..<frameCount {
            currentGain = Float(smoothing * Double(currentGain) + (1.0 - smoothing) * Double(targetGain))

            var sample = monoScratch[frame] * currentGain
            sample = highPass!.process(sample)
            sample = presenceEq!.process(sample)
            sample = compressor!.process(sample)
            sample = limiter!.process(sample)

            let base = frame * channelCount
            for channel in 0..<channelCount { output[base + channel] = sample }
        }

        measuredLufs = shortTerm
        appliedGainDb = 20 * log10(max(currentGain, 1e-8))

        return output
    }

    /// Every stage exists and the format was accepted.
    private var isReady: Bool {
        isConfigurationValid && lufsMeter != nil && highPass != nil && presenceEq != nil
            && compressor != nil && limiter != nil
    }

    /// Whole-stream loudness so far, gated per BS.1770.
    public var integratedLufs: Float { lufsMeter?.integratedLufs() ?? LufsMeter.gateFloorLufs }

    /// **Seek: drop the filter state, keep the loudness history.**
    ///
    /// Android's `onFlush` is the spec — it resets the highpass, presence EQ, compressor, limiter
    /// and current gain, and deliberately leaves the LUFS meter alone. A delay line or a compressor
    /// envelope from before a seek describes audio that is no longer adjacent to what comes next,
    /// so carrying either across is a click. Loudness is not like that: it is a property of the
    /// episode, and a seek does not change the episode. Clearing it would only spend the first
    /// seconds after every seek reconverging the makeup gain, audibly.
    public func flush() {
        highPass?.reset()
        presenceEq?.reset()
        compressor?.reset()
        limiter?.reset()
        currentGain = 1.0
        appliedGainDb = 0
    }

    /// Clear every filter's memory *and* the loudness history, and return the gain to unity.
    ///
    /// For a new episode or a rebuilt chain — turning the preference back on mid-episode, or a
    /// format change through ``configure(sampleRate:channelCount:)``. Not for a seek: see
    /// ``flush()``.
    public func reset() {
        highPass?.reset()
        presenceEq?.reset()
        compressor?.reset()
        limiter?.reset()
        lufsMeter?.reset()
        currentGain = 1.0
        measuredLufs = LufsMeter.gateFloorLufs
        appliedGainDb = 0
    }
}
