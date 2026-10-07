# Reference

The public API, product by product. For tasks, see [Integrating](integrating.md). For why the engine
works as it does, see [Architecture](architecture.md).

## Types

| Type | Product | Role |
|---|---|---|
| `StreamByteReader` | PlaybackDecode | Protocol: blocking, seekable bytes. |
| `FileByteReader` | PlaybackDecode | Reader over a local file. `reportsTotalLength: false` imitates a chunked response. |
| `FFmpegStreamDecoder` | PlaybackDecode | `open()`, `seek(toSeconds:)`, `nextChunk()`, `cancel()`, `interrupt()`, `endReason`, `mediaFramesRead`, `bytesConsumed`. |
| `StreamAudioFormat` | PlaybackDecode | Sample rate, channel count, duration (0 if unknown), codec name, container name. |
| `StreamProbeBudget` | PlaybackDecode | Probe bytes and analysis time. Default 64 KiB and 1 s. |
| `StreamDecoderError` | PlaybackDecode | `unavailable`, `invalidState`, `failed(status:)`, `cancelled`, `interrupted`. |
| `StreamByteReaderError` | PlaybackDecode | `cancelled`, `interrupted`, `unseekable`, `transport`. |
| `GrowingFileByteSource` | PlaybackStreaming | `StreamByteReader` over an HTTP(S) URL. |
| `GrowingFileStore` | PlaybackStreaming | The on-disk directory, the complete-file cache and its eviction. |
| `GrowingFileSnapshot`, `GrowingFileEvent` | PlaybackStreaming | What a host reads and hears. |
| `GrowingFileListener` | PlaybackStreaming | A protocol a host implements and wires itself. See below. |
| `LoopbackMediaServer` | PlaybackStreamingTestSupport | Fault-injecting local server for tests. |

`FFmpegStreamDecoder.isAvailable` is true in every build that has the FFmpeg xcframework, which is every
build of this package.

## `StreamByteReader`

- `read(into:maxLength:)` blocks until at least one byte is available. It returns 0 only at end of stream.
- `seek(to:)` throws `.unseekable` if the source cannot serve the offset.
- `totalLength` is nil while unknown. A made-up length breaks MP4 files with a trailing `moov`.
- `cancel()` and `interrupt()` unblock a waiting call from any thread. `cancel()` is permanent. `interrupt()`
  is lifted by `clearInterrupt()`, which the decoder calls on its next seek.

## `FFmpegStreamDecoder`

| Member | Behaviour |
|---|---|
| `init(reader:probeBudget:)` | The budget defaults to `StreamProbeBudget.default`. |
| `open()` | Blocks. Returns a `StreamAudioFormat` or throws `StreamDecoderError`. |
| `nextChunk()` | Blocks. Returns up to `framesPerChunk` (4096) frames of interleaved Float32 at the source rate, or nil. |
| `seek(toSeconds:)` | Returns the landed time, at or before the request, on a codec frame boundary. If the stream ended at the target it returns normally and `endReason` is `.eof`. |
| `cancel()` | Any thread. Ends the stream for good. |
| `interrupt()` | Any thread. Ends only the blocked call. Cleared by the next `seek(toSeconds:)`. |
| `endReason` | `.running`, `.eof`, `.failure`, `.cancelled` or `.interrupted`. |
| `mediaFramesRead` | Media time in frames. After a seek it is set from the landed time. |
| `bytesConsumed` | Bytes the decoder has taken from the reader. |

One thread drives a decoder. `open()` and `nextChunk()` block.

## `GrowingFileByteSource`

`init(url:authHeaders:store:session:onEvent:)`. `authHeaders` arrive already resolved. `store` defaults
to `GrowingFileStore.shared`, a directory under `Caches`.

| Member | Behaviour |
|---|---|
| `isProbing` | While set, a read of the last 128 bytes past the frontier answers end of file at once. Set around the decoder's `open()`. |
| `snapshot` | A `GrowingFileSnapshot`, readable from any thread: `base`, `frontier`, `totalLength`, `isComplete`, `fileURL`, `transactionGeneration`, `seekGeneration`, `downloadBytesPerSecond`. |
| `willSeek(generation:)` | Tags the next transaction a seek opens. Optional. It only affects `seekGeneration` in snapshots and events. |
| `cancel()` | Must be called when done. A running task retains its delegate, which is the source. |

`GrowingFileEvent` has three cases: `transaction` when a response is accepted, `download` at most once
a second while bytes arrive and once at completion, and `seekLanded` when a seek was answered from the
file already there.

A read fails with `StreamByteReaderError.transport` when retries and the 30 s link window are spent.

## `GrowingFileListener`

A protocol, `AnyObject`-constrained. The source has no listener parameter: a host implements the
protocol and calls it from its own `onEvent` closure and player code. The requirements:

| Method | Called |
|---|---|
| `playbackDidStart(file:decoderPosition:)` | Once per media load, before the first transaction opens, with the file and a closure for the decoder's absolute byte offset. Hold `file` weakly. |
| `playerWillSeek(toMs:generation:)` | Before the decoder is told to seek, so a transaction the seek opens can be paired with the target. |
| `growingFile(_:snapshot:)` | For each `GrowingFileEvent`, with a snapshot taken just after. Arrives outside the source's lock. |

## `GrowingFileStore`

| Member | Behaviour |
|---|---|
| `shared` | The default store, in `Caches`. |
| `temporary()` | A store in a fresh temporary directory. |
| `completedFile(for:)` | The cached complete file for a URL, or nil. |
| `sweepPartials()` | Removes `.partial` files left by a killed run. Returns the count. |
| `evict(toBudget:excluding:)` | Removes least recently played files until under the budget. The default budget is 1 GiB. |

## `LoopbackMediaServer`

`init(body:mimeType:)` serves the body at `/fixture.mp3` on the loopback interface, with `Range`
support. `url` is its address and `stop()` shuts it down. Fault knobs include `closesAfterBodyBytes`
(drop the first connection part-way), stalls, refused requests, redirects, and ignoring `Range`.
The package has no fixtures for this product.
