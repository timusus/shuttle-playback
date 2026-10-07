import Foundation
import PlaybackDecode
import XCTest

/// One whole-file decode through a reader with the given fault switches.
struct DecodeRun {
    enum Outcome: Equatable {
        case decoded(end: String)
        case failed(String)
    }

    var outcome: Outcome
    var format: StreamAudioFormat?
    var pcm: [Float] = []
    /// Bytes the reader had served when the first chunk came out.
    var bytesBeforeFirstAudio: Int64 = 0
    var attempts = 0

    var frames: Int { pcm.count / max(format?.channelCount ?? 1, 1) }
}

enum ConformanceMatrix {
    static let seekFractions: [Double] = [0, 1.0 / 3, 2.0 / 3, 1]
    /// A seek restarts the codec: the first frames after it lack the previous frame's overlap (AAC,
    /// Opus, Vorbis) or bit-reservoir bytes (MP3, catalogue C20), so they are not expected to equal
    /// the continuous decode. The warm-up is skipped; the frames after it must match exactly.
    static let seekWarmupFrames = 4608
    static let seekCompareFrames = 4096
    static let maxAttempts = 400

    /// Decodes the whole file. An injected I/O error ends a decode with `.interrupted`, which the
    /// decoder reports as recoverable by a seek; here the retry is a fresh decoder over the same
    /// reader, which remembers which positions already failed, so the run converges in about one
    /// attempt per 4 KiB block. A failure with no new injected error is a real one and is returned.
    static func decode(_ url: URL, switches: FaultSwitches) throws -> DecodeRun {
        let reader = try FaultyByteReader(url: url, switches: switches)
        for attempt in 1...maxAttempts {
            reader.rewind()
            let injectedBefore = reader.injectedErrors
            let decoder = FFmpegStreamDecoder(reader: reader)
            let format: StreamAudioFormat
            do {
                format = try decoder.open()
            } catch {
                if reader.injectedErrors > injectedBefore { continue }
                return DecodeRun(outcome: .failed(String(describing: error)), attempts: attempt)
            }
            var run = DecodeRun(outcome: .decoded(end: ""), format: format, attempts: attempt)
            var sawFirst = false
            while let chunk = decoder.nextChunk() {
                if !sawFirst { run.bytesBeforeFirstAudio = reader.bytesRead; sawFirst = true }
                run.pcm += chunk
            }
            if reader.injectedErrors > injectedBefore { continue }
            run.outcome = .decoded(end: decoder.endReason.rawValue)
            return run
        }
        return DecodeRun(outcome: .failed("no convergence after \(maxAttempts) attempts"), attempts: maxAttempts)
    }

    /// What one seek produced: where it says it landed and the PCM that followed (after the warm-up).
    struct SeekResult: Equatable {
        var target: Double
        var landed: Double
        var window: [Float]
    }

    /// Per-sample tolerance when comparing a seek's PCM with the continuous decode: a restarted
    /// codec reproduces it to float rounding, not to the bit.
    static let alignTolerance: Float = 2e-4
    static let alignSearchFrames = 65536
    static let alignProbeFrames = 256

    /// Seeks to each fraction of the clean duration and records where it landed and the PCM after it.
    static func seekResults(_ url: URL, switches: FaultSwitches, clean: DecodeRun, label: String) throws
        -> [SeekResult]
    {
        guard let format = clean.format else { return [] }
        let channels = format.channelCount
        let duration = Double(clean.frames) / format.sampleRate
        let decoder = FFmpegStreamDecoder(reader: try FaultyByteReader(url: url, switches: switches))
        try decoder.open()
        var results: [SeekResult] = []
        for fraction in seekFractions {
            let target = duration * fraction
            let landed: TimeInterval
            do {
                landed = try decoder.seek(toSeconds: target)
            } catch {
                XCTFail("\(label): seek to \(target) threw \(error)")
                continue
            }
            let skip = seekWarmupFrames * channels
            let take = seekCompareFrames * channels
            var got: [Float] = []
            while got.count < skip + take, let chunk = decoder.nextChunk() { got += chunk }
            results.append(SeekResult(target: target, landed: landed, window: Array(got.dropFirst(skip).prefix(take))))
        }
        return results
    }

    /// How many frames after the landed time the window really sits in the continuous decode: 0 when
    /// the seek is exact, nil when no alignment within ±`alignSearchFrames` matches to tolerance.
    static func alignment(of result: SeekResult, clean: DecodeRun) -> Int? {
        guard let format = clean.format, result.window.count >= alignProbeFrames * format.channelCount else {
            return nil
        }
        let channels = format.channelCount
        let nominal = Int((result.landed * format.sampleRate).rounded()) + seekWarmupFrames
        let probe = alignProbeFrames * channels
        for distance in 0...alignSearchFrames {
            for offset in distance == 0 ? [0] : [distance, -distance] {
                let start = (nominal + offset) * channels
                guard start >= 0, start + probe <= clean.pcm.count else { continue }
                var matches = true
                for i in 0..<probe where abs(result.window[i] - clean.pcm[start + i]) > alignTolerance {
                    matches = false
                    break
                }
                if matches { return offset }
            }
        }
        return nil
    }

    /// Seeks through the clean reader, returns the landings for the golden. Under faults the seeks
    /// must reproduce the clean ones exactly: same landing, same PCM.
    static func checkSeeks(_ url: URL, clean: DecodeRun, name: String) throws -> [Golden.Seek] {
        let reference = try seekResults(url, switches: [], clean: clean, label: "\(name) [clean]")
        for switches in [FaultSwitches.partialReads] {
            let faulted = try seekResults(url, switches: switches, clean: clean, label: "\(name) [\(switches)]")
            for (g, w) in zip(faulted, reference) where g != w {
                XCTFail("\(name) [\(switches)]: seek to \(w.target)s landed \(g.landed)s (clean \(w.landed)s) "
                    + "and its PCM \(g.window == w.window ? "matches" : "differs from") the clean seek")
            }
        }
        return reference.map { result in
            Golden.Seek(
                toS: (result.target * 1000).rounded() / 1000,
                landedS: (result.landed * 1000).rounded() / 1000,
                tolS: 0.03,
                alignFrames: alignment(of: result, clean: clean))
        }
    }

    private static func firstMismatch(_ a: [Float], _ b: [Float]) -> Int {
        (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
    }

    /// Everything the suite asserts about one fixture.
    static func run(fixture url: URL) throws {
        let name = url.lastPathComponent
        let fileHash = GoldenStore.sha256(of: try Data(contentsOf: url))
        var clean = try decode(url, switches: [])

        // Planted-defect hook for proving the suite fails: drop the last frame of the clean decode.
        if ProcessInfo.processInfo.environment["CONFORMANCE_PLANT_DEFECT"] == "1",
           let channels = clean.format?.channelCount, clean.pcm.count >= channels {
            clean.pcm.removeLast(channels)
        }

        // 1. Every faulted decode is bit-identical to the clean one from the same run.
        for switches in FaultSwitches.allCombinations {
            let faulted = try decode(url, switches: switches)
            if faulted.outcome != clean.outcome {
                XCTFail("\(name) [\(switches)]: outcome \(faulted.outcome), clean \(clean.outcome)")
            } else if faulted.pcm != clean.pcm {
                XCTFail("\(name) [\(switches)]: PCM differs from the clean decode "
                    + "(\(faulted.frames) vs \(clean.frames) frames, first mismatch at sample "
                    + "\(firstMismatch(faulted.pcm, clean.pcm)))")
            }
        }

        // 2. Seeks are fault-invariant, and their landing and alignment are what the golden says.
        var landings: [Golden.Seek] = []
        if case .decoded = clean.outcome {
            landings = try checkSeeks(url, clean: clean, name: name)
        }

        // 3. The golden: what "clean is right" means.
        let format = clean.format
        let rate = Int(format?.sampleRate ?? 0)
        let channels = format?.channelCount ?? 0
        let measured = Golden(
            fixture: name,
            sha256: fileHash,
            expect: { if case let .failed(why) = clean.outcome { return "error:\(why)" } else { return "decodes" } }(),
            sampleRate: rate,
            channels: channels,
            frames: clean.frames,
            durationS: ((format?.duration ?? 0) * 100).rounded() / 100,
            pcmSha256PerSecondInt16: GoldenStore.perSecondHashes(clean.pcm, sampleRate: rate, channels: channels),
            seeks: landings,
            bytesBeforeFirstAudioMax: (clean.bytesBeforeFirstAudio + 16383) / 16384 * 16384,
            )
        let existing = GoldenStore.load(name)

        if GoldenStore.updating {
            try GoldenStore.save(measured)
            return
        }
        guard let golden = existing else {
            XCTFail("\(name): no golden; run GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance")
            return
        }
        compare(measured, to: golden, clean: clean)
    }

    private static func compare(_ got: Golden, to golden: Golden, clean: DecodeRun) {
        let name = golden.fixture
        guard got.sha256 == golden.sha256 else {
            XCTFail("\(name): the fixture file changed (sha256 \(got.sha256.prefix(12)) vs golden "
                + "\(golden.sha256.prefix(12))); regenerate goldens if that was intended")
            return
        }
        XCTAssertEqual(got.expect, golden.expect, "\(name): outcome")
        XCTAssertEqual(got.sampleRate, golden.sampleRate, "\(name): sample rate")
        XCTAssertEqual(got.channels, golden.channels, "\(name): channels")
        XCTAssertEqual(got.frames, golden.frames, "\(name): frame count")
        XCTAssertEqual(got.durationS, golden.durationS, accuracy: 0.011, "\(name): reported duration")
        for (second, pair) in zip(got.pcmSha256PerSecondInt16, golden.pcmSha256PerSecondInt16).enumerated()
        where pair.0 != pair.1 {
            XCTFail("\(name): PCM of second \(second) differs from the golden")
        }
        XCTAssertEqual(got.pcmSha256PerSecondInt16.count, golden.pcmSha256PerSecondInt16.count,
                       "\(name): seconds of PCM")
        XCTAssertEqual(got.seeks.count, golden.seeks.count, "\(name): seek count")
        for (g, w) in zip(got.seeks, golden.seeks) {
            XCTAssertEqual(g.landedS, w.landedS, accuracy: w.tolS, "\(name): seek to \(w.toS)s landed")
            XCTAssertEqual(g.alignFrames, w.alignFrames,
                           "\(name): seek to \(w.toS)s, frames between the landed time and the PCM that follows")
        }
        XCTAssertLessThanOrEqual(clean.bytesBeforeFirstAudio, golden.bytesBeforeFirstAudioMax,
                                 "\(name): bytes read before the first audio")
    }
}

final class ConformanceMatrixTests: XCTestCase {
    /// One method over the corpus: a new fixture in `Fixtures/` is picked up with no code change.
    /// A fixture listed in `KnownIssues` runs inside `XCTExpectFailure`.
    func testEveryFixtureDecodesIdenticallyUnderEveryFault() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "no FFmpeg in this build")
        let urls = GoldenStore.fixtureURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 15, "fixture corpus went missing")
        for url in urls {
            if !GoldenStore.updating, let issue = KnownIssues.byFixture[url.lastPathComponent] {
                XCTExpectFailure("\(url.lastPathComponent): known decoder bug, \(issue)") {
                    try? ConformanceMatrix.run(fixture: url)
                }
            } else {
                try ConformanceMatrix.run(fixture: url)
            }
        }
    }

    func testFaultyReaderInjectsWhatItPromises() throws {
        let url = GoldenStore.legacyFixturesDir.appendingPathComponent("tone.mp3")
        let reader = try FaultyByteReader(url: url, switches: [.partialReads, .ioErrorOncePerPosition, .unknownLength])
        XCTAssertNil(reader.totalLength)
        var byte = [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(try byte.withUnsafeMutableBytes { try reader.read(into: $0.baseAddress!, maxLength: 64) })
        XCTAssertEqual(reader.position, 0, "a failed read leaves the position alone")
        let n = try byte.withUnsafeMutableBytes { try reader.read(into: $0.baseAddress!, maxLength: 64) }
        XCTAssertEqual(n, 1, "an unserved position yields one byte")
        try reader.seek(to: 0)
        let again = try byte.withUnsafeMutableBytes { try reader.read(into: $0.baseAddress!, maxLength: 64) }
        XCTAssertEqual(again, 64, "position 0 was already served, so a re-read is not shortened")
        XCTAssertEqual(reader.injectedErrors, 1)
        XCTAssertEqual(reader.bytesRead, 65)
    }
}
