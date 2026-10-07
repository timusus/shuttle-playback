import Foundation
import Testing
@testable import SilenceGate

/// **The skip-silence decision, and only the decision.**
///
/// The `AVAudioEngine` playback path cannot be exercised here: this machine's CoreAudio refuses to
/// open an output device and the simulator's clock does not advance, so anything that needs a
/// speaker is device work. What can be pinned, and what the whole feature turns on, is the
/// arithmetic — which runs are trimmed, by how much, and how the saving is counted. That is why
/// ``SilenceGate`` takes samples and returns samples with no engine and no audio session anywhere
/// near it.
///
/// The tuning under test is Android's, not one invented for iOS: 0.3 s minimum run, 35% retention,
/// 2 s cap, threshold 1024/32768 (`provideSilenceSkippingAudioProcessor` in the Android
/// `PlaybackModule`).
@Suite("Silence gate")
struct SilenceGateTests {

    private let sampleRate: Double = 48000
    private let channels = 1

    private func makeGate(channels: Int = 1) -> SilenceGate {
        SilenceGate(sampleRate: sampleRate, channelCount: channels)
    }

    private func frames(_ seconds: Double) -> Int {
        Int((seconds * sampleRate).rounded())
    }

    private func silence(_ seconds: Double, channels: Int = 1) -> [Float] {
        Array(repeating: 0, count: frames(seconds) * channels)
    }

    private func tone(_ seconds: Double, level: Float = 0.5, channels: Int = 1) -> [Float] {
        Array(repeating: level, count: frames(seconds) * channels)
    }

    // MARK: - The minimum run

    @Test("a silent run shorter than 300ms is passed through untouched")
    func shortSilenceIsKept() {
        let gate = makeGate()
        var out: [Float] = []
        var skipped = 0

        for block in [tone(0.1), silence(0.2), tone(0.1)] {
            let result = gate.process(block)
            out += result.samples
            skipped += result.skippedFrames
        }
        let tail = gate.flush()
        out += tail.samples
        skipped += tail.skippedFrames

        #expect(skipped == 0, "a 200ms pause is speech rhythm, not dead air")
        #expect(out.count == frames(0.4), "every frame must survive")
        #expect(gate.totalSkippedFrames == 0)
    }

    @Test("a run one frame under the minimum is still kept whole")
    func justUnderTheMinimumIsKept() {
        let gate = makeGate()
        let run = frames(0.3) - 1
        _ = gate.process(tone(0.05))
        let result = gate.process(Array(repeating: 0, count: run))
        let closing = gate.process(tone(0.05))
        #expect(result.skippedFrames == 0)
        #expect(closing.skippedFrames == 0)
        #expect(closing.samples.count == run + frames(0.05), "the held run is released whole")
    }

    // MARK: - The trim

    @Test("a long silent run is trimmed to 35 percent of itself")
    func longSilenceIsTrimmed() {
        let gate = makeGate()
        _ = gate.process(tone(0.05))
        _ = gate.process(silence(1.0))
        let released = gate.process(tone(0.05))

        let expectedKept = Int((Double(frames(1.0)) * 0.35).rounded())
        #expect(released.skippedFrames == frames(1.0) - expectedKept)
        #expect(released.samples.count == expectedKept + frames(0.05))
        #expect(gate.totalSkippedFrames == frames(1.0) - expectedKept)
    }

    @Test("the kept portion is capped at two seconds however long the run")
    func keptPortionIsCapped() {
        let gate = makeGate()
        // 30 s of silence: 35% would be 10.5 s, the cap says 2 s.
        #expect(gate.keptFrames(forSilentRunOf: frames(30)) == frames(2.0))
        #expect(gate.keptFrames(forSilentRunOf: frames(1.0)) == Int((Double(frames(1.0)) * 0.35).rounded()))
        #expect(gate.keptFrames(forSilentRunOf: frames(0.2)) == frames(0.2), "below the minimum, nothing is trimmed")
    }

    @Test("the saving is counted once, at the moment the run is released")
    func savingIsCountedOnce() {
        let gate = makeGate()
        _ = gate.process(tone(0.05))
        // The same run, arriving in four buffers. None of them may credit anything.
        for _ in 0..<4 {
            let mid = gate.process(silence(0.25))
            #expect(mid.skippedFrames == 0, "an unfinished run has no length yet")
        }
        let released = gate.process(tone(0.05))
        let runFrames = frames(0.25) * 4
        let expectedKept = min(Int((Double(runFrames) * 0.35).rounded()), frames(2.0))
        #expect(released.skippedFrames == runFrames - expectedKept)
        #expect(gate.totalSkippedFrames == runFrames - expectedKept)

        // And nothing further is credited for a run already released.
        let after = gate.process(tone(0.05))
        #expect(after.skippedFrames == 0)
        #expect(gate.flush().skippedFrames == 0)
        #expect(gate.totalSkippedFrames == runFrames - expectedKept)
    }

    // MARK: - The pathological cases

    @Test("a fully silent stream neither runs away nor grows without bound")
    func fullySilentStreamIsBounded() {
        let gate = makeGate()
        var emitted = 0
        var skipped = 0
        // Ten seconds of digital silence and nothing else.
        for _ in 0..<20 {
            let result = gate.process(silence(0.5))
            emitted += result.samples.count
            skipped += result.skippedFrames
        }
        #expect(emitted == 0, "an unfinished run emits nothing")
        #expect(skipped == 0, "and credits nothing")

        let tail = gate.flush()
        #expect(tail.samples.count == frames(2.0), "the cap decides the trailing run")
        #expect(tail.skippedFrames == frames(10.0) - frames(2.0))
        #expect(gate.totalSkippedFrames == frames(10.0) - frames(2.0))
        // The saving can never exceed the material: this is the runaway-skip guard.
        #expect(gate.totalSkippedFrames < frames(10.0))
        #expect(gate.flush().skippedFrames == 0, "a second flush credits nothing")
    }

    @Test("a level exactly at the threshold counts as silence and just above does not")
    func thresholdBoundary() {
        let threshold = SilenceGateSettings.podcast.silenceThreshold
        let atThreshold = SilenceGate(sampleRate: sampleRate, channelCount: 1)
        _ = atThreshold.process([0.5])
        _ = atThreshold.process(Array(repeating: threshold, count: frames(1.0)))
        let released = atThreshold.process([0.5])
        #expect(released.skippedFrames > 0, "at the threshold is silence")

        let above = SilenceGate(sampleRate: sampleRate, channelCount: 1)
        _ = above.process([0.5])
        _ = above.process(Array(repeating: threshold * 1.5, count: frames(1.0)))
        let quiet = above.process([0.5])
        #expect(quiet.skippedFrames == 0, "quiet speech is not dead air")
        #expect(above.totalSkippedFrames == 0)
    }

    @Test("a stereo frame with one live channel is not silence")
    func stereoUsesTheLoudestChannel() {
        let gate = makeGate(channels: 2)
        var samples: [Float] = []
        for _ in 0..<frames(1.0) {
            samples.append(0)     // dead left
            samples.append(0.4)   // live right
        }
        let result = gate.process(samples)
        #expect(result.skippedFrames == 0)
        #expect(result.samples.count == samples.count)
    }

    @Test("a seek clears the held run rather than emitting audio from before it")
    func resetDropsTheHold() {
        let gate = makeGate()
        _ = gate.process(tone(0.05))
        _ = gate.process(silence(1.0))
        gate.reset()
        let after = gate.process(tone(0.05))
        #expect(after.samples.count == frames(0.05), "nothing from before the seek comes back")
        #expect(after.skippedFrames == 0)
        // The tally survives a seek; only `resetSavings` clears it.
        #expect(gate.totalSkippedFrames == 0, "nothing had been released before the reset")
        _ = gate.process(silence(1.0))
        _ = gate.process(tone(0.05))
        #expect(gate.totalSkippedFrames > 0)
        gate.resetSavings()
        #expect(gate.totalSkippedFrames == 0)
    }

    @Test("a buffer that is not a whole number of frames is passed through, never silenced")
    func malformedBufferIsPassedThrough() {
        let gate = makeGate(channels: 2)
        let odd: [Float] = [0.1, 0.2, 0.3]
        let result = gate.process(odd)
        #expect(result.samples == odd)
        #expect(result.skippedFrames == 0)
    }

    @Test("an empty buffer is a no-op")
    func emptyBuffer() {
        let gate = makeGate()
        let result = gate.process([])
        #expect(result == SilenceGate.Output.empty)
    }
}
