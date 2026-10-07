import Foundation
import XCTest

@testable import PlaybackDecode

/// #21: FLAC, ALAC and PCM WAV/AIFF open without `avformat_find_stream_info` (the header already
/// describes them); everything else still probes. The skip must decode what the probe does, and
/// `forcesProbe` restores the probe.
final class ProbeSkipTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackDecodeConformanceTests/Fixtures/\(name)")
    }

    private func open(_ name: String, forcesProbe: Bool, reportsTotalLength: Bool = true) throws
        -> (FFmpegStreamDecoder, StreamAudioFormat)
    {
        let reader = try FileByteReader(url: url(name), reportsTotalLength: reportsTotalLength)
        let decoder = FFmpegStreamDecoder(reader: reader, forcesProbe: forcesProbe)
        return (decoder, try decoder.open())
    }

    private func firstSamples(_ decoder: FFmpegStreamDecoder, channels: Int, frames: Int = 8192) -> [Float] {
        var buffer = [Float](repeating: 0, count: frames * channels)
        let n = buffer.withUnsafeMutableBufferPointer { decoder.read(into: $0.baseAddress!, maxFrames: frames) }
        return Array(buffer[0..<(n * channels)])
    }

    private func assertSkipMatchesProbe(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let (skipping, skipFormat) = try open(name, forcesProbe: false)
        let (probing, probeFormat) = try open(name, forcesProbe: true)
        XCTAssertTrue(skipping.skippedProbe, "\(name) should skip the probe", file: file, line: line)
        XCTAssertFalse(probing.skippedProbe, "\(name) with forcesProbe", file: file, line: line)
        XCTAssertEqual(skipFormat, probeFormat, name, file: file, line: line)
        XCTAssertLessThanOrEqual(skipping.bytesConsumed, probing.bytesConsumed, name, file: file, line: line)
        let channels = skipFormat.channelCount
        let skipped = firstSamples(skipping, channels: channels)
        XCTAssertFalse(skipped.isEmpty, file: file, line: line)
        XCTAssertEqual(skipped, firstSamples(probing, channels: channels), name, file: file, line: line)
    }

    func testFLACSkipsTheProbeAndDecodesTheSame() throws { try assertSkipMatchesProbe("flac_stereo.flac") }
    func testALACSkipsTheProbeAndDecodesTheSame() throws { try assertSkipMatchesProbe("alac_stereo.m4a") }
    func testWAVSkipsTheProbeAndDecodesTheSame() throws {
        try assertSkipMatchesProbe("wav_s16.wav")
        try assertSkipMatchesProbe("wav_s24.wav")
    }
    func testAIFFSkipsTheProbeAndDecodesTheSame() throws { try assertSkipMatchesProbe("aiff_s16.aiff") }

    func testASourceWithoutALengthSkipsTheProbeAndReadsLess() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let (skipping, _) = try open("wav_s24.wav", forcesProbe: false, reportsTotalLength: false)
        let (probing, _) = try open("wav_s24.wav", forcesProbe: true, reportsTotalLength: false)
        XCTAssertTrue(skipping.skippedProbe)
        XCTAssertFalse(probing.skippedProbe)
        // Today's figure for this open is 131072 bytes, a 32 KiB read per probe step.
        XCTAssertLessThanOrEqual(skipping.bytesConsumed, 32 * 1024)
        XCTAssertGreaterThanOrEqual(probing.bytesConsumed, 4 * skipping.bytesConsumed)
    }

    /// A streamed recorder leaves the RIFF and data sizes at 0 or 0xFFFFFFFF. With a known source
    /// length the probe recovers the duration from the file size, so the skip must not lose it.
    func testWAVWithUnsizedHeaderKeepsItsDurationWhenTheLengthIsKnown() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let original = try Data(contentsOf: url("wav_s16.wav"))
        for fill: UInt32 in [0, 0xFFFF_FFFF] {
            var data = original
            let dataChunk = try XCTUnwrap(data.range(of: Data("data".utf8)), "no data chunk")
            for offset in [4, dataChunk.upperBound] {
                for i in 0..<4 { data[offset + i] = UInt8((fill >> (8 * UInt32(i))) & 0xFF) }
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("unsized-\(fill)-\(UUID().uuidString).wav")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            func decode(forcesProbe: Bool) throws -> (StreamAudioFormat, [Float]) {
                let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: tmp), forcesProbe: forcesProbe)
                let format = try decoder.open()
                return (format, firstSamples(decoder, channels: format.channelCount, frames: 4096))
            }
            let (format, pcm) = try decode(forcesProbe: false)
            let (probedFormat, probedPCM) = try decode(forcesProbe: true)
            XCTAssertNotNil(probedFormat.duration, "fill \(fill): the probe should recover a duration")
            XCTAssertNotNil(format.duration, "fill \(fill)")
            XCTAssertEqual(format.duration, probedFormat.duration, "fill \(fill)")
            XCTAssertEqual(pcm, probedPCM, "fill \(fill)")
        }
    }

    func testLossyFormatsStillProbe() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        for name in ["cbr_info_64k.mp3", "aac_edit_list.m4a", "adts_id3.aac", "opus_stereo.opus", "vorbis_stereo.ogg"] {
            let (decoder, _) = try open(name, forcesProbe: false)
            XCTAssertFalse(decoder.skippedProbe, name)
        }
    }
}
