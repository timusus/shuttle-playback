/// Decoder bugs the suite has found. Each is scoped to the one assertion that shows it, which runs
/// inside `XCTExpectFailure`, so the suite goes red the day the bug is fixed (strict mode: an
/// expected failure that does not happen fails) and the entry must be removed. Every other
/// assertion on the fixture, including every other fault combination, counts as a real failure.
/// The issue number is on timusus/shuttle-playback.
///
/// Not listed because the golden pins it as measured instead: seek misalignment (issue #3) shows
/// as `alignFrames` in the goldens. A fix there changes the golden, and the diff is the review.
enum KnownIssues {
    struct Rule {
        var issue: String
        var fixtures: Set<String>
        var kinds: Set<ConformanceMatrix.Kind>
        var applies: (FaultSwitches) -> Bool
    }

    static let rules: [Rule] = [
        // An Ogg resume is an ordinary seek (no index puts it back on a packet), so landing early
        // repeats audio: more frames, or an outcome failure where it lands late instead.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/6 (Ogg seek with totalLength nil lands early)",
             fixtures: ["opus_stereo.opus", "vorbis_stereo.ogg"],
             kinds: [.seekLanding, .outcome, .frameCount],
             applies: { $0.contains(.unknownLength) }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/9 (moov-first M4A reads the whole probe budget when totalLength is nil)",
             fixtures: ["tone_moov_first.m4a"],
             kinds: [.bytes],
             applies: { $0.contains(.unknownLength) }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/8(seek to the end of an MP3 with trailing garbage)",
             fixtures: ["garbage_trailing_4k.mp3"],
             kinds: [.seekPCM],
             applies: { $0.contains(.unknownLength) }),
    ]
}
