/// Decoder bugs the suite has found. Each is scoped to the one assertion that shows it, which runs
/// inside `XCTExpectFailure`, so the suite goes red the day the bug is fixed (strict mode: an
/// expected failure that does not happen fails) and the entry must be removed. Every other
/// assertion on the fixture, including every other fault combination, counts as a real failure.
/// The issue number is on timusus/shuttle-playback.
///
/// Not listed because the golden pins it as measured instead: seek misalignment (issue #3) shows
/// as `alignFrames` in the goldens. A fix there changes the golden, and the diff is the review.
enum KnownIssues {
    /// Issue #1: the frame-count assertion of a decode with `totalLength` nil.
    static let unknownLengthTail = "https://github.com/timusus/shuttle-playback/issues/1 "
        + "(totalLength nil: end padding of an MP3 with an Xing/Info header is not trimmed)"

    struct Rule {
        var issue: String
        var fixtures: Set<String>
        var kinds: Set<ConformanceMatrix.Kind>
        var applies: (FaultSwitches) -> Bool
    }

    static let rules: [Rule] = [
        Rule(issue: unknownLengthTail,
             fixtures: ["tone.mp3", "vbr_xing.mp3", "lame_info_delay_padding.mp3",
                        "test-cbr-info-header-pcut-frame.mp3"],
             kinds: [.frameCount],
             applies: { $0.contains(.unknownLength) }),
        // A resume after an interrupt seeks the same decoder; where MP3 seeks land early the
        // stitched decode repeats audio (more frames, PCM shifted after the warm-up).
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/3 (MP3 seek lands before the reported time; a resume repeats audio)",
             fixtures: ["bear-vbr-vbri-header.mp3", "bear-vbr-vbri-header-truncated-toc.mp3", "tone.mp3",
                        "lame_info_delay_padding.mp3", "test-cbr-info-header-pcut-frame.mp3", "id3v1_footer.mp3"],
             kinds: [.frameCount, .resumePCM],
             applies: { $0.contains(.ioErrorOncePerPosition) }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/4 (HE-AAC seek after an interrupted read lands late)",
             fixtures: ["he_aac_v1.m4a", "he_aac_v2.m4a"],
             kinds: [.outcome, .seekLanding, .seekPCM],
             applies: { $0.contains(.ioErrorOncePerPosition) }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/5 (MP3 seek retried after an interrupt lands on another frame)",
             fixtures: ["lame_info_delay_padding.mp3", "garbage_trailing_4k.mp3"],
             kinds: [.seekLanding, .seekPCM],
             applies: { $0.contains(.ioErrorOncePerPosition) }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/6 (Ogg seek with totalLength nil lands early)",
             fixtures: ["opus_stereo.opus", "vorbis_stereo.ogg"],
             kinds: [.seekLanding, .outcome],
             applies: { $0.contains(.unknownLength) }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/7 (AAC resume differs in the last ~800 frames)",
             fixtures: ["aac_edit_list.m4a", "tone_moov_first.m4a", "tone_moov_last.m4a"],
             kinds: [.resumePCM],
             applies: { $0.contains(.ioErrorOncePerPosition) }),
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
