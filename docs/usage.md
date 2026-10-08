# Usage

From adding the package to decoding a file and playing a URL while it downloads. Signatures and
parameters are in the doc comments of the types named here; this page covers the order of calls and the
behaviour you must know. Threading and blocking apply throughout: `open()`, `nextChunk()`,
`read(into:maxFrames:)` and `seek(toSeconds:)` block, so run them on a thread of your own, one thread per decoder.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "PlaybackDecode", package: "shuttle-playback"),
        .product(name: "PlaybackStreaming", package: "shuttle-playback"),   // only to play URLs
    ]),
]
```

Pin a tag, never a branch. `PlaybackDecode` links the system libraries the static FFmpeg needs. The
`FFmpeg` product is only for an app with its own C code against libavformat: it carries no linker
settings (a binary target cannot), so the app adds CoreFoundation, CoreMedia, CoreVideo and
VideoToolbox, `z` and `iconv` itself, and must link exactly one FFmpeg.

## Decode a file

```swift
import PlaybackDecode

let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let format = try decoder.open()          // sampleRate, channelCount, duration (nil if unknown), codec, container

while let chunk = decoder.nextChunk() {  // [Float], interleaved, up to 4096 frames
    // schedule `chunk` at format.sampleRate, format.channelCount channels
}
if decoder.endReason != .eof { /* .failure, .cancelled or .interrupted */ }
```

`nextChunk()` returning nil is not always the end of the file: check `endReason`, or a network failure
looks like a short track. Output is Float32 at the source's own rate, not resampled.

`open()` throws `StreamDecoderError`; a format the build lacks arrives as `.failed(status:)`. The probe
is budgeted at 64 KiB / 1 s (libavformat's own is 5 MB / 5 s); a heavier file passes
`probeBudget: StreamProbeBudget(bytes:analyzeDuration:)` to the initialiser. Header-described formats
(FLAC, ALAC, WAV) skip the probe (`skippedProbe`); `forcesProbe: true` restores it.

**Fixed output format.** A player running one graph across tracks (gapless, mixed sample rates) calls
`setOutputFormat(sampleRate:channelCount:)` after `open()` and before the first read or seek. The
decoder then resamples and remixes every frame (mono is spread to every channel at full level).
`read(into:maxFrames:)` fills your buffer without allocating. A seek still returns media seconds
([ADR-0010](decisions/0010-the-decoder-owns-output-format-conversion.md)).

## Play a URL while it downloads

```swift
import PlaybackDecode
import PlaybackStreaming

let source = GrowingFileByteSource(
    url: url,
    authHeaders: ["Authorization": "Bearer \(token)"],   // already resolved; [:] for none
    onEvent: { event in /* .transaction, .download, .seekLanded */ }
)
defer { source.cancel() }

let decoder = FFmpegStreamDecoder(reader: source)
source.isProbing = true
let format = try decoder.open()
source.isProbing = false

while let chunk = decoder.nextChunk() { /* schedule it */ }
```

- **Always call `cancel()`.** A running URLSession task retains its delegate, which is the source.
  Without it the source and its partial file leak.
- **Set `isProbing` around `open()`.** FFmpeg's MP3 open reads the last 128 bytes (an ID3v1 footer).
  While probing, that read answers end of file at once instead of cancelling the head download
  ([ADR-0003](decisions/0003-growing-file-playback.md)).
- **The decoder blocks while it waits for bytes.** That is how buffering shows up. The source retries
  drops itself; a read throws `StreamByteReaderError.transport` only when retries and the 30 s link
  window are spent, after the bytes already downloaded have been read. Play out what you have decoded,
  then show an error at that position.
- **Do not re-seek or recreate the source on a network change.** The source watches the network path and
  resumes from its frontier. A host that does the same races it
  ([ADR-0004](decisions/0004-one-recovery-layer-in-the-byte-source.md)).
- **Auth headers stay on the origin.** A redirect to another origin (a CDN) and its later restarts carry
  none of them.
- **Extra headers.** `GrowingFileConnectionPolicy.headers` adds request headers for the origin, with the same redirect rule as `authHeaders`.
- **Self-signed servers.** Pass `connectionPolicy: GrowingFileConnectionPolicy(trustedLeafSHA256: [...])`
  with the fingerprint the user trusted. It is an exception, not a pin: the system evaluates first,
  and only a certificate it refuses is accepted by fingerprint. Otherwise the read fails with
  `transport("untrusted_certificate")`, unretried.
- **Cache.** A download that completes from byte 0 is kept in a `GrowingFileStore` (default
  `.shared`, 1 GiB, least recently played out). Before streaming, ask
  `store.completedFile(for: url)` and play that with `FileByteReader`. If the URL carries a
  per-session token, pass `cacheKey:` (the URL without it) to the source and to `completedFile(for:)`. Call `sweepPartials()` at launch,
  and give each owner (podcasts, music) its own store so one cannot evict the other's files.
- **Seeking to exactly the end** reads zero bytes even before the length is known, as media3's
  `DefaultHttpDataSource` does with the host's `416 bytes */N`.

## Seek

```swift
let landed = try decoder.seek(toSeconds: 600)
```

Use `landed`, not 600, as your position. The landing is sample-accurate
([ADR-0009](decisions/0009-seeks-are-sample-accurate.md)) with one exception: a VBR MP3 far from a
frame of known time (no MP3 frame carries its time) lands on an estimate from its Xing table or
bitrate, and the estimate is what comes back. If the stream ended at the target, `seek` returns
normally and `endReason` is `.eof`. At a fixed output rate the first frame after a seek is within one
output frame, not bit-identical to the uninterrupted decode.

A forward-only source (a reader whose `seek(to:)` throws `StreamByteReaderError.unseekable`, such as
an unknown-length chunked transcode) opens and decodes sequentially. A seek that needs a position it
refuses throws `StreamDecoderError.unseekable`, distinct from `.failed(status:)` (a corrupt stream).
The decoder has failed after it: `endReason` is `.failure` and reads return nothing, so open a new
decoder over a seekable source. A seek that libavformat can serve from bytes it still holds succeeds.

With a growing-file source, a seek past the frontier restarts the download at the target into a new
file (a short hop ahead waits instead). Call `source.willSeek(generation:)` first only if you want the
transaction paired with your seek in `snapshot` and events.

## Cancel and interrupt

```swift
decoder.cancel()      // any thread: the stream ends for good, endReason == .cancelled
decoder.interrupt()   // any thread: only the blocked call ends, endReason == .interrupted
```

Use `interrupt()` when the pull loop is stuck on a slow read and the user has seeked: stop treating
the nil as an end and call `seek(toSeconds:)`, which clears it. If that seek is to exactly the frame
the interrupted read would have returned, the decode resumes without a flush (MP3 and MP4 bit-exactly).
Use `cancel()` when you throw the decoder away.

## Show buffering and download state

`source.snapshot` is readable from any thread: `base`, `frontier`, `totalLength`, `isComplete`,
`downloadBytesPerSecond`, `fileURL`. `onEvent` delivers changes without polling: `.transaction` when a
response is accepted, `.download` at most once a second, `.seekLanded` when a seek was served from the
file already on disk. A host that wants protocol-shaped callbacks implements `GrowingFileListener` and
calls it from `onEvent`; the source does not take a listener. A listener reads the file back through
`fileURL`, so it never sees a byte the decoder did not have.

## Write a byte source of your own

Conform to `StreamByteReader`: `read` blocks until at least one byte, returning 0 only at end of
stream; `totalLength` is nil when unknown, never a guess (a made-up length breaks MP4 with a trailing
`moov`); `cancel()` and `interrupt()` unblock a waiting call from any thread.

## Test code built on the streaming source

`PlaybackStreamingTestSupport` has `LoopbackMediaServer`, a `Range`-aware local HTTP server with fault
knobs (dropped connections, stalls, refusals, redirects, ignored `Range`). It has no audio fixtures;
supply your own.

```swift
let server = try LoopbackMediaServer(body: audioData, mimeType: "audio/mpeg")
let source = GrowingFileByteSource(url: server.url, authHeaders: [:], store: .temporary())
server.closesAfterBodyBytes = 40_000   // drop the first connection part-way
```
