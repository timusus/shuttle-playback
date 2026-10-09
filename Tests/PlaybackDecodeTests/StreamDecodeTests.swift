import AVFoundation
import Foundation
import XCTest

@testable import PlaybackDecode
#if canImport(CStreamDecode)
    import CStreamDecode
#endif

/// The playback decoder's tests.
///
/// The two that matter most are the parity ones — the streamed decode has to sound like the
/// `AVAssetReader` decode of the same file — and `testMoovLastCostsOneSeekNotTheWholeFile`, the
/// only place the trailing-`moov` bandwidth trap is measured rather than assumed.
final class StreamDecodeTests: XCTestCase {

    func skipUnlessAvailable() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    func decodeAll(_ decoder: FFmpegStreamDecoder) -> [Float] {
        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm.append(contentsOf: chunk) }
        return pcm
    }

    // MARK: - Open

    func testOpenReportsSourceFormat() throws {
        try skipUnlessAvailable()
        for name in Fixture.all {
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(name)))
            let format = try decoder.open()
            XCTAssertEqual(format.sampleRate, 44100, "\(name): the player runs at the source's rate")
            XCTAssertEqual(format.channelCount, 2, "\(name)")
            XCTAssertEqual(try XCTUnwrap(format.duration), 20, accuracy: 0.2, "\(name)")
            XCTAssertFalse(format.codec.isEmpty, "\(name)")
            XCTAssertFalse(format.container.isEmpty, "\(name)")
        }
    }

    func testMoovLastAtomOrder() throws {
        /* Guards the bandwidth test below: if a re-encode ever put `moov` first in both fixtures,
         * that test would pass while measuring nothing. */
        let first = try atomOrder(try Fixture.url(Fixture.moovFirst))
        let last = try atomOrder(try Fixture.url(Fixture.moovLast))
        XCTAssertLessThan(first.firstIndex(of: "moov") ?? .max, first.firstIndex(of: "mdat") ?? .max)
        XCTAssertGreaterThan(last.firstIndex(of: "moov") ?? -1, last.firstIndex(of: "mdat") ?? -1)
    }

    let stitches = [
        Stitch(name: "stitch_44k_48k_64k.mp3", rates: (44100, 48000), frames: (155, 168)),
        Stitch(name: "stitch_48k_44k_64k.mp3", rates: (48000, 44100), frames: (168, 155)),
    ]

    let chains = [
        Chain(name: "chained_vorbis_44k_48k.ogg", rates: (44100, 48000), channels: (2, 2), slack: 2048, secondLevel: 1),
        Chain(name: "chained_opus_mono_stereo.opus", rates: (48000, 48000), channels: (1, 2), slack: 2048, secondLevel: 1),
    ]

    // MARK: - Helpers

    /// Top-level MP4 atom types, in file order.
    private func atomOrder(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var order: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            order.append(type)
            guard size >= 8 else { break }
            offset += Int(size)
        }
        return order
    }
}
