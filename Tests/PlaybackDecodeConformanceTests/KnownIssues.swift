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

    static let rules: [Rule] = [
        // A 24-bit WAV with no known length buffers a second 32 KiB before the first audio. Inherent
        // to FFmpeg's wav demuxer: its header loop skips past the data chunk to look for trailing
        // chunks unless `avio_size()` shows the chunk ends the file. With no size it seeks to the end
        // of the data (the read there meets EOF), and the `avio_seek` back to the data start drops the
        // buffer, so the first packet refills it from byte 102. `avio_size()` cannot be answered
        // honestly for such a source, and the demuxer has no option to skip the look.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "wav_s24.wav", kind: .bytes, switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["65546 bytes read before the first audio, golden allows 33792"]),
        // media3 Ogg and WAV port (#33). The WAV rules below are the #36 double read again: with no
        // known length the wav demuxer buffers a second time before the first audio.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sample.wav", kind: .bytes, switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["98314 bytes read before the first audio, golden allows 89088"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sample_with_odd_metadata_chunk_size.wav", kind: .bytes,
             switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["98314 bytes read before the first audio, golden allows 89088"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sample_8bit.wav", kind: .bytes, switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["76956 bytes read before the first audio, golden allows 33792"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sample_float32.wav", kind: .bytes, switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["65546 bytes read before the first audio, golden allows 33792"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sine_24le.wav", kind: .bytes, switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["65546 bytes read before the first audio, golden allows 33792"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sample_rf64.wav", kind: .bytes, switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["98314 bytes read before the first audio, golden allows 67584"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/36 (wav_s24 reads twice with unknown length)",
             fixture: "sample_wav_format_extensible.wav", kind: .bytes,
             switches: [.unknownLength, [.partialReads, .unknownLength]],
             messages: ["131082 bytes read before the first audio, golden allows 99328"]),
        // The same fixture re-reads more after an I/O error under partial reads.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/58 (extensible WAV re-reads after an I/O error)",
             fixture: "sample_wav_format_extensible.wav", kind: .bytes,
             switches: [[.partialReads, .ioErrorOncePerPosition],
                        [.partialReads, .ioErrorOncePerPosition, .unknownLength]],
             messages: ["135178 bytes read before the first audio, golden allows 99328"]),
        // Ogg FLAC resumed after an I/O error repeats frames.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac.ogg", kind: .frameCount, switches: [.ioErrorOncePerPosition],
             messages: ["143856 frames, clean 131568"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac.ogg", kind: .frameCount, switches: [[.partialReads, .ioErrorOncePerPosition]],
             messages: ["217584 frames, clean 131568"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac.ogg", kind: .resumePCM, switches: [.ioErrorOncePerPosition],
             messages: ["PCM differs from the clean decode at sample 107520 (143856 vs 131568 frames, resumes at frames [16384, 49152])"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac.ogg", kind: .resumePCM, switches: [[.partialReads, .ioErrorOncePerPosition]],
             messages: ["PCM differs from the clean decode at sample 107520 (217584 vs 131568 frames, resumes at frames [16384, 16384, 49152, 61440, 73728, 86016])"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac_noseektable.ogg", kind: .frameCount, switches: [.ioErrorOncePerPosition],
             messages: ["143856 frames, clean 131568"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac_noseektable.ogg", kind: .frameCount, switches: [[.partialReads, .ioErrorOncePerPosition]],
             messages: ["168432 frames, clean 131568"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac_noseektable.ogg", kind: .resumePCM, switches: [.ioErrorOncePerPosition],
             messages: ["PCM differs from the clean decode at sample 107520 (143856 vs 131568 frames, resumes at frames [16384, 49152])"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/57 (Ogg FLAC resume after an I/O error repeats frames)",
             fixture: "bear_flac_noseektable.ogg", kind: .resumePCM, switches: [[.partialReads, .ioErrorOncePerPosition]],
             messages: ["PCM differs from the clean decode at sample 107520 (168432 vs 131568 frames, resumes at frames [16384, 16384, 49152, 61440, 73728])"]),
        // An MP4 whose mdat is longer than the file ends in a failure instead of EOF without a length.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/60 (sample_mdat_too_long: unknown length ends in failure)",
             fixture: "sample_mdat_too_long.mp4", kind: .outcome, switches: unknownLengthCombos,
             messages: ["outcome decoded(end: \"failure\"), clean decoded(end: \"eof\")"]),
        // Fragmented Opus in MP4 stops after 0.5 s without a length; every seek lands there.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/61 (sample_opus_fragmented: unknown length stops after 0.5 s)",
             fixture: "sample_opus_fragmented.mp4", kind: .frameCount, switches: unknownLengthCombos,
             messages: ["24000 frames, clean 120000"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/61 (sample_opus_fragmented: unknown length stops after 0.5 s)",
             fixture: "sample_opus_fragmented.mp4", kind: .seekLanding, switches: unknownLengthCombos,
             messages: ["0.8333333333333333", "1.6666666666666665", "2.4", "2.5"].map { "seek to \($0)s landed 0.5s" }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/61 (sample_opus_fragmented: unknown length stops after 0.5 s)",
             fixture: "sample_opus_fragmented.mp4", kind: .seekPCM, switches: unknownLengthCombos,
             messages: ["0.8333333333333333", "1.6666666666666665", "2.4", "2.5"]
                .map { "seek to \($0)s: PCM after the landing at 0.5s is not in the clean decode" }),
        // A partially fragmented MP4 decodes nothing without a length; every seek lands at 0.11 s.
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/62 (sample_partially_fragmented: unknown length decodes 0 frames)",
             fixture: "sample_partially_fragmented.mp4", kind: .frameCount, switches: unknownLengthCombos,
             messages: ["0 frames, clean 45056"]),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/62 (sample_partially_fragmented: unknown length decodes 0 frames)",
             fixture: "sample_partially_fragmented.mp4", kind: .seekLanding, switches: unknownLengthCombos,
             messages: partiallyFragmentedSeeks.map { "seek to \($0)s landed 0.11072562358276644s" }),
        Rule(issue: "https://github.com/timusus/shuttle-playback/issues/62 (sample_partially_fragmented: unknown length decodes 0 frames)",
             fixture: "sample_partially_fragmented.mp4", kind: .seekPCM, switches: unknownLengthCombos,
             messages: partiallyFragmentedSeeks
                .map { "seek to \($0)s: PCM after the landing at 0.11072562358276644s is not in the clean decode" }),
    ]

    private static let unknownLengthCombos: [FaultSwitches] = [
        .unknownLength, [.partialReads, .unknownLength], [.ioErrorOncePerPosition, .unknownLength],
        [.partialReads, .ioErrorOncePerPosition, .unknownLength],
    ]
    private static let partiallyFragmentedSeeks = ["0.0", "0.34055933484504913", "0.6811186696900983",
                                                   "0.9216780045351475", "1.0216780045351475"]

    /// The rule a finding is pinned by, if any.
    static func rule(for fixture: String, kind: ConformanceMatrix.Kind, switches: FaultSwitches,
                     message: String) -> Int? {
        rules.firstIndex {
            $0.fixture == fixture && $0.kind == kind && $0.switches.contains(switches) && $0.messages.contains(message)
        }
    }
}
