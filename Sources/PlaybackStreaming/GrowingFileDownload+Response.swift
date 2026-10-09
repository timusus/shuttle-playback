import Foundation

// MARK: - Reading a response

extension GrowingFileDownload {

    /// `X` and `Z` of `bytes X-Y/Z`; `Z` is nil for `*`.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst("bytes ".count).split(whereSeparator: { "-/".contains($0) })
        guard parts.count == 3, let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, Int64(parts[2].trimmingCharacters(in: .whitespaces)))
    }

    /// The resource's total when an answer says it ends exactly at `base` (a request's start or a
    /// resume's frontier): a `416` with `Content-Range: bytes */<base>`, or a `206` clamped to the
    /// last byte (`bytes X-Y/<base>` with `X` before `base`). Nil for any other answer.
    static func totalEndingAt(_ base: Int64, status: Int, contentRange header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count)
        let total: Int64?
        switch status {
        case 416:
            guard spec.hasPrefix("*/") else { return nil }
            total = Int64(spec.dropFirst(2).trimmingCharacters(in: .whitespaces))
        case 206:
            guard let range = contentRange(header), range.start < base else { return nil }
            total = range.total
        default:
            return nil
        }
        return total == base ? base : nil
    }

    /// Whether a body is media. A page by its type, what a signed URL past its expiry
    /// answers with, never is; an audio or video type is. Otherwise (`application/octet-stream`
    /// names nothing) the body's first ``GrowingFileByteSource/sniffBytes`` decide when given: an
    /// mp3 or ADTS frame sync, an ID3 tag, or a container's magic, which a page never starts with.
    /// Nil: undecided.
    static func isMedia(mimeType: String?, head: [UInt8]? = nil) -> Bool? {
        let type = mimeType?.lowercased() ?? ""
        if type == "text/html" || type == "application/xhtml+xml" { return false }
        if type.hasPrefix("audio/") || type.hasPrefix("video/") || type == "application/ogg" { return true }
        guard let head else { return nil }
        guard head.count >= GrowingFileByteSource.sniffBytes else { return false }
        if head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return true }
        let magic = String(decoding: head[0..<4], as: UTF8.self)
        return magic.hasPrefix("ID3") || ["OggS", "fLaC", "RIFF"].contains(magic)
            || String(decoding: head[4..<8], as: UTF8.self) == "ftyp"
    }
}
