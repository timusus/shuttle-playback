import Foundation
import Testing

@testable import PlaybackStreaming

/// Reading a response's headers, per RFC 9110's Content-Range forms.
extension GrowingFileDownloadTests {

    @Test("a Content-Range gives its start and total, a nil total for *, and nothing when malformed")
    func contentRangeParses() {
        #expect(GrowingFileDownload.contentRange("bytes 100-199/1000")! == (100, 1000))
        #expect(GrowingFileDownload.contentRange("bytes 0-99/*")! == (0, nil))
        #expect(GrowingFileDownload.contentRange("bytes */1000") == nil)
        #expect(GrowingFileDownload.contentRange("items 0-99/1000") == nil)
        #expect(GrowingFileDownload.contentRange("bytes x-99/1000") == nil)
        #expect(GrowingFileDownload.contentRange(nil) == nil)
    }

    @Test("a 416 for */base or a 206 clamped to end at base says the resource ends at base; nothing else does")
    func totalEndingAtReadsOnlyAnEndAtTheBase() {
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 416, contentRange: "bytes */1000") == 1000)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 416, contentRange: "bytes */2000") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 206, contentRange: "bytes 900-999/1000") == 1000)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 206, contentRange: "bytes 1000-1099/2000") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 206, contentRange: "bytes 900-999/*") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 200, contentRange: "bytes */1000") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 416, contentRange: nil) == nil)
    }

    @Test("a page type is never media, an audio or video type always is, and an unnamed type waits for the sniff")
    func isMediaByType() {
        #expect(GrowingFileDownload.isMedia(mimeType: "text/html") == false)
        #expect(GrowingFileDownload.isMedia(mimeType: "Application/XHTML+XML") == false)
        #expect(GrowingFileDownload.isMedia(mimeType: "audio/mpeg") == true)
        #expect(GrowingFileDownload.isMedia(mimeType: "video/mp4") == true)
        #expect(GrowingFileDownload.isMedia(mimeType: "application/ogg") == true)
        #expect(GrowingFileDownload.isMedia(mimeType: "application/octet-stream") == nil)
        #expect(GrowingFileDownload.isMedia(mimeType: nil) == nil)
        #expect(GrowingFileDownload.isMedia(mimeType: "application/octet-stream", head: Array("ID3".utf8)) == false)
    }
}
