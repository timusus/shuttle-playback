import Foundation

/// **How far a ``GrowingFileByteSource`` may download ahead of the decoder on an expensive path**
/// (ADR-0013). While the network path is expensive or constrained (cellular, a hotspot, Low Data
/// Mode), the source cancels its request once the frontier is `bytes` ahead of the decoder's read
/// position, and resumes from the frontier when the decoder comes within half of that. On a cheap
/// path, and for a host that ignores ranges, the file downloads whole.
///
/// The cap is in bytes; the host converts from seconds with the stream's bitrate.
public struct GrowingFileReadAhead: Equatable, Sendable {
    public let bytes: Int64

    public init(bytes: Int64) {
        precondition(bytes > 0, "a read-ahead of \(bytes) bytes")
        self.bytes = bytes
    }
}
