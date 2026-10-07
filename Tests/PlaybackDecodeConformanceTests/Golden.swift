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
        /// as measured, so a change in either direction shows in the diff.
        var alignFrames: Int?
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

enum GoldenStore {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixturesDir = root.appendingPathComponent("Fixtures")
    /// The three 20 s fixtures the decoder's own tests use, shared rather than copied.
    static let legacyFixturesDir = root.deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeTests/Fixtures")
    static let goldensDir = root.appendingPathComponent("Goldens")

    static var updating: Bool { ProcessInfo.processInfo.environment["GOLDEN_UPDATE"] == "1" }

    static func fixtureURLs() -> [URL] {
        let skip: Set<String> = ["NOTICE", "make-fixtures.sh", "README.md"]
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(golden).write(to: goldenURL(for: golden.fixture))
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
