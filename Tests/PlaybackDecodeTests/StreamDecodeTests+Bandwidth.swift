import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

extension StreamDecodeTests {
    // MARK: - The trailing-moov bandwidth trap

    func testMoovLastCostsOneSeekNotTheWholeFile() throws {
        try skipUnlessAvailable()
        let url = try Fixture.url(Fixture.moovLast)
        let fileSize = try Int64(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        XCTAssertGreaterThan(fileSize, 0)

        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        let afterOpen = counting.bytesRead

        var frames = 0
        while frames < Int(format.sampleRate), let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        XCTAssertGreaterThanOrEqual(frames, Int(format.sampleRate))

        /* Without a seek callback FFmpeg read-discards the entire `mdat` to reach the trailing
         * `moov`: on a real 60 MB file that is 60 MB of cellular data before a note is heard.
         *
         * The bound is absolute bytes rather than a share of the file, because on a fixture this
         * small there is no share worth asserting: the 64 KiB probe budget alone is 40% of 161 KB,
         * while on a 60 MB file that same fixed cost is 0.1%. What these numbers pin down is
         * the SHAPE of the transfer — probe, one seek to the end, the moov, nothing else — and a
         * walked mdat blows through every one of them. */
        let probeBudget: Int64 = 64 * 1024      // stream_decode.c sets AVFormatContext.probesize
        let avioBuffer: Int64 = 32 * 1024       // one refill of slack
        let moovSize: Int64 = 4215              // Fixtures/README.md; testMoovLastAtomOrder walks it
        let mdatSize: Int64 = 160_680
        XCTAssertLessThan(counting.bytesRead, probeBudget + avioBuffer + moovSize,
                          "read \(counting.bytesRead) of \(fileSize) bytes — more than probe + moov")
        XCTAssertLessThan(counting.bytesRead, mdatSize,
                          "read \(counting.bytesRead) bytes, more than the mdat: it is being walked")
        let nearEnd = counting.seekOffsets.contains { $0 > fileSize - 64 * 1024 }
        XCTAssertTrue(nearEnd, "no seek to the trailing moov; seeks were \(counting.seekOffsets)")
        print("MOOV-LAST BANDWIDTH: \(counting.bytesRead) of \(fileSize) bytes "
            + "(\(String(format: "%.1f", Double(counting.bytesRead) * 100 / Double(fileSize)))%), "
            + "\(counting.seekOffsets.count) seeks, \(afterOpen) of them in open()")
    }

    // MARK: - The bandwidth traps a real long MP3 has

    /// **A no-Xing CBR MP3 must cost a window to open and a window to seek in, not the file.**
    ///
    /// Most long spoken-word MP3s are exactly this: constant bitrate, no Xing/Info header, and so no
    /// table of contents. libavformat's generic seek has nothing to place a timestamp with, so it
    /// DECODES FORWARD FROM THE START until the timestamps reach the target — measured here before
    /// the fix at 12 MB for one seek to 25 minutes, on a file whose whole open cost 32 KiB.
    /// `seek.c` now caps what a seek may read and falls back to the byte estimate, which
    /// on a constant bitrate is exact.
    func testLargeCBRMP3CostsAWindowToOpenAndToSeek() throws {
        try skipUnlessAvailable()
        let url = try GeneratedFixture.largeCBRMP3()
        let size = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        XCTAssertGreaterThan(size, 8 * 1024 * 1024, "the fixture is meant to be big enough to matter")

        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        XCTAssertEqual(try XCTUnwrap(format.duration), 1800, accuracy: 5, "a CBR MP3's duration comes from its size and bitrate")

        var frames = 0
        while frames < Int(format.sampleRate), let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        XCTAssertGreaterThanOrEqual(frames, Int(format.sampleRate))
        let openCost = counting.bytesRead
        XCTAssertLessThan(openCost, 512 * 1024, "open plus one second of audio read \(openCost) bytes")

        let landed = try decoder.seek(toSeconds: 1500)
        let seekCost = counting.bytesRead - openCost
        XCTAssertLessThan(seekCost, 512 * 1024, "the seek read \(seekCost) bytes — it is walking the file")
        XCTAssertEqual(landed, 1500, accuracy: 2, "landed \(landed)")

        /* And the audio after the seek has to be the audio, not a resync into noise. */
        var after: [Float] = []
        while after.count < Int(format.sampleRate) * format.channelCount, let chunk = decoder.nextChunk() {
            after.append(contentsOf: chunk)
        }
        XCTAssertGreaterThan(after.count, 0, "nothing decoded after the seek")
        let peak = after.dropFirst(Int(format.sampleRate) / 2).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "the post-seek audio is silence, not the tone")
    }

    /// **A VBR MP3 seek is exact as far as a seek's byte budget reaches, and bounded beyond it.**
    ///
    /// A Xing TOC places a time to 1/256 of the file and mp3dec labels the frame it finds with the
    /// time asked for. Near a frame of known time the decoder counts frames instead, so
    /// the landing is the requested sample; far from one, the count would walk the file, so the
    /// TOC's landing stands and the seek still costs a window.
    func testXingVBRMP3SeeksExactlyNearAndCheaplyFar() throws {
        try skipUnlessAvailable()
        let url = try GeneratedFixture.xingVBRMP3()
        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        XCTAssertEqual(try XCTUnwrap(format.duration), 300, accuracy: 1)

        /* The audio after the near seek must be the continuous decode's at the same sample. The
         * landed time alone proves nothing: a TOC landing is labelled with the time asked for. At
         * 7 s the TOC lands on its third entry, an estimate; the first frame is within reach. */
        let channels = format.channelCount
        let seconds = 7, at = seconds * Int(format.sampleRate), window = 4096
        var continuous: [Float] = []
        let reference = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try reference.open()
        while continuous.count < (at + window) * channels, let chunk = reference.nextChunk() {
            continuous.append(contentsOf: chunk)
        }
        let near = try decoder.seek(toSeconds: Double(seconds))
        XCTAssertEqual(near, Double(seconds), accuracy: 0.5 / format.sampleRate)
        var afterNear: [Float] = []
        while afterNear.count < window * channels, let chunk = decoder.nextChunk() { afterNear.append(contentsOf: chunk) }
        XCTAssertGreaterThanOrEqual(afterNear.count, window * channels)
        let expected = continuous[(at * channels)..<((at + window) * channels)]
        let worst = zip(afterNear, expected).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4, "the near seek's audio is not the continuous decode's at \(seconds) s")

        let before = counting.bytesRead
        let far = try decoder.seek(toSeconds: 250)
        let seekCost = counting.bytesRead - before
        XCTAssertLessThan(seekCost, 512 * 1024, "the seek read \(seekCost) bytes — it is walking the file")
        XCTAssertEqual(far, 250, accuracy: 5, "landed \(far)")
        XCTAssertNotNil(decoder.nextChunk(), "nothing decoded after the far seek")
    }

    /// **A megabyte-sized ID3v2 tag must be stepped over, not downloaded.**
    ///
    /// `mp3_read_header` parses every APIC frame, so a tag carrying cover art is READ in full
    /// before the demuxer has looked at a single audio frame — and `probesize` does not bound it,
    /// because the tag is consumed before probing starts. Measured on a published 108 MB MP3: a
    /// 13 782 278-byte tag holding a 3000x3000 PNG, and `open()` cost 13.8 MB of cellular data
    /// before a note was heard.
    func testAHugeID3TagIsSteppedOverNotRead() throws {
        try skipUnlessAvailable()
        let tagBytes = 4 * 1024 * 1024
        let url = try GeneratedFixture.mp3BehindID3Tag(bytes: tagBytes)

        let counting = CountingByteReader(try FileByteReader(url: url))
        let decoder = FFmpegStreamDecoder(reader: counting)
        let format = try decoder.open()
        XCTAssertEqual(format.sampleRate, 44100)
        XCTAssertEqual(try XCTUnwrap(format.duration), 20, accuracy: 0.5, "the duration is the AUDIO's, not the file's")

        var frames = 0
        while frames < Int(format.sampleRate), let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        XCTAssertGreaterThanOrEqual(frames, Int(format.sampleRate))
        XCTAssertLessThan(counting.bytesRead, 256 * 1024,
                          "read \(counting.bytesRead) bytes past a \(tagBytes)-byte tag: the tag is being downloaded")
        XCTAssertTrue(counting.seekOffsets.contains { $0 >= Int64(tagBytes) },
                      "no seek past the tag; seeks were \(counting.seekOffsets)")
    }

}
