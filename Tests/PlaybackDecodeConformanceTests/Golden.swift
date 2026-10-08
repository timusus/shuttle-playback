import CryptoKit
import Foundation

/// What "the clean decode is right" means for one fixture, as JSON beside it in `Goldens/`. PCM is
/// hashed after quantising to Int16, per second, so a diff names the second that changed and float
/// drift across toolchains does not churn the file. Regenerate with
/// `GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance` and read the diff.
struct Golden: Codable, Equatable {
    struct Seek: Codable, Equatable {
        var toS: Double
        var landedS: Double
        var tolS: Double
        /// Frames between the landed time and where the PCM that follows really sits in the
        /// continuous decode: 0 is an exact seek, nil means no match within ±65536 frames. Pinned
        /// as measured, so a change in either direction shows in the diff. Always written, as an
        /// explicit `null` when there is no match.
        var alignFrames: Int?
        /// Frames in the compared window after the landing (fewer than the nominal when the seek
        /// lands near the end of the file).
        var windowFrames: Int
        /// Int16 hash of that window: pins the PCM of a seek even when `alignFrames` is null.
        var windowSha256Int16: String
    }

    var fixture: String
    /// Of the fixture file: a re-encode under the golden shows up here first.
    var sha256: String
    /// "decodes", or "error:<StreamDecodeStatus>" when open is expected to fail.
    var expect: String
    var sampleRate: Int
    var channels: Int
    var frames: Int
    var durationS: Double
    var pcmSha256PerSecondInt16: [String]
    var seeks: [Seek]
    var bytesBeforeFirstAudioMax: Int64
}

extension Golden.Seek {
    private enum CodingKeys: String, CodingKey {
        case toS, landedS, tolS, alignFrames, windowFrames, windowSha256Int16
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toS = try c.decode(Double.self, forKey: .toS)
        landedS = try c.decode(Double.self, forKey: .landedS)
        tolS = try c.decode(Double.self, forKey: .tolS)
        // `decode`, not `decodeIfPresent`: a missing key is a malformed golden, null is a measurement.
        alignFrames = try c.decode(Int?.self, forKey: .alignFrames)
        windowFrames = try c.decode(Int.self, forKey: .windowFrames)
        windowSha256Int16 = try c.decode(String.self, forKey: .windowSha256Int16)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toS, forKey: .toS)
        try c.encode(landedS, forKey: .landedS)
        try c.encode(tolS, forKey: .tolS)
        try c.encode(alignFrames, forKey: .alignFrames)
        try c.encode(windowFrames, forKey: .windowFrames)
        try c.encode(windowSha256Int16, forKey: .windowSha256Int16)
    }
}

enum GoldenStore {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixturesDir = root.appendingPathComponent("Fixtures")
    /// The three 20 s fixtures the decoder's own tests use, shared rather than copied.
    static let legacyFixturesDir = root.deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeTests/Fixtures")
    static let goldensDir = root.appendingPathComponent("Goldens")

    static var updating: Bool { ProcessInfo.processInfo.environment["GOLDEN_UPDATE"] == "1" }

    static func fixtureURLs() -> [URL] {
        /* The stitch_*_64k.mp3 pair belongs to StreamDecodeTests: the second half is resampled, and
         * a seek into it starts the resampler on another output grid (anchored at the landing, not
         * at the switch) and lands to within a byte's time, so it is not bit-identical to the
         * clean decode. stitch_stereo_mono_64k.mp3 changes channel count mid-stream and belongs to
         * OutputFormatTests. The chained Ogg pair is not byte-reproducible and has known bugs
         * (#48, #49); the two FLACs are covered by their own decoder tests (StreamDecodeTests,
         * OutputFormatTests). */
        let skip: Set<String> = ["NOTICE", "LICENSE-APACHE-2.0", "make-fixtures.sh", "README.md",
                                 "stitch_44k_48k_64k.mp3", "stitch_48k_44k_64k.mp3",
                                 "stitch_stereo_mono_64k.mp3",
                                 "chained_vorbis_44k_48k.ogg", "chained_opus_mono_stereo.opus",
                                 "flac_192k_24bit.flac", "flac_51_48k.flac"]
        return [fixturesDir, legacyFixturesDir].flatMap { dir -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { !skip.contains($0) && !$0.hasPrefix(".") }.sorted()
                .map { dir.appendingPathComponent($0) }
        }
    }

    static func goldenURL(for fixture: String) -> URL {
        goldensDir.appendingPathComponent(fixture + ".json")
    }

    static func load(_ fixture: String) -> Golden? {
        guard let data = try? Data(contentsOf: goldenURL(for: fixture)) else { return nil }
        return try? JSONDecoder().decode(Golden.self, from: data)
    }

    static func save(_ golden: Golden) throws {
        try FileManager.default.createDirectory(at: goldensDir, withIntermediateDirectories: true)
        print("golden \(golden.fixture): \(diffSummary(old: load(golden.fixture), new: golden))")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(golden).write(to: goldenURL(for: golden.fixture))
    }

    /// One line naming what changed between the golden on disk and the new measurement.
    static func diffSummary(old: Golden?, new: Golden) -> String {
        guard let old else { return "new" }
        var changed: [String] = []
        if old.sha256 != new.sha256 { changed.append("fixture sha256") }
        if old.expect != new.expect { changed.append("expect \(old.expect) -> \(new.expect)") }
        if old.sampleRate != new.sampleRate { changed.append("sampleRate") }
        if old.channels != new.channels { changed.append("channels") }
        if old.frames != new.frames { changed.append("frames \(old.frames) -> \(new.frames)") }
        if old.durationS != new.durationS { changed.append("durationS \(old.durationS) -> \(new.durationS)") }
        if old.pcmSha256PerSecondInt16 != new.pcmSha256PerSecondInt16 {
            let n = max(old.pcmSha256PerSecondInt16.count, new.pcmSha256PerSecondInt16.count)
            let differing = (0..<n).filter {
                ($0 < old.pcmSha256PerSecondInt16.count ? old.pcmSha256PerSecondInt16[$0] : nil)
                    != ($0 < new.pcmSha256PerSecondInt16.count ? new.pcmSha256PerSecondInt16[$0] : nil)
            }
            changed.append("PCM seconds \(differing.map(String.init).joined(separator: ","))")
        }
        if old.seeks != new.seeks {
            let n = max(old.seeks.count, new.seeks.count)
            let differing = (0..<n).filter {
                ($0 < old.seeks.count ? old.seeks[$0] : nil) != ($0 < new.seeks.count ? new.seeks[$0] : nil)
            }
            changed.append("seeks #\(differing.map(String.init).joined(separator: ",#"))")
        }
        if old.bytesBeforeFirstAudioMax != new.bytesBeforeFirstAudioMax {
            changed.append("bytesBeforeFirstAudioMax \(old.bytesBeforeFirstAudioMax) -> \(new.bytesBeforeFirstAudioMax)")
        }
        return changed.isEmpty ? "unchanged" : changed.joined(separator: "; ")
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Per-second Int16 hashes of interleaved Float32 PCM (the last second may be partial).
    static func perSecondHashes(_ pcm: [Float], sampleRate: Int, channels: Int) -> [String] {
        let perSecond = max(sampleRate * channels, 1)
        return stride(from: 0, to: pcm.count, by: perSecond).map { start in
            var bytes = [UInt8]()
            bytes.reserveCapacity(perSecond * 2)
            for x in pcm[start..<min(start + perSecond, pcm.count)] {
                let q = Int16(max(-32768, min(32767, (x * 32767).rounded())))
                bytes.append(UInt8(truncatingIfNeeded: q))
                bytes.append(UInt8(truncatingIfNeeded: q >> 8))
            }
            return sha256(of: Data(bytes))
        }
    }
}
