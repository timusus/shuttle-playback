/// Decoder bugs the suite has found. A fixture listed here runs inside `XCTExpectFailure`, so the
/// suite goes red the day the bug is fixed (strict mode: an expected failure that does not happen
/// fails) and the entry must be removed. The issue number is on timusus/shuttle-playback.
///
/// Not listed because the golden pins them as measured instead: seek misalignment (issue #3) shows
/// as `alignFrames` in the goldens, and the garbage-prefix seek (issue #2) as its large negative
/// `alignFrames`. A fix there changes the golden, and the diff is the review.
enum KnownIssues {
    private static let unknownLengthTail = "https://github.com/timusus/shuttle-playback/issues/1 "
        + "(totalLength nil: end padding of an MP3 with an Xing/Info header is not trimmed)"

    static let byFixture: [String: String] = [
        "tone.mp3": unknownLengthTail,
        "vbr_xing.mp3": unknownLengthTail,
        "lame_info_delay_padding.mp3": unknownLengthTail,
        "test-cbr-info-header-pcut-frame.mp3": unknownLengthTail,
    ]
}
