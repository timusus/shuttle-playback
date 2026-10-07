import Foundation

/// **The growing file's listener**: a host's view of the bytes the decoder plays
/// (growing-file plan §5). It is handed the file rather than every chunk: the listener reads the
/// bytes back from it (`GrowingFileSnapshot.fileURL`), so it can never see a byte the decoder did
/// not have, nor run a second fetch. Nil for a local file.
///
/// Ordering is the source's: `growingFile(_:snapshot:)` arrives outside the source's lock, on the
/// session's delegate queue or the decoder's thread, so a listener may read the snapshot again.
public protocol GrowingFileListener: AnyObject {

    /// Once per media load, before the first transaction opens: the file and the decoder's read
    /// position (its absolute byte offset). Hold `file` weakly: the source holds the listener.
    func playbackDidStart(file: any GrowingFileSnapshotSource, decoderPosition: @escaping () -> Int64)

    /// The player is about to move the decoder to `ms`. Announced before the decoder is told, so
    /// a transaction the seek opens (its snapshot's `seekGeneration` equals `generation`) can be
    /// paired with the target.
    func playerWillSeek(toMs ms: Int64, generation: Int)

    /// A transaction was accepted or the download moved; `snapshot` was taken just after.
    func growingFile(_ event: GrowingFileEvent, snapshot: GrowingFileSnapshot)
}
