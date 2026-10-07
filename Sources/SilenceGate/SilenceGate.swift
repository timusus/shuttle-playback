import Foundation

/// The tuning, taken from Android rather than invented here.
///
/// Android hands media3 a podcast-tuned `SilenceSkippingAudioProcessor`
/// (`playback/.../di/PlaybackModule.kt`, `provideSilenceSkippingAudioProcessor`):
///
/// ```
/// minimumSilenceDurationUs            = 300_000     // 0.3 s
/// silenceRetentionRatio               = 0.35
/// maxSilenceToKeepDurationUs          = 2_000_000   // 2 s
/// minVolumeToKeepPercentageWhenMuting = 10
/// silenceThresholdLevel               = 1024        // 16-bit PCM amplitude
/// ```
///
/// Those five numbers are reproduced below, converted where the units differ: the threshold is an
/// absolute 16-bit sample level on Android and this pipeline is Float32, so 1024/32768 is the same
/// level expressed in the units the samples actually arrive in.
///
/// The retention ratio is why this is a *gate* and not a mute: a silent run long enough to trim is
/// not removed outright, 35% of it (capped at 2 s) is kept, so inter-sentence rhythm survives and
/// speech does not butt against speech. A run shorter than 0.3 s is a natural pause and is passed
/// through untouched.
public struct SilenceGateSettings: Equatable, Sendable {

    /// Sample magnitude at or below which a frame counts as silent. `1024 / 32768`.
    public var silenceThreshold: Float = 1024.0 / 32768.0
    /// Shorter runs than this are natural speech pauses and are never trimmed.
    public var minimumSilenceDuration: TimeInterval = 0.3
    /// The fraction of a trimmable run that is kept.
    public var silenceRetentionRatio: Double = 0.35
    /// Hard cap on the kept portion, however long the run.
    public var maximumSilenceToKeep: TimeInterval = 2.0

    public init(
        silenceThreshold: Float = 1024.0 / 32768.0,
        minimumSilenceDuration: TimeInterval = 0.3,
        silenceRetentionRatio: Double = 0.35,
        maximumSilenceToKeep: TimeInterval = 2.0
    ) {
        self.silenceThreshold = silenceThreshold
        self.minimumSilenceDuration = minimumSilenceDuration
        self.silenceRetentionRatio = silenceRetentionRatio
        self.maximumSilenceToKeep = maximumSilenceToKeep
    }

    public static let podcast = SilenceGateSettings()
}

/// **The whole decision: which decoded frames reach the speaker and which are dropped.**
///
/// Pure by construction. No engine, no audio session, no clock: samples in, samples out, plus a
/// count of what was dropped. That is deliberate and is the only reason any of this is testable on
/// a machine whose CoreAudio cannot open an output device. Everything about the AVAudioEngine path
/// that needs a real speaker is unproven; this is not part of it.
///
/// Interleaved Float32, because that is what an `AVAssetReader` output hands over and what the
/// engine writes back into an `AVAudioPCMBuffer`. A "frame" is one sample per channel; silence is
/// judged on the loudest channel of a frame, so a stereo file with one dead channel is not trimmed
/// to nothing.
///
/// # Streaming
///
/// A run of silence cannot be judged until it ends, so its samples are held. ``process(_:)`` returns
/// only what is safe to emit; the held tail is emitted by the next call that sees a loud frame, or
/// by ``flush()`` at end of stream. The holding buffer is bounded: past
/// `maximumSilenceToKeep` worth of frames, everything further is dropped as it arrives rather than
/// accumulated, so an hour of digital silence costs a fixed 2 s of memory and does not stall output.
public final class SilenceGate {

    /// One call's worth of output.
    public struct Output: Equatable {
        /// Interleaved Float32 samples to play, in order.
        public var samples: [Float]
        /// Frames removed by this call. Media time still advances over them: the position the app
        /// reports is media position, exactly as media3's `getSkippedOutputFrameCount` correction
        /// makes it on Android.
        public var skippedFrames: Int

        public init(samples: [Float], skippedFrames: Int) {
            self.samples = samples
            self.skippedFrames = skippedFrames
        }

        public static let empty = Output(samples: [], skippedFrames: 0)
    }

    private let settings: SilenceGateSettings
    private let channelCount: Int
    private let sampleRate: Double

    /// Frames of the run of silence currently being accumulated, interleaved. Never longer than
    /// ``maximumKeptFrames``.
    private var heldSilence: [Float] = []
    /// The true length of the current silent run, including frames already discarded from the hold.
    private var heldSilenceFrames = 0

    /// Total frames this gate has removed since the last ``reset()``.
    public private(set) var totalSkippedFrames: Int = 0

    /// The time this gate has removed since the last ``reset()``.
    public var totalSkippedDuration: TimeInterval {
        sampleRate > 0 ? TimeInterval(totalSkippedFrames) / sampleRate : 0
    }

    public init(settings: SilenceGateSettings = .podcast, sampleRate: Double, channelCount: Int) {
        self.settings = settings
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = max(channelCount, 1)
    }

    /// The shortest run that may be trimmed at all, in frames.
    private var minimumSilenceFrames: Int {
        max(Int((settings.minimumSilenceDuration * sampleRate).rounded()), 1)
    }

    /// The cap on the kept portion of a run, in frames.
    private var maximumKeptFrames: Int {
        max(Int((settings.maximumSilenceToKeep * sampleRate).rounded()), 0)
    }

    /// Whether a frame's loudest channel sits at or below the silence threshold.
    ///
    /// At or below, not below: a level exactly at the threshold counts as silence, matching the
    /// Android monitor's boundary (`a level exactly at the inaudible threshold counts as silence`).
    private func isSilent(frameAt index: Int, in samples: [Float]) -> Bool {
        let base = index * channelCount
        for channel in 0..<channelCount {
            if abs(samples[base + channel]) > settings.silenceThreshold { return false }
        }
        return true
    }

    /// How many frames of a completed silent run of `length` frames survive.
    ///
    /// Exposed for tests: this is the arithmetic the whole feature turns on, and asserting it
    /// through a buffer would assert the buffering as well.
    public func keptFrames(forSilentRunOf length: Int) -> Int {
        guard length >= minimumSilenceFrames else { return length }
        let proportional = Int((Double(length) * settings.silenceRetentionRatio).rounded())
        return min(proportional, maximumKeptFrames)
    }

    /// Push one buffer of interleaved samples through the gate.
    ///
    /// A sample count that is not a whole number of frames is passed through untouched rather than
    /// half-analysed: a malformed buffer must never be able to silence playback.
    public func process(_ samples: [Float]) -> Output {
        guard !samples.isEmpty else { return .empty }
        guard samples.count % channelCount == 0 else {
            return Output(samples: flush().samples + samples, skippedFrames: 0)
        }

        let frameCount = samples.count / channelCount
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var skipped = 0
        // Start of the current stretch of loud frames in this buffer, or nil while in silence.
        var loudRunStart: Int?

        for frame in 0..<frameCount {
            if isSilent(frameAt: frame, in: samples) {
                if let start = loudRunStart {
                    out.append(contentsOf: samples[(start * channelCount)..<(frame * channelCount)])
                    loudRunStart = nil
                }
                hold(frame: frame, of: samples)
            } else {
                if heldSilenceFrames > 0 {
                    let released = releaseHeldSilence()
                    out.append(contentsOf: released.samples)
                    skipped += released.skippedFrames
                }
                if loudRunStart == nil { loudRunStart = frame }
            }
        }

        if let start = loudRunStart {
            out.append(contentsOf: samples[(start * channelCount)..<samples.count])
        }

        totalSkippedFrames += skipped
        return Output(samples: out, skippedFrames: skipped)
    }

    /// End of stream: emit whatever silence is still held, trimmed by the same rule.
    ///
    /// A trailing run is decided here rather than left in the hold, or the last seconds of an
    /// episode would never be emitted and `.ended` would arrive with audio still owed.
    public func flush() -> Output {
        guard heldSilenceFrames > 0 else { return .empty }
        let released = releaseHeldSilence()
        totalSkippedFrames += released.skippedFrames
        return released
    }

    /// Forget the current run. Called on every seek: silence either side of a seek is two runs, not
    /// one long one, and carrying the hold across would emit audio from before the seek.
    ///
    /// The lifetime tally is deliberately NOT cleared here; ``resetSavings()`` does that.
    public func reset() {
        heldSilence.removeAll(keepingCapacity: true)
        heldSilenceFrames = 0
    }

    /// Zero the tally. Separate from ``reset()`` so a seek does not erase the time already saved.
    public func resetSavings() {
        totalSkippedFrames = 0
    }

    // MARK: - The hold

    private func hold(frame: Int, of samples: [Float]) {
        heldSilenceFrames += 1
        // Bounded: nothing past the cap can ever be kept, so nothing past the cap is stored. This
        // is what stops a fully silent file from growing the hold without limit.
        guard heldSilence.count / channelCount < maximumKeptFrames else { return }
        let base = frame * channelCount
        heldSilence.append(contentsOf: samples[base..<(base + channelCount)])
    }

    /// Decide the completed run and empty the hold.
    private func releaseHeldSilence() -> Output {
        let runFrames = heldSilenceFrames
        let keep = min(keptFrames(forSilentRunOf: runFrames), heldSilence.count / channelCount)
        let kept = Array(heldSilence.prefix(keep * channelCount))
        heldSilence.removeAll(keepingCapacity: true)
        heldSilenceFrames = 0
        return Output(samples: kept, skippedFrames: runFrames - keep)
    }
}
