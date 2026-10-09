import XCTest
@testable import PlaybackStreaming
import PlaybackDecode
import PlaybackStreamingTestSupport

/// The decoder reads the growing file exactly as it reads the same bytes on disk: the same PCM,
/// to the sample, under a drip, a `moov` at the end and a dropped connection (the byte-source
/// contract's decode-equality cases for this source).
final class GrowingFileDecodeTests: XCTestCase {

    static let testSession = GrowingFileByteSource.makeSession(configuration: .ephemeral)

    private var directory: URL!
    private var server: LoopbackMediaServer?
    private var source: GrowingFileByteSource?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("growing-decode-\(UUID().uuidString)")
    }

    override func tearDown() {
        source?.cancel()
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func decodeAll(
        _ reader: StreamByteReader, probing: GrowingFileByteSource? = nil, afterOpen: () -> Void = {}
    ) throws -> [Float] {
        let decoder = FFmpegStreamDecoder(reader: reader)
        probing?.isProbing = true
        try decoder.open()
        probing?.isProbing = false
        afterOpen()
        var samples: [Float] = []
        while let chunk = decoder.nextChunk() { samples += chunk }
        XCTAssertEqual(decoder.endReason, .eof)
        return samples
    }

    private func assertDecodesAsOnDisk(
        _ name: String, _ ext: String, mimeType: String, configure: (LoopbackMediaServer) -> Void = { _ in },
        afterOpen: (LoopbackMediaServer) -> Void = { _ in }
    ) throws -> GrowingFileByteSource {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
        let expected = try decodeAll(FileByteReader(url: fixture))
        XCTAssertFalse(expected.isEmpty)

        let server = try LoopbackMediaServer(body: Data(contentsOf: fixture), mimeType: mimeType)
        self.server = server
        configure(server)
        let source = GrowingFileByteSource(
            url: server.url, authHeaders: [:], store: GrowingFileStore(directory: directory), session: Self.testSession
        )
        self.source = source
        let actual = try decodeAll(source, probing: source) { afterOpen(server) }
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual == expected, "the PCM differs from the file's")
        return source
    }

    func testADrippedMP3DecodesAsOnDisk() throws {
        let source = try assertDecodesAsOnDisk("tone-45s", "mp3", mimeType: "audio/mpeg", configure: {
            $0.bytesPerSecond = 256 * 1024
        })
        XCTAssertEqual(source.snapshot.transactionGeneration, 1, "a head-first file never needs a restart")
    }

    func testAnM4AWithItsIndexAtTheEndDecodesAsOnDisk() throws {
        // Slow enough that the index at the tail is more than 3 s of download away.
        let source = try assertDecodesAsOnDisk("tone_moov_last", "m4a", mimeType: "audio/mp4", configure: {
            $0.bytesPerSecond = 32 * 1024
        })
        XCTAssertGreaterThan(source.snapshot.transactionGeneration, 1, "the index fetch is its own transaction")
        // Head, tail and the media between, from three transactions, are one file (ADR-0014).
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tone_moov_last", withExtension: "m4a", subdirectory: "Fixtures"))
        let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: try XCTUnwrap(server).url))
        XCTAssertEqual(try Data(contentsOf: cached), try Data(contentsOf: fixture))
    }

    func testAnMP3WhoseConnectionDropsMidBodyDecodesAsOnDisk() throws {
        // The drop comes once the decoder has opened: the probe's footer look is over and the
        // decoder reads inside the file, so the retry is a resume from where the body stopped. A
        // drop timed by the server instead could land during that look and be a restart.
        let source = try assertDecodesAsOnDisk("tone-45s", "mp3", mimeType: "audio/mpeg", configure: {
            $0.heldBodyAfterBytesForRangeStartingAt = [0: 50_000]
        }, afterOpen: {
            XCTAssertTrue($0.dropHeldBody(forRangeStartingAt: 0), "the body was not held when the decoder opened")
        })
        let server = try XCTUnwrap(self.server)
        XCTAssertEqual(server.requestedRanges, [0, 50_000], "the retry did not resume from the frontier")
        XCTAssertTrue(server.requestHeads.last?.lowercased().contains("range: bytes=50000-") ?? false)
        XCTAssertEqual(source.snapshot.transactionGeneration, 1, "the retry resumes the same file")
    }
}
