# Reference

The public API, product by product. For tasks, see [Integrating](integrating.md). For why the engine
works as it does, see [Architecture](architecture.md).

## Types

| Type | Product | Role |
|---|---|---|
| `StreamByteReader` | PlaybackDecode | Protocol: blocking, seekable bytes. |
| `FileByteReader` | PlaybackDecode | Reader over a local file. `reportsTotalLength: false` imitates a chunked response. |
| `FFmpegStreamDecoder` | PlaybackDecode | `open()`, `setOutputFormat(sampleRate:channelCount:)`, `seek(toSeconds:)`, `nextChunk()`, `read(into:maxFrames:)`, `cancel()`, `interrupt()`, `endReason`, `mediaFramesRead`, `bytesConsumed`. |
| `StreamAudioFormat` | PlaybackDecode | Sample rate, channel count, duration (`nil` if unknown), codec name, container name. |
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
| `init(reader:probeBudget:forcesProbe:)` | The budget defaults to `StreamProbeBudget.default`. `forcesProbe` (default `false`) always runs FFmpeg's stream-info probe; without it the probe is skipped for FLAC, ALAC (MP4) and PCM WAV/AIFF, whose header already describes the stream, and runs for everything else (#21). |
| `skippedProbe` | True after `open()` when the probe was skipped. A caller whose open turns out wrong can retry with `forcesProbe: true`. |
| `open()` | Blocks. Returns a `StreamAudioFormat` (the source's) or throws `StreamDecoderError`. |
| `setOutputFormat(sampleRate:channelCount:)` | Optional. Fixes the output rate and channel count for everything read afterwards: swresample resamples, downmixes by its default matrix (5.1 to stereo, stereo to mono) and duplicates mono to every channel at full level. Only between `open()` and the first read or seek; may be called again in that window. Throws `invalidState` after it, before `open()`, or for a rate or channel count <= 0. |
| `nextChunk()` | Blocks. Returns up to `framesPerChunk` (4096) frames of interleaved Float32 at the output format (the source's unless set), or nil. |
| `read(into:maxFrames:)` | Blocks. Fills a caller buffer of `maxFrames` × output channels floats and returns the frames written, or 0 where `nextChunk()` returns nil. `maxFrames` must be > 0 (a precondition), so 0 only ever means the stream ended. The same samples as `nextChunk()` without an allocation per call; the two may be mixed. |
| `seek(toSeconds:)` | Returns the landed time in media seconds: the requested sample, or an estimate in a VBR MP3 far from a frame of known time. At a non-native output rate the first frame after it is within one output frame of that time (the resampler restarts at the landing). Exact in time and frame count, but not bit-identical to the uninterrupted decode for its first few frames, while the restarted resampler warms up (idea #27). If the stream ended at the target it returns normally and `endReason` is `.eof`. |
| `cancel()` | Any thread. Ends the stream for good. |
| `interrupt()` | Any thread. Ends only the blocked call. Cleared by the next `seek(toSeconds:)`. |
| `endReason` | `.running`, `.eof`, `.failure`, `.cancelled` or `.interrupted`. |
| `mediaFramesRead` | Media time in frames at the output rate. After a seek it is set from the landed time. |
| `bytesConsumed` | Bytes the decoder has taken from the reader. |

One thread drives a decoder. `open()`, `nextChunk()` and `read(into:maxFrames:)` block.

## `GrowingFileByteSource`

`init(url:authHeaders:cacheKey:connectionPolicy:store:session:onEvent:)`. `authHeaders` arrive already resolved,
and are sent only to `url`'s origin (same scheme, host and port): a redirect to another origin, such as a CDN,
is requested without them, and so are later requests to that remembered end. `connectionPolicy` (default nil)
is a `GrowingFileConnectionPolicy`, below. `store` defaults
to `GrowingFileStore.shared`, a directory under `Caches`. `cacheKey` (default nil) is the URL the completed-file
cache knows the resource by. Pass the URL without its token or session query parameters (Jellyfin, Emby,
Subsonic) so each new session reuses the cached file instead of adding a duplicate; requests still go to `url`.
Ask the store for `completedFile(for:)` with the same key. Nil keys the cache by `url`.

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

When the device's network path changes to another usable one (Wi-Fi to cellular, back online after
none), the source reopens a transaction in flight from the download frontier at once instead of
waiting out the 6 s idle timeout (`idleTimeoutSeconds`). This is automatic, through one shared
`NWPathMonitor`, and spends the same retry budget as any other failure; there is nothing to call.

A read at exactly the end before the length is known returns 0, as media3's `DefaultHttpDataSource`
does: the host's `416` with `Content-Range: bytes */N` (or a range clamped to the last byte of `N`) at
position `N` is a zero-length open, and `totalLength` becomes `N`. Any other `416` is a refusal,
retried and then failed as before, and so is an `N` that differs from a length already known.

### `GrowingFileConnectionPolicy`

`Sendable`, `Equatable`; passed at init, per source. Applies to `url`'s origin only.

| Member | Behaviour |
|---|---|
| `headers` | Extra request headers, sent after `authHeaders` (these win a clash). Dropped on a redirect to another origin, like `authHeaders`. |
| `trustedLeafSHA256` | `Set<String>`: SHA-256 fingerprints of whole leaf certificates (DER) the user trusted for the origin, a trust exception rather than a restriction (this is how a self-signed server is trusted). The origin's chain is first evaluated by the system: if it is trusted, default handling applies whatever these hold. If it is refused, it is accepted only when its leaf (the first certificate, the one whose key the handshake proves) has one of these fingerprints, waiving the system's roots, expiry and host name check for that leaf; a matching certificate further up the chain counts for nothing. Otherwise the challenge is cancelled and the read fails with `untrustedCertificateReason`. Hex in any case, with or without separators; kept upper-case without separators. Empty (the default) leaves the system's evaluation alone. Other origins, such as a CDN redirect, always use the system's trust. Matches Shuttle2's `handleServerTrust`. |
| `leafSHA256(of:)` | Static. The fingerprint of a DER certificate in the form `trustedLeafSHA256` keeps: SHA-256 of the whole certificate, upper-case hex, no separators (Shuttle2's `fingerprintOf`). |
| `untrustedCertificateReason` | `"untrusted_certificate"`: the `StreamByteReaderError.transport` reason of a read whose certificate the system refused and whose leaf is not trusted. It fails at once and is never retried. |

The challenge is answered by the source as the task's delegate, so one shared `URLSession` serves sources
with different policies.

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
| `init(directory:budgetBytes:)` | A store over its own directory with its own complete-file budget (default `GrowingFileStore.budgetBytes`, 1 GiB). Stores with different directories never see or evict each other's files. |
| `budget` | This store's ceiling. |
| `evict(toBudget:excluding:)` | Removes least recently played files of this store until under `toBudget`, by default the store's `budget`. |

## `LoopbackMediaServer`

`init(body:mimeType:)` serves the body at `/fixture.mp3` on the loopback interface, with `Range`
support. `url` is its address and `stop()` shuts it down. Fault knobs include `closesAfterBodyBytes`
(drop the first connection part-way), stalls, refused requests, redirects, and ignoring `Range`.
The package has no fixtures for this product.
