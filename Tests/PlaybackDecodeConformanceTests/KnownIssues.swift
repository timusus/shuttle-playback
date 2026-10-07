/// Decoder bugs the suite has found and not fixed, pinned exactly: one fixture, one assertion kind,
/// the fault combinations that show it, and the exact finding each one produces (the measured
/// landing, byte count or frame count is in the message). A matching finding runs inside
/// `XCTExpectFailure`. Anything else fails: a finding with another value, under another
/// combination, or a pinned finding that stops happening (remove its rule when its issue is fixed).
/// The issue number is on timusus/shuttle-playback.
///
/// Seeks are sample-accurate: the decoder starts a pre-roll before the target and drops what
/// comes before it, so `alignFrames` is 0 in every seek of every golden (a seek to the end lands
/// where the clean decode ends). The one landing that cannot be exact is
/// outside these fixtures: a seek in a VBR MP3 further from a frame of known time than one seek's
/// byte budget (`kSeekBudgetBytes`, a few seconds of audio) is placed by its Xing TOC or bitrate,
/// and nothing in an MP3 frame says what time it is (issue #3).
enum KnownIssues {
    struct Rule {
        var issue: String
        var fixture: String
        var kind: ConformanceMatrix.Kind
        var switches: [FaultSwitches]
        /// Each must be produced, verbatim, under every one of `switches`.
        var messages: [String]
    }

    static let rules: [Rule] = []

    /// The rule a finding is pinned by, if any.
    static func rule(for fixture: String, kind: ConformanceMatrix.Kind, switches: FaultSwitches,
                     message: String) -> Int? {
        rules.firstIndex {
            $0.fixture == fixture && $0.kind == kind && $0.switches.contains(switches) && $0.messages.contains(message)
        }
    }
}
