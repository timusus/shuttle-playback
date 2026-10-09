import Foundation

// MARK: - The read rule

extension GrowingFileDownload {

    /// **What a read at a position of a growing file does**: the seek-wait rule, pinned with
    /// literal numbers.
    enum ReadRule {

        /// The tail FFmpeg's MP3 open looks at while probing, and why it is the one footer rule
        /// left (ADR-0003): `mp3_read_header` reads an ID3v1 tag from exactly the last 128 bytes
        /// (`ff_id3v1_read`) and an APE footer from the last 32, inside it. Answering that look
        /// with end of file during the probe keeps the head download running.
        static let footerBytes: Int64 = 128

        enum Action: Equatable, Sendable {
            /// `position` is on disk: copy from the file.
            case serve
            /// End of stream: answer 0.
            case endOfStream
            /// Block until bytes land, the body completes, or a cancel or interrupt arrives.
            case wait
            /// Retire the download and open a new transaction at the first hole from `position`.
            case restart
        }

        /// Decided on the first read at a position, never at the seek: the ID3v1 probe seeks to the
        /// footer, reads it and seeks back, and deciding at the seek would cancel the head download for
        /// a read that never needed the network.
        ///
        /// A hole ahead of the frontier is waited for only while the download closes it sooner than a
        /// new request would answer (`gap / rate < responseLatency`); otherwise the download restarts
        /// at the position. media3's `seekToUs` never waits on a seek its buffer cannot
        /// serve: it cancels the loader and loads from the target.
        ///
        /// - Parameters:
        ///   - isCovered: `position` is in a range of the session's file (ADR-0014).
        ///   - frontier: the current transaction's, when it is bringing bytes up to `position`: it
        ///     started at or before it, is not done, and asked for it. Nil restarts a hole.
        ///   - isProbing: the decoder is inside `open()`; a footer look past the frontier is then
        ///     answered EOF at once (FFmpeg reads that as "no footer"). Outside the probe the same read
        ///     waits, or the last frames would be cut.
        ///   - rangeIgnored: the host answered a ranged request with `200`; a restart would only be
        ///     answered from byte 0 again, so everything ahead is waited for.
        ///   - downloadBytesPerSecond: the observed download rate; nil (no sample yet) restarts.
        ///   - responseLatency: how long this source's last accepted response took to arrive after
        ///     its request went out; nil (none yet) restarts.
        static func action(
            position: Int64,
            isCovered: Bool,
            frontier: Int64?,
            totalLength: Int64?,
            isProbing: Bool,
            rangeIgnored: Bool,
            downloadBytesPerSecond: Double?,
            responseLatency: TimeInterval?
        ) -> Action {
            if isCovered { return .serve }
            if let totalLength, position >= totalLength { return .endOfStream }
            guard let frontier, position >= frontier else { return .restart }
            if isProbing, let totalLength, position >= totalLength - footerBytes { return .endOfStream }
            if position == frontier || rangeIgnored { return .wait }
            guard let downloadBytesPerSecond, downloadBytesPerSecond > 0, let responseLatency else { return .restart }
            return Double(position - frontier) / downloadBytesPerSecond < responseLatency ? .wait : .restart
        }
    }
}
