import Foundation
import Testing

@testable import PlaybackStreaming

/// The body sniff for a host that names no audio type: every container the FFmpeg build can
/// demux is taken, a page is not.
extension GrowingFileDownloadTests {

    private static let containers: [(name: String, head: [UInt8])] = [
        ("MP3 frame sync", [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 8)),
        ("ID3 tag", Array("ID3".utf8) + [UInt8](repeating: 0, count: 9)),
        ("ADTS", [0xFF, 0xF1, 0x50, 0x80] + [UInt8](repeating: 0, count: 8)),
        ("LOAS", [0x56, 0xE0, 0x20, 0x00] + [UInt8](repeating: 0, count: 8)),
        ("MP4", [0, 0, 0, 0x20] + Array("ftypM4A ".utf8)),
        ("Ogg", Array("OggS".utf8) + [UInt8](repeating: 0, count: 8)),
        ("FLAC", Array("fLaC".utf8) + [UInt8](repeating: 0, count: 8)),
        ("WAV", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)),
        ("RF64", Array("RF64".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WAVE".utf8)),
        ("AIFF", Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8)),
        ("AIFC", Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFC".utf8)),
        ("Matroska", [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 8)),
    ]

    @Test("a body of any enabled container is taken when served as application/octet-stream")
    func everyContainerSniffsAsMedia() {
        for container in Self.containers {
            let h = Harness()
            _ = h.read()
            #expect(h.respond(200, length: 100_000, mimeType: "application/octet-stream"), "\(container.name)")
            h.body(12, head: container.head)
            guard case .serve = h.read() else {
                Issue.record("\(container.name) was refused")
                continue
            }
        }
    }

    @Test("a page served as application/octet-stream is refused")
    func aPageDoesNotSniffAsMedia() {
        let h = Harness()
        _ = h.read()
        #expect(h.respond(200, length: 100_000, mimeType: "application/octet-stream"))
        h.body(12, head: Array("<!DOCTYPE ht".utf8))
        guard case .fail = h.read() else {
            Issue.record("a page was taken")
            return
        }
    }

    @Test("the sniff list names exactly the demuxers scripts/build-ffmpeg.sh enables")
    func sniffListMatchesTheDemuxerList() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build-ffmpeg.sh")
        let line = try String(contentsOf: script, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("DEMUXERS=") }
        let enabled = try #require(line).dropFirst("DEMUXERS=".count).split(separator: ",").map(String.init)
        #expect(Set(GrowingFileDownload.sniffers.map(\.demuxer)) == Set(enabled))
    }
}
