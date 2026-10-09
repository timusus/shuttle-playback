import Foundation
import PlaybackDecode

extension GrowingFileDownload {

    // MARK: - Effects and events

    /// A request for the current transaction: `Range: bytes=<from>-`, to `url`.
    struct Request: Equatable {
        /// Names this request; a timer or a callback for an earlier one changes nothing.
        let attempt: Int
        let url: URL
        let from: Int64
        /// The resume's validator: the first response's strong ETag.
        let ifRange: String?
    }

    enum Timer: Equatable {
        /// The backoff of a failed transaction is over: resume or restart it.
        case retry(transaction: Int)
        /// The request has had its wait for a response.
        case response(attempt: Int)
        /// Look whether the body has been silent for ``GrowingFileByteSource/idleTimeoutSeconds``.
        case idle(transaction: Int)
        /// A parked read looks again.
        case recheck
    }

    /// What the adapter does, in order, under its lock unless said otherwise.
    enum Effect: Equatable {
        /// Cancel the current transaction's task and, when `discardFile`, delete its file.
        case retire(discardFile: Bool)
        /// Drop the current transaction: there is none until the next open.
        case release
        /// Make a new partial for the next transaction and report it with ``opened(fileReady:now:)``.
        case openFile
        /// Cancel the current task.
        case cancelTask
        /// Send `request` as the current transaction's task.
        case send(Request)
        case schedule(Timer, after: TimeInterval)
        /// Wake parked reads.
        case wake
        /// Rename the complete file into the cache and report it with ``promoted()``.
        case promote
        /// After the lock is released: reserve room in the store for this many bytes.
        case makeRoom(bytes: Int64)
        /// After the lock is released.
        case emit(GrowingFileEvent)
    }

    /// The parts of a response the lifecycle decides on.
    struct Response: Equatable {
        var status: Int
        var contentRange: String?
        var mimeType: String?
        /// `expectedContentLength`, -1 when unknown.
        var expectedContentLength: Int64 = -1
        var entityTag: String?
        /// Where the response came from: the redirect chain's end.
        var url: URL?
    }

    /// A read's next step: carry out `effects`, then do `action`.
    struct ReadStep: Equatable {
        enum Action: Equatable {
            /// Copy `count` bytes at `fileOffset` of the current file, then ``advance(by:)``.
            /// `landed`: report that seek's landing first.
            case serve(fileOffset: Int64, count: Int, landed: Int?)
            /// Answer 0, after reporting `landed`.
            case endOfStream(landed: Int?)
            /// Wait for a wake.
            case park
            /// Ask again at once: a transaction was opened.
            case again
            case fail(StreamByteReaderError)
        }

        var effects: [Effect]
        var action: Action
    }

    // MARK: - One transaction

    /// One transaction's state: one file, one base, one or more requests (a resume is another).
    struct Transaction: Equatable {
        let id: Int
        var generation: Int
        var seekGeneration: Int?
        /// False once the partial is deleted: nothing of it is readable any more.
        var hasFile = true
        /// The current request went to the redirect chain's remembered end, not the requested URL.
        var remembered: Bool
        /// The current request's ``Request/attempt``.
        var attempt = 0
        /// A resume is in flight: the byte its `206` must start at. Nil once it is answered.
        var resumeAt: Int64?
        /// The first response's strong ETag, the resume's `If-Range`.
        var entityTag: String?
        var base: Int64
        /// This transaction's own, from its response; never inherited from an earlier transaction's body.
        var totalLength: Int64?
        /// Bytes in the file.
        var written: Int64 = 0
        /// The body's first bytes are not yet proven to be media; nothing is readable until they are.
        var sniffPending = false
        /// A response arrived, whatever it said. A failure before one is the link's, not the host's.
        var answered = false
        /// The time the current request went out.
        var attemptStartedAt: TimeInterval = 0
        /// Done with the network: complete, failed, or handed to a retry.
        var ended = false
        var isComplete = false
        var isCached = false
        /// The time of the response or the last body chunk, whichever came later.
        var lastByteAt: TimeInterval = 0
        /// An idle check is scheduled; one at a time.
        var idleCheckPending = false
        /// The read-ahead cap cancelled the request (ADR-0013): `ended`, though nothing failed, until
        /// a resume from the frontier once the decoder comes within half the cap.
        var paused = false
        /// The rate measured when it paused, which the read rule goes on using until the resumed request delivers.
        var rateAtPause: Double?
        /// The host answered this transaction's range with a `206` from its base.
        var rangeHonoured = false
        var frontier: Int64 { base + (sniffPending || !hasFile ? 0 : written) }
    }
}
