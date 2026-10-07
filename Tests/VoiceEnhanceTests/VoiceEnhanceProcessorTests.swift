import Foundation
import Testing
@testable import VoiceEnhance

/// **Voice Boost's arithmetic, and only the arithmetic.**
///
/// Same constraint as ``SilenceGateTests``: this machine's CoreAudio cannot open an output device
/// and the simulator's clock does not advance, so nothing here can be heard. What can be pinned is
/// the DSP — which is the whole feature, because "Voice Boost" is a port of Android's chain
/// (`playback/.../audio/VoiceEnhanceAudioProcessor.kt` and its `dsp/` neighbours), not an
/// `AVAudioUnitEQ` approximation of it. If these numbers drift, the two platforms stop sounding the
/// same and nobody finds out until a listener says so.
///
/// The expected values below were measured against this port and cross-checked against the Kotlin
/// formulas they came from; tolerances are wide enough to survive a `Float`/`Double` reshuffle and
/// tight enough that a wrong coefficient fails.

// MARK: - Signal helpers

private let testSampleRate: Double = 48000

private func sine(frequency: Double, amplitude: Float, frames: Int, sampleRate: Double = testSampleRate) -> [Float] {
    (0..<frames).map { Float(Double(amplitude) * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sum / Double(samples.count)).squareRoot()
}

private func dB(_ ratio: Double) -> Double { 20 * log10(ratio) }

/// Gain of a filter at a frequency, measured on the steady state: the first half of the tone is
/// discarded so the filter's start-up transient is not in the answer.
private func steadyStateGainDb(_ process: (Float) -> Float, frequency: Double, frames: Int = 48000) -> Double {
    let input = sine(frequency: frequency, amplitude: 0.5, frames: frames)
    let output = input.map(process)
    let tail = frames / 2
    return dB(rms(output[tail...]) / rms(input[tail...]))
}

@Suite("Voice Boost — biquad")
struct BiquadTests {

    @Test("The 80 Hz high-pass kills infrasonics and leaves speech alone")
    func highPassShape() {
        var low = Biquad.highPass(frequency: 80, sampleRate: testSampleRate, q: 0.707)
        var mid = Biquad.highPass(frequency: 80, sampleRate: testSampleRate, q: 0.707)

        let at20Hz = steadyStateGainDb({ low.process($0) }, frequency: 20)
        let at1kHz = steadyStateGainDb({ mid.process($0) }, frequency: 1000)

        // Two poles at 80 Hz put 20 Hz two octaves down: about -24 dB.
        #expect(at20Hz < -20)
        // A 1 kHz tone is more than three octaves above the corner and must be untouched.
        #expect(abs(at1kHz) < 0.1)
        #expect(at1kHz - at20Hz > 20)
    }

    @Test("The presence peak lifts 2.5 kHz by 3.5 dB and nothing else")
    func peakingShape() {
        var atCentre = Biquad.peaking(frequency: 2500, sampleRate: testSampleRate, gainDb: 3.5, q: 1.0)
        var wellBelow = Biquad.peaking(frequency: 2500, sampleRate: testSampleRate, gainDb: 3.5, q: 1.0)

        let centre = steadyStateGainDb({ atCentre.process($0) }, frequency: 2500)
        let below = steadyStateGainDb({ wellBelow.process($0) }, frequency: 100)

        #expect(abs(centre - 3.5) < 0.1)
        // Q of 1.0 is a narrow band; 100 Hz is far outside it.
        #expect(abs(below) < 0.2)
    }

    @Test("Reset clears the delay line")
    func resetClearsState() {
        var filter = Biquad.highPass(frequency: 80, sampleRate: testSampleRate, q: 0.707)
        let impulse: [Float] = [1] + [Float](repeating: 0, count: 63)
        let first = impulse.map { filter.process($0) }
        filter.reset()
        let second = impulse.map { filter.process($0) }
        #expect(first == second)
    }
}

@Suite("Voice Boost — compressor")
struct CompressorTests {

    private func makeCompressor() -> Compressor {
        Compressor(thresholdDb: -18, ratio: 3, attackMs: 5, releaseMs: 100, kneeDb: 6, sampleRate: testSampleRate)
    }

    /// The envelope starts at -96 dB (Android's initial value), so anything asserted about the
    /// steady state has to be asserted after the envelope has settled. One second is ten release
    /// time constants.
    private func settled(_ compressor: inout Compressor, level: Float) -> Float {
        var last: Float = 0
        for _ in 0..<Int(testSampleRate) { last = compressor.process(level) }
        return last
    }

    @Test("Above the knee, reduction follows the 3:1 ratio")
    func compressesAboveThreshold() {
        var compressor = makeCompressor()
        // -6 dBFS: 12 dB above the -18 dB threshold and clear of the 6 dB knee.
        let output = settled(&compressor, level: 0.5)
        let reductionDb = dB(Double(output / 0.5))
        // 3:1 on 12 dB of excess passes 4 dB, so 8 dB is removed.
        #expect(abs(reductionDb - -8.0) < 0.3)
    }

    @Test("Below the knee, the signal is untouched")
    func passesBelowThreshold() {
        var compressor = makeCompressor()
        // -26 dBFS: below the threshold and below the knee's lower edge (-21 dB).
        let output = settled(&compressor, level: 0.05)
        #expect(abs(Double(output / 0.05) - 1.0) < 0.01)
    }

    @Test("Reset returns the envelope to its initial state")
    func resetRestoresInitialEnvelope() {
        var compressor = makeCompressor()
        let firstSample = compressor.process(0.5)
        _ = settled(&compressor, level: 0.5)
        compressor.reset()
        #expect(compressor.process(0.5) == firstSample)
    }
}

@Suite("Voice Boost — limiter")
struct LookaheadLimiterTests {

    @Test("Nothing leaves above the -1 dBFS ceiling")
    func holdsCeiling() {
        var limiter = LookaheadLimiter(ceilingDb: -1, attackMs: 5, releaseMs: 100, sampleRate: testSampleRate)
        // +6 dB of headroom over full scale — the case the limiter exists for.
        let burst = sine(frequency: 500, amplitude: 2.0, frames: 48000)

        var peak: Float = 0
        for sample in burst { peak = max(peak, abs(limiter.process(sample))) }
        for sample in limiter.flush() { peak = max(peak, abs(sample)) }

        let ceiling = Float(pow(10.0, -1.0 / 20.0))
        // A hair of tolerance for the Float round trip, far below the 0.9 dB that would mean the
        // ceiling was not being enforced at all.
        #expect(peak <= ceiling * 1.001)
        // And it is actually limiting, not muting.
        #expect(peak > ceiling * 0.9)
    }

    @Test("A signal already under the ceiling passes at unity, just delayed")
    func passesQuietSignal() {
        var limiter = LookaheadLimiter(ceilingDb: -1, attackMs: 5, releaseMs: 100, sampleRate: testSampleRate)
        let input = sine(frequency: 500, amplitude: 0.2, frames: 4800)
        let output = input.map { limiter.process($0) }
        // The first `lookaheadSamples` are the empty delay line; compare the steady state.
        #expect(abs(dB(rms(output[2400...]) / rms(input[2400...]))) < 0.01)
    }

    /// The sliding-window maximum is a ring-buffer deque because the `Array` it replaced shifted
    /// every remaining entry on each front-trim: per-sample cost that grows with the window, on the
    /// decode queue. Ten seconds of hot audio at 48 kHz is 480k samples — a wall-clock bound of one
    /// second is loose enough not to flake on a busy simulator and tight enough that a return to
    /// O(n) fails it, while the ceiling assertion pins the output as unchanged.
    @Test("Ten seconds of loud audio limits correctly, and fast")
    func longBufferHoldsCeilingQuickly() {
        var limiter = LookaheadLimiter(ceilingDb: -1, attackMs: 5, releaseMs: 100, sampleRate: testSampleRate)
        let input = sine(frequency: 500, amplitude: 2.0, frames: Int(testSampleRate) * 10)

        let started = Date()
        var peak: Float = 0
        for sample in input { peak = max(peak, abs(limiter.process(sample))) }
        for sample in limiter.flush() { peak = max(peak, abs(sample)) }
        let elapsed = Date().timeIntervalSince(started)

        let ceiling = Float(pow(10.0, -1.0 / 20.0))
        #expect(peak <= ceiling * 1.001)
        #expect(peak > ceiling * 0.9)
        #expect(elapsed < 1.0, "480k samples took \(elapsed)s; the window trim is back to O(n)")
    }
}

@Suite("Voice Boost — loudness meter")
struct LufsMeterTests {

    @Test("A -20 dBFS sine reads close to its BS.1770 loudness")
    func measuresSine() {
        var meter = LufsMeter(sampleRate: testSampleRate)
        // Peak -20 dBFS, so RMS is -23 dBFS; K-weighting adds about +1 dB at 1 kHz and BS.1770
        // subtracts the 0.691 offset, landing near -23.0 LUFS.
        meter.process(sine(frequency: 1000, amplitude: 0.1, frames: Int(testSampleRate) * 5))
        #expect(abs(meter.shortTermLufs() - -23.0) < 1.0)
        #expect(abs(meter.integratedLufs() - -23.0) < 1.0)
    }

    @Test("Silence reads at the gate floor")
    func measuresSilence() {
        var meter = LufsMeter(sampleRate: testSampleRate)
        meter.process([Float](repeating: 0, count: Int(testSampleRate) * 2))
        #expect(meter.shortTermLufs() == LufsMeter.gateFloorLufs)
        #expect(meter.integratedLufs() == LufsMeter.gateFloorLufs)
    }

    @Test("Nothing measured yet reads at the floor, not NaN")
    func emptyMeterIsFloor() {
        let meter = LufsMeter(sampleRate: testSampleRate)
        #expect(meter.shortTermLufs() == LufsMeter.gateFloorLufs)
        #expect(meter.integratedLufs() == LufsMeter.gateFloorLufs)
    }

    @Test("Reset clears the history")
    func resetClearsHistory() {
        var meter = LufsMeter(sampleRate: testSampleRate)
        meter.process(sine(frequency: 1000, amplitude: 0.5, frames: Int(testSampleRate)))
        meter.reset()
        #expect(meter.shortTermLufs() == LufsMeter.gateFloorLufs)
    }
}

@Suite("Voice Boost — processor")
struct VoiceEnhanceProcessorTests {

    private func speechLike(seconds: Double, amplitude: Float) -> [Float] {
        // A single tone in the speech band. Not speech, but it exercises the whole chain: the
        // meter sees it, the high-pass leaves it, the presence peak touches it, and the makeup gain
        // has to lift it.
        sine(frequency: 500, amplitude: amplitude, frames: Int(seconds * testSampleRate))
    }

    @Test("A quiet signal comes out louder")
    func liftsQuietAudio() {
        let processor = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        // -30 dBFS peak, well below the -14 LUFS target.
        let input = speechLike(seconds: 5, amplitude: 0.0316)
        let output = processor.process(input)

        #expect(output.count == input.count)
        // Measured on the last second, after the meter's 400 ms blocks and the gain smoothing have
        // both settled.
        let tail = input.count - Int(testSampleRate)
        let gainDb = dB(rms(output[tail...]) / rms(input[tail...]))
        #expect(gainDb > 10)
    }

    @Test("Gain stays inside the -20..+30 dB bounds")
    func gainIsBounded() {
        // About -57 LUFS: the -14 target is 43 dB away, so the gain has to clamp rather than run
        // away lifting a noise floor.
        let quiet = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        _ = quiet.process(speechLike(seconds: 5, amplitude: 0.002))
        #expect(quiet.appliedGainDb <= VoiceEnhanceProcessor.maxGainDb + 0.01)
        #expect(quiet.appliedGainDb >= VoiceEnhanceProcessor.minGainDb - 0.01)
        // And it is actually pinned at the ceiling, not coincidentally under it.
        #expect(abs(quiet.appliedGainDb - VoiceEnhanceProcessor.maxGainDb) < 0.5)

        // Digital near-silence is below the -70 LUFS gate: held at unity rather than lifted.
        let nearSilent = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        _ = nearSilent.process(speechLike(seconds: 5, amplitude: 0.0002))
        #expect(abs(nearSilent.appliedGainDb) < 0.5)

        // And the other end: a signal already far above the target must be cut, but not past -20 dB.
        let loud = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        _ = loud.process(speechLike(seconds: 5, amplitude: 0.98))
        #expect(loud.appliedGainDb <= 0.01)
        #expect(loud.appliedGainDb >= VoiceEnhanceProcessor.minGainDb - 0.01)
    }

    @Test("Silence is not lifted")
    func doesNotLiftSilence() {
        let processor = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        let output = processor.process([Float](repeating: 0, count: Int(testSampleRate) * 2))
        #expect(output.allSatisfy { $0 == 0 })
        #expect(processor.measuredLufs == LufsMeter.gateFloorLufs)
    }

    @Test("Bypass is bit-exact: the caller simply does not call process")
    func bypassIsPassThrough() {
        // The controller never calls `process` while the preference is off, so bypass cannot be
        // anything but the input. What has to hold is that a rejected format behaves the same way:
        // inert, not silent.
        let processor = VoiceEnhanceProcessor(sampleRate: 4000, channelCount: 1)
        #expect(processor.isConfigurationValid == false)
        let input = speechLike(seconds: 0.1, amplitude: 0.3)
        #expect(processor.process(input) == input)
    }

    @Test("Re-enabling resets the chain")
    func resetReturnsToInitialState() {
        let processor = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        let input = speechLike(seconds: 1, amplitude: 0.0316)

        let first = processor.process(input)
        _ = processor.process(speechLike(seconds: 3, amplitude: 0.8))
        processor.reset()

        #expect(processor.appliedGainDb == 0)
        #expect(processor.measuredLufs == LufsMeter.gateFloorLufs)
        // Same input, same output: no filter memory, no compressor envelope, no loudness history
        // carried across the gap.
        #expect(processor.process(input) == first)
    }

    /// Android's `onFlush` keeps the loudness meter alive across a seek and resets only the
    /// filters, the dynamics and the gain. A seek does not change the episode, so the measurement
    /// is still about the same audio; clearing it would spend the seconds after every seek
    /// reconverging the makeup gain. `reset()` is the other case — a new episode or a rebuilt
    /// chain — and it does clear it.
    @Test("Flush spares the loudness history; reset clears it")
    func flushKeepsLoudnessHistory() {
        let flushed = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        _ = flushed.process(speechLike(seconds: 5, amplitude: 0.0316))
        let measured = flushed.measuredLufs
        let integrated = flushed.integratedLufs
        #expect(measured > LufsMeter.gateFloorLufs)

        flushed.flush()
        #expect(flushed.measuredLufs == measured)
        #expect(flushed.integratedLufs == integrated)
        // The parts a seek discontinuity does invalidate are gone.
        #expect(flushed.appliedGainDb == 0)

        let cleared = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 1)
        _ = cleared.process(speechLike(seconds: 5, amplitude: 0.0316))
        cleared.reset()
        #expect(cleared.measuredLufs == LufsMeter.gateFloorLufs)
        #expect(cleared.integratedLufs == LufsMeter.gateFloorLufs)
    }

    @Test("Stereo is processed once and written to both channels")
    func stereoIsDualMono() {
        let processor = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 2)
        var interleaved: [Float] = []
        for sample in speechLike(seconds: 2, amplitude: 0.0316) {
            interleaved.append(sample)
            interleaved.append(sample)
        }

        let output = processor.process(interleaved)

        #expect(output.count == interleaved.count)
        for frame in stride(from: 0, to: output.count, by: 2) {
            #expect(output[frame] == output[frame + 1])
        }
    }

    @Test("A malformed buffer is passed through, never half-processed")
    func partialFrameIsPassedThrough() {
        let processor = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 2)
        let odd: [Float] = [0.1, 0.2, 0.3]
        #expect(processor.process(odd) == odd)
    }

    @Test("Reconfiguring for a new sample rate rebuilds the chain")
    func configureRecomputesCoefficients() {
        let processor = VoiceEnhanceProcessor(sampleRate: testSampleRate, channelCount: 2)
        _ = processor.process(speechLike(seconds: 1, amplitude: 0.0316))

        processor.configure(sampleRate: 44100, channelCount: 1)

        #expect(processor.sampleRate == 44100)
        #expect(processor.channelCount == 1)
        #expect(processor.isConfigurationValid)
        // A rebuild is also a reset: nothing from the previous format survives it.
        #expect(processor.appliedGainDb == 0)
        #expect(processor.measuredLufs == LufsMeter.gateFloorLufs)
    }
}
