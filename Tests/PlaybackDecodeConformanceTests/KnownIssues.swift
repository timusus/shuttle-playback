/// Decoder bugs the suite has found and not fixed, pinned exactly: one fixture, one assertion kind,
/// the fault combinations that show it, and the exact finding each one produces (the measured
/// landing, byte count or frame count is in the message). A matching finding runs inside
/// `XCTExpectFailure`. Anything else fails: a finding with another value, under another
/// combination, or a pinned finding that stops happening (remove its rule when its issue is fixed).
/// The issue number is on timusus/shuttle-playback.
///
/// Not listed because the golden pins it as measured instead: MP3 seek misalignment (issue #3)
/// shows as `alignFrames` in the goldens. A fix there changes the golden, and the diff is the review.
enum KnownIssues {
    struct Rule {
        var issue: String
        var fixture: String
        var kind: ConformanceMatrix.Kind
        var switches: [FaultSwitches]
        /// Each must be produced, verbatim, under every one of `switches`.
        var messages: [String]
    }

    private static let unknownLengthSets: [FaultSwitches] = [
        [.unknownLength], [.partialReads, .unknownLength],
        [.ioErrorOncePerPosition, .unknownLength], [.partialReads, .ioErrorOncePerPosition, .unknownLength],
    ]

    static let rules: [Rule] = [
        // ff_seek_frame_binary bisects between 0 and the file size; with no size it cannot, and the
        // Ogg seek lands on an earlier page.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/6 (Ogg seek with totalLength nil lands early)",
             fixture: "opus_stereo.opus", kind: .seekLanding, switches: unknownLengthSets,
             messages: ["seek to 1.3333333333333333s landed 0.9934999999999999s",
                        "seek to 2.6666666666666665s landed 1.9934999999999998s"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/6 (Ogg seek with totalLength nil lands early)",
             fixture: "vorbis_stereo.ogg", kind: .seekLanding, switches: unknownLengthSets,
             messages: ["seek to 1.3336961451247165s landed 1.0216780045351475s",
                        "seek to 2.667392290249433s landed 2.043356009070295s"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/6 (Ogg seek with totalLength nil lands early)",
             fixture: "vorbis_stereo.ogg", kind: .seekPCM, switches: unknownLengthSets,
             messages: ["seek to 4.001088435374149s: PCM after the landing at 4.017052154195011s sits -41984 frames off, clean seek 0"]),
        // Ogg has no index to resume by, so its resume is that same seek, and landing early
        // repeats audio.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/6 (Ogg seek with totalLength nil lands early)",
             fixture: "vorbis_stereo.ogg", kind: .frameCount,
             switches: [[.ioErrorOncePerPosition, .unknownLength], [.partialReads, .ioErrorOncePerPosition, .unknownLength]],
             messages: ["218432 frames, clean 176448"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/8 (seek to the end of an MP3 with trailing garbage)",
             fixture: "garbage_trailing_4k.mp3", kind: .seekPCM, switches: unknownLengthSets,
             messages: ["seek to 4.048979591836734s: PCM after the landing at 4.048979591836734s is not in the clean decode"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/9 (moov-first M4A reads the whole probe budget when totalLength is nil)",
             fixture: "tone_moov_first.m4a", kind: .bytes, switches: unknownLengthSets,
             messages: ["65546 bytes read before the first audio, golden allows 33792"]),
    ]

    /// The rule a finding is pinned by, if any.
    static func rule(for fixture: String, kind: ConformanceMatrix.Kind, switches: FaultSwitches,
                     message: String) -> Int? {
        rules.firstIndex {
            $0.fixture == fixture && $0.kind == kind && $0.switches.contains(switches) && $0.messages.contains(message)
        }
    }
}
