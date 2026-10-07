import Foundation

/// **What a read at a position of a growing file does**: the seek-wait rule, with no source, lock or
/// clock, so every branch is pinned with literal numbers.
enum GrowingFileReadRule {

    /// A gap ahead of the frontier that the download closes in less than this is waited for; a
    /// longer one restarts the download at the position. One named number, no byte floor.
    static let seekWaitSeconds: Double = 3
    /// The ID3v1 footer FFmpeg's mp3 open reads: exactly the last 128 bytes.
    static let footerBytes: Int64 = 128

    enum Action: Equatable, Sendable {
        /// `position` is in `[base, frontier)`: copy from the file.
        case serve
        /// End of stream: answer 0.
        case endOfStream
        /// Block until bytes land, the body completes, or a cancel or interrupt arrives.
        case wait
        /// Cancel the download and open a new transaction, into a new file, at `position`.
        case restart
    }

    /// Decided on the first read at a position, never at the seek: the ID3v1 probe seeks to the
    /// footer, reads it and seeks back, and deciding at the seek would cancel the head download for
    /// a read that never needed the network.
    ///
    /// - Parameters:
    ///   - isProbing: the decoder is inside `open()`; a footer look past the frontier is then
    ///     answered EOF at once (FFmpeg reads that as "no footer"). Outside the probe the same read
    ///     waits, or the last frames would be cut.
    ///   - rangeIgnored: the host answered a ranged request with `200`; a restart would only be
    ///     answered from byte 0 again, so everything ahead is waited for.
    ///   - downloadBytesPerSecond: the observed download rate; nil (no sample yet) restarts.
    static func action(
        position: Int64,
        base: Int64,
        frontier: Int64,
        totalLength: Int64?,
        isComplete: Bool,
        isProbing: Bool,
        rangeIgnored: Bool,
        downloadBytesPerSecond: Double?
    ) -> Action {
        if position >= base, position < frontier { return .serve }
        if let totalLength, position >= totalLength { return .endOfStream }
        if position < base { return .restart }
        if isComplete { return .endOfStream }
        if isProbing, let totalLength, position >= totalLength - footerBytes { return .endOfStream }
        if position == frontier || rangeIgnored { return .wait }
        guard let downloadBytesPerSecond, downloadBytesPerSecond > 0 else { return .restart }
        return Double(position - frontier) / downloadBytesPerSecond < seekWaitSeconds ? .wait : .restart
    }
}
