import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

extension StreamDecodeTests {
    // MARK: - Cancel

    func testCancelUnblocksAStalledRead() throws {
        try skipUnlessAvailable()
        let reader = BlockingByteReader()
        let decoder = FFmpegStreamDecoder(reader: reader)
        let finished = expectation(description: "the decoder returned")

        /* `open()` is the blocking call here — probing needs bytes — so this covers the case that
         * actually strands a listener: tapping play on a dead connection and then tapping back. */
        DispatchQueue.global().async {
            do {
                _ = try decoder.open()
                XCTFail("open() returned on a reader that never delivered a byte")
            } catch {
                XCTAssertNil(decoder.nextChunk())
            }
            finished.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { decoder.cancel() }
        wait(for: [finished], timeout: 2.0)
        XCTAssertEqual(decoder.endReason, .cancelled)
    }

    // MARK: - Interrupt

    /// The seek race, at the decoder. A read parked on a stalled body must come back when the
    /// caller interrupts it, and — the whole difference from a cancel — the decoder must still be
    /// usable: the seek that the interrupt was for runs on it and audio keeps coming.
    func testInterruptEndsTheReadButNotTheDecoder() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let reader = try StallingFileByteReader(url: url, stallAfterBytes: 64 * 1024)
        let decoder = FFmpegStreamDecoder(reader: reader)
        _ = try decoder.open()

        let blocked = expectation(description: "the pull loop returned nil")
        DispatchQueue.global().async {
            while decoder.nextChunk() != nil {}
            blocked.fulfill()
        }
        /* Interrupt only once a read is actually parked in the stall: interrupting before that
         * would prove nothing about a blocked call coming back. */
        XCTAssertTrue(reader.waitUntilStalled(timeout: 5), "the reader never reached the stall")
        decoder.interrupt()
        wait(for: [blocked], timeout: 5.0)

        XCTAssertEqual(decoder.endReason, .interrupted, "an interrupt must not read as EOF or a cancel")
        let landed = try decoder.seek(toSeconds: 5)
        XCTAssertEqual(landed, 5, accuracy: 1.0)
        XCTAssertEqual(decoder.endReason, .running, "the seek did not clear the interruption")
        XCTAssertNotNil(decoder.nextChunk(), "the decoder produced nothing after an interrupted read")
    }

    /// A seek that arrives while the stream is still opening interrupts the open. That has to
    /// throw `.interrupted`, never `.failed`: a caller answers `.failed` with its fallback
    /// player, as if the format were unsupported. Stalls in the ID3 probe (0), in libavformat's
    /// first read (10, past the ID3 header) and, where the open reads that far, deeper in its probe.
    func testInterruptDuringOpenThrowsInterruptedNotFailed() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            for stallAfter: Int64 in [0, 10, 40 * 1024] {
                let reader = try StallingFileByteReader(url: try Fixture.url(name), stallAfterBytes: stallAfter)
                let decoder = FFmpegStreamDecoder(reader: reader)
                var thrown: Error?
                var opened = false
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    do { _ = try decoder.open(); opened = true } catch { thrown = error }
                    done.signal()
                }
                let deadline = Date().addingTimeInterval(5)
                var finished = false
                while !reader.isStalled, !finished, Date() < deadline {
                    finished = done.wait(timeout: .now() + 0.002) == .success
                }
                guard !finished, reader.isStalled else {
                    if !finished { _ = done.wait(timeout: .now() + 5) }
                    /* The open needed fewer bytes than the stall point: nothing to interrupt. */
                    XCTAssertTrue(opened, "\(name) @\(stallAfter): open neither stalled nor succeeded")
                    XCTAssertGreaterThan(stallAfter, 10, "\(name): every open reads past its first 10 bytes")
                    continue
                }
                decoder.interrupt()
                XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "\(name) @\(stallAfter): open never returned")
                XCTAssertFalse(opened, "\(name) @\(stallAfter): an interrupted open reported success")
                XCTAssertEqual(thrown as? StreamDecoderError, .interrupted, "\(name) @\(stallAfter): got \(String(describing: thrown))")
                XCTAssertEqual(decoder.endReason, .interrupted, "\(name) @\(stallAfter)")
            }
        }
    }

    // MARK: - Read failure

    /// A read that failed is not a failed seek: the decoder is still positioned, so a seek once
    /// the source is back resumes it. 0.4.0 stored the read's failure as terminal (#45's rule for
    /// a failed seek), so the player's Play after a network outage was refused without a byte read.
    func testASeekAfterAFailedReadResumesTheSameDecoder() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let size = try XCTUnwrap(try FileByteReader(url: url).totalLength)
        let reader = try OutageFileByteReader(url: url, cutoff: size / 2)
        let decoder = FFmpegStreamDecoder(reader: reader)
        let format = try decoder.open()
        let decoded = decodeAll(decoder).count / format.channelCount
        XCTAssertEqual(decoder.endReason, .failure, "a broken body must not read as the end of the stream")
        XCTAssertGreaterThan(decoded, 0)
        XCTAssertLessThan(decoded, Fixture.frameCount)

        reader.heal()
        let stoppedAt = Double(decoded) / format.sampleRate
        let landed = try decoder.seek(toSeconds: stoppedAt)
        XCTAssertEqual(landed, stoppedAt, accuracy: 0.01)
        XCTAssertEqual(decoder.endReason, .running, "the seek did not clear the failed read")
        let rest = decodeAll(decoder)
        XCTAssertEqual(decoder.endReason, .eof)
        XCTAssertEqual(Double(rest.count / format.channelCount), Double(Fixture.frameCount) - stoppedAt * format.sampleRate, accuracy: 1)
        let reference = try referenceDecode(url, from: stoppedAt)
        XCTAssertEqual(landed, reference.landed)
        XCTAssertTrue(rest == reference.pcm, "the resumed decode differs from a clean decode seeked to \(stoppedAt) s")
    }

    /// A seek that fails because the source is still offline is not a refusal by the source: it
    /// throws for that call only, and the next seek, once the source is back, reads again. 0.4.0
    /// latched it like an unseekable source's refusal, so a Play pressed during the outage killed
    /// the episode for every later Play.
    func testASeekThatFailsInAnOutageLeavesTheDecoderSeekable() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let size = try XCTUnwrap(try FileByteReader(url: url).totalLength)
        let reader = try OutageFileByteReader(url: url, cutoff: size / 2)
        let decoder = FFmpegStreamDecoder(reader: reader)
        _ = try decoder.open()
        _ = decodeAll(decoder)
        XCTAssertEqual(decoder.endReason, .failure)

        // Well past the cutoff, so the seek must read bytes the outage withholds.
        let target = 15.0
        XCTAssertThrowsError(try decoder.seek(toSeconds: target), "a seek into the outage succeeded") { error in
            guard case .failed = error as? StreamDecoderError else {
                return XCTFail("an outage is not a refused seek: got \(error)")
            }
        }
        XCTAssertEqual(decoder.endReason, .failure)

        reader.heal()
        let landed = try decoder.seek(toSeconds: target)
        XCTAssertEqual(landed, target, accuracy: 0.01)
        XCTAssertEqual(decoder.endReason, .running, "the seek after the outage did not clear the failed one")
        let rest = decodeAll(decoder)
        XCTAssertEqual(decoder.endReason, .eof)
        let reference = try referenceDecode(url, from: target)
        XCTAssertEqual(landed, reference.landed)
        XCTAssertTrue(rest == reference.pcm, "the decode after the outage differs from a clean decode seeked to \(target) s")
    }

    /// A clean decoder over `url`, seeked to `seconds` and decoded to the end.
    private func referenceDecode(_ url: URL, from seconds: Double) throws -> (landed: Double, pcm: [Float]) {
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try decoder.open()
        let landed = try decoder.seek(toSeconds: seconds)
        let pcm = decodeAll(decoder)
        XCTAssertEqual(decoder.endReason, .eof)
        return (landed, pcm)
    }

    // MARK: - No Content-Length

    /// A seek into a chunked body whose connection broke is NOT the end of the stream: libavformat
    /// reports the broken read as end of file, and only the reader knows otherwise. (A seek past
    /// the real end of a length-less source is end of stream; the conformance suite's seek to the
    /// end under `unknownLength` holds that.)
    func testUnknownLengthSeekIntoATruncatedBodyIsNotEOF() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        let size = try XCTUnwrap(try FileByteReader(url: url).totalLength)
        let decoder = FFmpegStreamDecoder(reader: try TruncatedFileByteReader(url: url, cutoff: size / 2))
        _ = try decoder.open()
        do {
            _ = try decoder.seek(toSeconds: 25)
            XCTFail("a seek into a broken body succeeded with endReason \(decoder.endReason)")
        } catch {
            XCTAssertEqual(error as? StreamDecoderError, .failed(status: Int32(STREAM_DECODE_ERR_SEEK.rawValue)))
        }
        XCTAssertNotEqual(decoder.endReason, .eof, "a truncated body read as the end of the stream")
    }

    func testUnknownLengthStillDecodesMP3() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.mp3)
        /* A chunked response with no `Content-Length`: `AVSEEK_SIZE` must answer "unknown", and
         * MP3 must not care — its duration comes from the Xing header, not from the file size. */
        let reader = try FileByteReader(url: url, reportsTotalLength: false)
        XCTAssertNil(reader.totalLength)
        let decoder = FFmpegStreamDecoder(reader: reader)
        let format = try decoder.open()
        XCTAssertEqual(format.sampleRate, 44100)
        /* The Xing duration survives a length-less source: stock n7.1 mp3dec discarded the tag
         * when `avio_size()` could not answer, which scripts/ffmpeg-patches/0001 fixes. */
        XCTAssertEqual(try XCTUnwrap(format.duration), 20, accuracy: 0.1, "the Xing frame count gives the duration")
        let pcm = decodeAll(decoder)
        XCTAssertEqual(Double(pcm.count / format.channelCount), 44100 * 20, accuracy: 4096)
        XCTAssertEqual(decoder.endReason, .eof)
    }

    // MARK: - Refusals

    func testGarbageInputFailsRatherThanHangs() throws {
        try skipUnlessAvailable()
        var bytes = Data(count: 96 * 1024)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            var seed: UInt64 = 0x5EED
            for i in 0..<raw.count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                p[i] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        let decoder = FFmpegStreamDecoder(reader: DataByteReader(bytes))
        XCTAssertThrowsError(try decoder.open()) { error in
            guard case StreamDecoderError.failed = error else {
                return XCTFail("expected a decode failure, got \(error)")
            }
        }
        XCTAssertEqual(decoder.endReason, .failure)
        XCTAssertNil(decoder.nextChunk())
    }

    // MARK: - Probe budget

    /// The Swift default and the C fallback (used when a field is zero, or by `stream_decoder_open`)
    /// are two spellings of one number. If they drift, a caller passing `.default` probes
    /// differently from one that passes nothing.
    func testDefaultProbeBudgetMatchesTheCFallback() {
        XCTAssertEqual(StreamProbeBudget.default.bytes, 64 * 1024)
        XCTAssertEqual(StreamProbeBudget.default.analyzeDuration, 1)
        #if canImport(CStreamDecode)
            XCTAssertEqual(StreamProbeBudget.default.bytes, Int64(STREAM_DECODE_DEFAULT_PROBE_BYTES))
            XCTAssertEqual(
                Int64(StreamProbeBudget.default.analyzeDuration * 1_000_000),
                Int64(STREAM_DECODE_DEFAULT_MAX_ANALYZE_US)
            )
        #endif
    }

    /// A caller-chosen budget reaches the decoder: a generous one still opens every fixture, and
    /// the result matches the default's.
    func testCustomProbeBudgetOpens() throws {
        try skipUnlessAvailable()
        let budget = StreamProbeBudget(bytes: 1024 * 1024, analyzeDuration: 5)
        for name in Fixture.all {
            let url = try Fixture.url(name)
            let custom = try FFmpegStreamDecoder(reader: try FileByteReader(url: url), probeBudget: budget).open()
            let standard = try FFmpegStreamDecoder(reader: try FileByteReader(url: url)).open()
            XCTAssertEqual(custom.sampleRate, standard.sampleRate, "\(name)")
            XCTAssertEqual(custom.channelCount, standard.channelCount, "\(name)")
            XCTAssertEqual(try XCTUnwrap(custom.duration), try XCTUnwrap(standard.duration), accuracy: 0.01, "\(name)")
        }
    }

}
