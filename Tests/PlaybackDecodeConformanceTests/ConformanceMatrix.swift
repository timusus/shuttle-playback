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
    /// Frame positions where an interrupted decode was resumed by a seek of the same decoder. The
    /// PCM from each is a restarted codec's, so its first `seekWarmupFrames` are not compared.
    var resumeFrames: [Int] = []

    var frames: Int { pcm.count / max(format?.channelCount ?? 1, 1) }
}

enum ConformanceMatrix {
    static let seekFractions: [Double] = [0, 1.0 / 3, 2.0 / 3, 1]
    /// A seek this far before the last frame, between 2/3 and the end: the seek to the end lands on
    /// EOF and pins no audio, so this one pins the last of it.
    static let nearEndSeconds = 0.1

    /// Where the suite seeks in a file of `duration` seconds: each of `seekFractions`, with the
    /// near-end seek before the last.
    static func seekTargets(duration: Double) -> [Double] {
        var targets = seekFractions.map { duration * $0 }
        targets.insert(max(0, duration - nearEndSeconds), at: targets.count - 1)
        return targets
    }
    /// A seek restarts the codec: the first frames after it lack the previous frame's overlap (AAC,
    /// Opus, Vorbis) or bit-reservoir bytes (MP3, catalogue C20), so they are not expected to equal
    /// the continuous decode. The warm-up is skipped; the frames after it must match.
    static let seekWarmupFrames = 4608
    static let seekCompareFrames = 4096
    static let maxAttempts = 400

    static var plantDefect: String? { ProcessInfo.processInfo.environment["CONFORMANCE_PLANT_DEFECT"] }

    /// Opens a decoder, retrying with a fresh one when the open itself is interrupted by an injected
    /// error (nothing is decoded yet, so there is nothing to resume).
    /// Also returns the bytes the reader had served when the successful attempt began.
    private static func open(_ reader: FaultyByteReader) -> (FFmpegStreamDecoder, StreamAudioFormat, Int, String?, Int64) {
        var attempts = 0
        while true {
            attempts += 1
            reader.rewind()
            let before = reader.injectedErrors
            let start = reader.bytesRead
            let decoder = FFmpegStreamDecoder(reader: reader)
            do {
                return (decoder, try decoder.open(), attempts, nil, start)
            } catch {
                if reader.injectedErrors > before, attempts < maxAttempts { continue }
                return (decoder, StreamAudioFormat(sampleRate: 0, channelCount: 0, duration: 0, codec: "", container: ""),
                        attempts, String(describing: error), start)
            }
        }
    }

    /// Decodes the whole file. An injected I/O error ends the pull with `.interrupted`, which the
    /// decoder reports as recoverable by a seek. Recovery is the player's: keep the PCM decoded so
    /// far and seek the same decoder to where the pull stopped, then drop whatever the seek landed
    /// before that point and carry on. The reader remembers which blocks already failed, so each
    /// further attempt meets faults at new positions only. A failure with no new injected error is
    /// a real one and is returned.
    static func decode(_ url: URL, switches: FaultSwitches) throws -> DecodeRun {
        let reader = try FaultyByteReader(url: url, switches: switches)
        let (decoder, format, openAttempts, openError, openStart) = open(reader)
        if let openError { return DecodeRun(outcome: .failed(openError), attempts: openAttempts) }
        let channels = format.channelCount
        let rate = format.sampleRate
        var run = DecodeRun(outcome: .decoded(end: ""), format: format, attempts: openAttempts)
        var sawFirst = false
        var injected = reader.injectedErrors
        while true {
            while let chunk = decoder.nextChunk() {
                if !sawFirst { run.bytesBeforeFirstAudio = reader.bytesRead - openStart; sawFirst = true }
                run.pcm += chunk
            }
            guard reader.injectedErrors > injected || decoder.endReason == .interrupted else { break }
            let resumeAt = run.frames
            var landed: TimeInterval?
            while landed == nil {
                run.attempts += 1
                if run.attempts > maxAttempts {
                    return DecodeRun(outcome: .failed("no convergence after \(maxAttempts) attempts"), attempts: maxAttempts)
                }
                let before = reader.injectedErrors
                do {
                    landed = try decoder.seek(toSeconds: Double(resumeAt) / rate)
                } catch {
                    if reader.injectedErrors > before { continue }
                    return DecodeRun(outcome: .failed("resume seek failed: \(error)"), attempts: run.attempts)
                }
            }
            let landedFrame = Int(((landed ?? 0) * rate).rounded())
            guard landedFrame <= resumeAt else {
                return DecodeRun(outcome: .failed("resume seek to frame \(resumeAt) landed later, at \(landedFrame)"),
                                 attempts: run.attempts)
            }
            run.pcm.removeLast((resumeAt - landedFrame) * channels)
            run.resumeFrames.append(landedFrame)
            injected = reader.injectedErrors
        }
        run.outcome = .decoded(end: decoder.endReason.rawValue)
        return run
    }

    /// What one seek produced: where it says it landed and the PCM that followed (after the warm-up).
    struct SeekResult: Equatable {
        var target: Double
        var landed: Double
        /// Frames of the warm-up skipped before `window`.
        var skipFrames: Int
        var window: [Float]
    }

    /// Per-sample tolerance when comparing PCM after a restarted codec with the continuous decode:
    /// a restarted codec reproduces it to float rounding, not to the bit.
    /// Measured: an AAC seek restart differs from the continuous decode by up to 5e-4 at exactly
    /// the right alignment, so 2e-4 (the old probe tolerance) cannot hold over a whole window. The
    /// exact PCM of each seek is pinned by `windowSha256Int16`; this only finds where it sits.
    static let alignTolerance: Float = 1e-3
    static let alignSearchFrames = 65536

    /// Seeks to each fraction of the clean duration and records where it landed and the PCM after it.
    /// An injected error during a seek or its window read restarts that seek, as the player would.
    static func seekResults(_ url: URL, switches: FaultSwitches, clean: DecodeRun, label: String) throws
        -> [SeekResult]
    {
        guard let cleanFormat = clean.format else { return [] }
        let channels = cleanFormat.channelCount
        let duration = Double(clean.frames) / cleanFormat.sampleRate
        let reader = try FaultyByteReader(url: url, switches: switches)
        let (decoder, _, _, openError, _) = open(reader)
        if let openError { XCTFail("\(label): open failed: \(openError)"); return [] }
        var results: [SeekResult] = []
        for target in seekTargets(duration: duration) {
            var result: SeekResult?
            for _ in 0..<maxAttempts where result == nil {
                let before = reader.injectedErrors
                let landed: TimeInterval
                do {
                    landed = try decoder.seek(toSeconds: target)
                } catch {
                    if reader.injectedErrors > before { continue }
                    XCTFail("\(label): seek to \(target) threw \(error)")
                    break
                }
                let want = (seekWarmupFrames + seekCompareFrames) * channels
                var got: [Float] = []
                while got.count < want, let chunk = decoder.nextChunk() { got += chunk }
                if reader.injectedErrors > before { continue }
                // Near the end of the file there is less than a warm-up left: skip what there is
                // room for, keeping the last `probe` frames so something is still compared.
                let probe = 256 * channels
                let skip = min(seekWarmupFrames * channels, max(0, got.count - probe))
                result = SeekResult(target: target, landed: landed, skipFrames: skip / channels,
                                    window: Array(got.dropFirst(skip).prefix(seekCompareFrames * channels)))
            }
            if let result { results.append(result) }
        }
        return results
    }

    /// How many frames after the landed time the window really sits in the continuous decode: 0 when
    /// the seek is exact, nil when no alignment within ±`alignSearchFrames` matches to tolerance.
    /// The whole window must match, not a probe of it. An empty window is exact (0) only when it
    /// landed on the clean decode's end, where there is nothing after it to compare.
    static func alignment(of result: SeekResult, clean: DecodeRun) -> Int? {
        guard let format = clean.format else { return nil }
        let channels = format.channelCount
        let nominal = Int((result.landed * format.sampleRate).rounded()) + result.skipFrames
        if result.window.isEmpty { return nominal == clean.frames ? 0 : nil }
        for distance in 0...alignSearchFrames {
            for offset in distance == 0 ? [0] : [distance, -distance] {
                let start = (nominal + offset) * channels
                guard start >= 0, start + result.window.count <= clean.pcm.count else { continue }
                var matches = true
                for i in 0..<result.window.count where abs(result.window[i] - clean.pcm[start + i]) > alignTolerance {
                    matches = false
                    break
                }
                if matches { return offset }
            }
        }
        return nil
    }

    /// Seeks through the clean reader, returns the landings for the golden. Under every fault
    /// combination the seeks must reproduce the clean ones exactly: same landing, same PCM.
    static func checkSeeks(_ url: URL, clean: DecodeRun, name: String) throws -> [Golden.Seek] {
        let reference = try seekResults(url, switches: [], clean: clean, label: "\(name) [clean]")
        for switches in FaultSwitches.allCombinations {
            let faulted = try seekResults(url, switches: switches, clean: clean, label: "\(name) [\(switches)]")
            XCTAssertEqual(faulted.count, reference.count, "\(name) [\(switches)]: seek count")
            for (g, w) in zip(faulted, reference) {
                if switches.contains(.unknownLength) {
                    // Without a length an MP3 or Opus seek has no bitrate estimate to use, so it may
                    // land elsewhere than the clean seek. What must hold: it lands near the target,
                    // and the PCM after it sits where the landing says, as exactly as the clean
                    // seek's does (the same offset, or 0, an exact seek). Where the clean window
                    // has no alignment, the same landing must give the same PCM.
                    if abs(g.landed - w.target) > 0.1 {
                        report(.seekLanding, name, switches, "seek to \(w.target)s landed \(g.landed)s")
                    }
                    let cleanOffset = alignment(of: w, clean: clean)
                    let offset = alignment(of: g, clean: clean)
                    if cleanOffset != nil, offset == nil {
                        report(.seekPCM, name, switches, "seek to \(w.target)s: PCM after the landing at \(g.landed)s "
                            + "is not in the clean decode")
                    } else if let offset, offset != 0, offset != cleanOffset {
                        report(.seekPCM, name, switches, "seek to \(w.target)s: PCM after the landing at \(g.landed)s "
                            + "sits \(offset) frames off, clean seek \(cleanOffset.map(String.init) ?? "unaligned")")
                    } else if cleanOffset == nil, offset == nil, g.landed == w.landed, g.window != w.window,
                              !(g.window.isEmpty && Int((g.landed * (clean.format?.sampleRate ?? 0)).rounded()) >= clean.frames) {
                        // (An empty window at or past the clean decode's last frame is the truth:
                        // there is nothing after that landing.)
                        report(.seekPCM, name, switches, "seek to \(w.target)s: PCM after the landing differs from the clean seek")
                    }
                    continue
                }
                if g.landed != w.landed {
                    report(.seekLanding, name, switches, "seek to \(w.target)s landed \(g.landed)s, clean \(w.landed)s")
                }
                if g.window != w.window {
                    report(.seekPCM, name, switches, "seek to \(w.target)s: PCM after the landing differs from the clean seek")
                }
            }
        }
        let rate = Int(clean.format?.sampleRate ?? 0)
        return reference.map { result in
            Golden.Seek(
                toS: (result.target * 1000).rounded() / 1000,
                landedS: (result.landed * 1000).rounded() / 1000,
                tolS: 0.03,
                alignFrames: alignment(of: result, clean: clean),
                windowFrames: result.window.count / max(clean.format?.channelCount ?? 1, 1),
                windowSha256Int16: GoldenStore.perSecondHashes(
                    result.window, sampleRate: max(result.window.count, 1), channels: 1).first ?? "")
        }
    }

    private static func firstMismatch(_ a: [Float], _ b: [Float]) -> Int {
        (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
    }

    /// Compares a faulted decode with the clean one over their common prefix. With no resume it must
    /// be bit-identical. After a resume the restarted codec's warm-up is not compared and the rest
    /// matches to `alignTolerance`, not to the bit: that is every format with codec state (all of
    /// them but PCM), since a seek cannot reproduce the previous frame's overlap or reservoir.
    /// Returns the first mismatching sample, or nil.
    static func firstDifference(_ faulted: DecodeRun, _ clean: DecodeRun) -> Int? {
        let channels = max(clean.format?.channelCount ?? 1, 1)
        let common = min(faulted.pcm.count, clean.pcm.count)
        if faulted.resumeFrames.isEmpty { return faulted.pcm.prefix(common) == clean.pcm.prefix(common) ? nil : firstMismatch(faulted.pcm, clean.pcm) }
        let warm = faulted.resumeFrames.map { ($0 * channels)..<(($0 + seekWarmupFrames) * channels) }
        for i in 0..<common where abs(faulted.pcm[i] - clean.pcm[i]) > alignTolerance {
            if !warm.contains(where: { $0.contains(i) }) { return i }
        }
        return nil
    }

    private static func checkFaulted(_ faulted: DecodeRun, clean: DecodeRun, name: String, switches: FaultSwitches) {
        if faulted.outcome != clean.outcome {
            report(.outcome, name, switches, "outcome \(faulted.outcome), clean \(clean.outcome)")
            return
        }
        if let at = firstDifference(faulted, clean) {
            report(faulted.resumeFrames.isEmpty ? .pcm : .resumePCM, name, switches,
                   "PCM differs from the clean decode at sample \(at) "
                   + "(\(faulted.frames) vs \(clean.frames) frames, resumes at frames \(faulted.resumeFrames.prefix(6)))")
        }
        if faulted.frames != clean.frames {
            report(.frameCount, name, switches, "\(faulted.frames) frames, clean \(clean.frames)")
        }
        // A tone repeated or shifted by a resume still matches to tolerance; the bits do not.
        // Every whole second clear of a resume's warm-up must hash the same as the clean decode.
        if !faulted.resumeFrames.isEmpty, let format = clean.format {
            let rate = Int(format.sampleRate)
            let seconds = min(faulted.frames, clean.frames) / max(rate, 1)
            let got = GoldenStore.perSecondHashes(faulted.pcm, sampleRate: rate, channels: format.channelCount)
            let want = GoldenStore.perSecondHashes(clean.pcm, sampleRate: rate, channels: format.channelCount)
            for second in 0..<seconds where got[second] != want[second] {
                let span = (second * rate)..<((second + 1) * rate)
                if faulted.resumeFrames.contains(where: { span.overlaps($0..<($0 + seekWarmupFrames)) }) { continue }
                report(.resumePCM, name, switches, "second \(second) hashes differently from the clean decode "
                    + "(resumes at frames \(faulted.resumeFrames.prefix(6)))")
                break
            }
        }
    }

    // MARK: Findings

    /// What a mismatch is about. A known decoder bug is scoped to a fixture, a kind and the fault
    /// combinations it shows under (`KnownIssues`).
    enum Kind: String {
        case outcome, pcm, resumePCM, frameCount, seekLanding, seekPCM, bytes
    }

    struct Finding {
        var kind: Kind
        var name: String
        var switches: FaultSwitches
        var message: String
    }

    nonisolated(unsafe) static var findings: [Finding] = []

    static func report(_ kind: Kind, _ name: String, _ switches: FaultSwitches, _ message: String) {
        findings.append(Finding(kind: kind, name: name, switches: switches, message: message))
    }

    /// A finding covered by a known issue is recorded as an expected failure; anything else fails.
    /// A known issue that matched nothing fails too: the bug is fixed, so the entry must go.
    static func resolveFindings(for name: String) {
        defer { findings = [] }
        if ProcessInfo.processInfo.environment["CONFORMANCE_LIST_FINDINGS"] == "1" {
            for f in findings { print("FINDING \(name) | \(f.kind.rawValue) | \(f.switches) | \(f.message.prefix(120))") }
        }
        var seen = Set<String>()
        for f in findings {
            if let index = KnownIssues.rule(for: name, kind: f.kind, switches: f.switches, message: f.message) {
                seen.insert("\(index) \(f.switches.rawValue) \(f.message)")
                XCTExpectFailure("\(name): known decoder bug, \(KnownIssues.rules[index].issue)") {
                    XCTFail("\(name) [\(f.switches)] \(f.kind.rawValue): \(f.message)")
                }
            } else {
                XCTFail("\(name) [\(f.switches)] \(f.kind.rawValue): \(f.message)")
            }
        }
        for (index, rule) in KnownIssues.rules.enumerated() where rule.fixture == name {
            for switches in rule.switches {
                for message in rule.messages where !seen.contains("\(index) \(switches.rawValue) \(message)") {
                    XCTFail("\(name) [\(switches)] \(rule.kind.rawValue): pinned finding no longer "
                        + "reproduces (\(message)); update or remove its rule: \(rule.issue)")
                }
            }
        }
    }

    /// Everything the suite asserts about one fixture.
    static func run(fixture url: URL) throws {
        let name = url.lastPathComponent
        if GoldenStore.updating, plantDefect != nil {
            XCTFail("GOLDEN_UPDATE=1 with CONFORMANCE_PLANT_DEFECT set would write the planted defect into the goldens")
            return
        }
        let fileHash = GoldenStore.sha256(of: try Data(contentsOf: url))
        var clean = try decode(url, switches: [])

        // Planted-defect hook for proving the suite fails: drop the last frame of the clean decode.
        if plantDefect == "1", let channels = clean.format?.channelCount, clean.pcm.count >= channels {
            clean.pcm.removeLast(channels)
        }

        // 1. Every faulted decode, resumed after each injected error, matches the clean one from the
        // same run, and reads no more before its first audio than the golden allows.
        findings = []
        var faultedBytes: [(FaultSwitches, Int64)] = []
        for switches in FaultSwitches.allCombinations {
            let faulted = try decode(url, switches: switches)
            checkFaulted(faulted, clean: clean, name: name, switches: switches)
            faultedBytes.append((switches, faulted.bytesBeforeFirstAudio))
        }

        // 2. Seeks are fault-invariant, and their landing, alignment and PCM are what the golden says.
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
            bytesBeforeFirstAudioMax: (clean.bytesBeforeFirstAudio + 1023) / 1024 * 1024)

        // Counted from the start of the open attempt that succeeded, so an open retried after an
        // injected error is held to the same budget as one that was not.
        func checkBytes(allowed: Int64) {
            for (switches, bytes) in faultedBytes where bytes > allowed {
                report(.bytes, name, switches, "\(bytes) bytes read before the first audio, golden allows \(allowed)")
            }
        }
        if GoldenStore.updating {
            // A golden is only written from a run whose fault matrix holds against it.
            checkBytes(allowed: measured.bytesBeforeFirstAudioMax)
            let unpinned = findings.filter {
                KnownIssues.rule(for: name, kind: $0.kind, switches: $0.switches, message: $0.message) == nil
            }
            if unpinned.isEmpty {
                try GoldenStore.save(measured)
            } else {
                XCTFail("\(name): golden NOT written, the fault matrix fails \(unpinned.count) time(s) against it")
            }
            resolveFindings(for: name)
            return
        }
        guard let golden = GoldenStore.load(name) else {
            XCTFail("\(name): no golden; run GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance")
            return
        }
        compare(measured, to: golden, clean: clean)
        checkBytes(allowed: golden.bytesBeforeFirstAudioMax)
        resolveFindings(for: name)
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
            XCTAssertEqual(g.windowFrames, w.windowFrames, "\(name): seek to \(w.toS)s, window length")
            XCTAssertEqual(g.windowSha256Int16, w.windowSha256Int16, "\(name): seek to \(w.toS)s, PCM after the landing")
        }
        XCTAssertLessThanOrEqual(clean.bytesBeforeFirstAudio, golden.bytesBeforeFirstAudioMax,
                                 "\(name): bytes read before the first audio")
    }
}

final class ConformanceMatrixTests: XCTestCase {
    /// One method over the corpus: a new fixture in `Fixtures/` is picked up with no code change.
    /// A known decoder bug is expected only at the one assertion it shows in (see `KnownIssues`).
    func testEveryFixtureDecodesIdenticallyUnderEveryFault() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "no FFmpeg in this build")
        // CONFORMANCE_FIXTURE=<file name> runs one fixture, for debugging a single finding.
        if let only = ProcessInfo.processInfo.environment["CONFORMANCE_FIXTURE"] {
            try ConformanceMatrix.run(fixture: try XCTUnwrap(GoldenStore.fixtureURLs().first { $0.lastPathComponent == only }))
            return
        }
        let urls = GoldenStore.fixtureURLs()
        XCTAssertEqual(urls.count, 26,"fixture corpus changed: update the count with the goldens")
        for url in urls {
            try ConformanceMatrix.run(fixture: url)
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
