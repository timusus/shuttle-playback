# Integrating

How to add shuttle-playback to an app, decode a local file, play a URL while it downloads, and handle
seeking and cancellation. This guide assumes you can already write an audio render loop. If you are
new to the package, start with the [tutorial](tutorial.md).

## Add the package

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "PlaybackDecode", package: "shuttle-playback"),
        // Only if you play URLs:
        .product(name: "PlaybackStreaming", package: "shuttle-playback"),
    ]),
]
```

In Xcode, use File > Add Package Dependencies with the same URL.

`PlaybackDecode` links the system frameworks and libraries the static FFmpeg needs (CoreFoundation,
CoreMedia, CoreVideo, VideoToolbox, zlib and iconv), so a target needs no linker settings of its
own. A target that takes only the `FFmpeg` product gets none of them, because a binary target cannot
carry linker settings: add them to that target's `linkerSettings`.

Pin a tag, never a branch. The package needs iOS 17 or macOS 14. Add `PlaybackStreaming` only if
you stream URLs. Add the `FFmpeg` product only if you have your own C code against libavformat, and
then link no other copy of FFmpeg. See [FFmpeg](ffmpeg.md).

## Decode a local file

```swift
import PlaybackDecode

let reader = try FileByteReader(url: fileURL)
let decoder = FFmpegStreamDecoder(reader: reader)
let format = try decoder.open()          // StreamAudioFormat: sampleRate, channelCount, duration, ...

while let chunk = decoder.nextChunk() {  // [Float], interleaved, up to 4096 frames
    // schedule `chunk` at format.sampleRate with format.channelCount channels
}
if decoder.endReason != .eof {
    // the stream stopped for another reason: .failure, .cancelled or .interrupted
}
```

`open()` blocks and throws a `StreamDecoderError` on failure. `nextChunk()` blocks too. Run both on a
thread of your own, not the main thread. One thread drives a decoder.

The output is Float32 at the file's own sample rate. Nothing is resampled, so an `AVAudioEngine` graph
or other renderer should run at `format.sampleRate`.

## Decode to a fixed format

A player that runs one graph at one format across tracks (gapless playback, where two files of
different rates play back to back on one node) asks the decoder for that format instead, after
`open()` and before the first read or seek:

```swift
let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let source = try decoder.open()                          // still describes the file
try decoder.setOutputFormat(sampleRate: 48000, channelCount: 2)

let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
defer { buffer.deallocate() }
while true {
    let frames = decoder.read(into: buffer, maxFrames: 4096)
    if frames == 0 { break }   // check decoder.endReason, exactly as for nextChunk() returning nil
    // `frames` interleaved stereo frames at 48 kHz in `buffer`
}
```

The decoder resamples, downmixes more channels by swresample's default matrix and spreads mono to
both sides at full level. `read(into:maxFrames:)` hands out the same samples as `nextChunk()` without
allocating; `nextChunk()` also returns the fixed format. A seek still returns media seconds, and
`mediaFramesRead` counts frames at the output rate.

Always check `endReason` after `nextChunk()` returns nil. A nil from a network failure is not the end
of the stream.

## Play a URL while it downloads

```swift
import PlaybackDecode
import PlaybackStreaming

let source = GrowingFileByteSource(
    url: url,
    authHeaders: ["Authorization": "Bearer \(token)"],   // already resolved; use [:] for none
    onEvent: { event in /* GrowingFileEvent: transaction, download, seekLanded */ }
)
defer { source.cancel() }                                // required, see below

let decoder = FFmpegStreamDecoder(reader: source)
source.isProbing = true
let format = try decoder.open()
source.isProbing = false

while let chunk = decoder.nextChunk() { /* schedule it */ }
```

Notes:

- **Call `cancel()` when you are done.** A running URLSession task retains its delegate, which is the
  source. Without `cancel()` the source and its partial file leak.
- **Set `isProbing` around `open()`.** While it is set, a read of the last 128 bytes past the frontier
  answers end of file at once. FFmpeg reads that as "no ID3v1 footer", and the head download is not
  cancelled for a look at the tail.
- **The source writes to `GrowingFileStore.shared`**, a directory under `Caches`. Pass your own store
  with `store:`. Call `sweepPartials()` on the store at launch to remove leftovers from a killed run.
- **Bound the cache per owner with one store each.** `shared` is one 1 GiB LRU, so a large music
  library can push podcast episodes out of it. Give each owner its own store, for example
  `GrowingFileStore(directory: caches.appendingPathComponent("growing-music"), budgetBytes: 4 << 30)`,
  and pass it as `store:`. Eviction, the low-disk clear and `sweepPartials()` touch only that store's
  directory, so use a distinct directory per store and look a URL up in the store that played it.
- **A completed download is cached.** Before streaming a URL, ask the store:
  `GrowingFileStore.shared.completedFile(for: url)`. If it returns a file, play that with
  `FileByteReader` and skip the network.
- **The decoder blocks while it waits for bytes.** That is how buffering shows up. A body that goes quiet
  is retried by the source, and a read fails with `StreamByteReaderError.transport` only when
  retries and the 30 s link window are spent. See [Recovery and retry](architecture.md#recovery-and-retry).

## Seek

```swift
let landed = try decoder.seek(toSeconds: 600)
```

Use `landed`, not 600, as your new position. The decoder lands on the requested sample, except in a
VBR MP3 far from a frame of known time, where it lands on an estimate (see
[architecture](architecture.md#seek)). If the stream ended at the target, `seek` returns normally and
`endReason` is `.eof`.

With `GrowingFileByteSource`, tell it about the seek first if you want to pair a seek with the
transaction it opens:

```swift
source.willSeek(generation: seekCounter)
let landed = try decoder.seek(toSeconds: 600)
```

This is optional. It only affects the `seekGeneration` in snapshots and events.

## Stop from another thread

```swift
decoder.cancel()      // ends the stream for good; the pull loop sees endReason == .cancelled
decoder.interrupt()   // ends only the blocked call; the decoder stays open
```

Use `interrupt()` when the pull loop is blocked on a slow network read and the user has seeked.
The loop gets `endReason == .interrupted`, you stop treating that as an end, and you call
`seek(toSeconds:)`, which clears the interrupt. Use `cancel()` when you are throwing the decoder away.

## Show buffering and download state

Read `source.snapshot` from any thread. It gives `base`, `frontier`, `totalLength`, `isComplete`,
`downloadBytesPerSecond` and the file's `fileURL`. To get changes without polling, pass `onEvent`.
If you want the protocol-shaped callbacks, implement `GrowingFileListener` and call it from your
`onEvent` closure and your seek code, since the source does not take a listener itself. See
[Reference](reference.md#growingfilelistener).

## Write a byte source of your own

Conform to `StreamByteReader` and pass it to `FFmpegStreamDecoder(reader:)`. Report `totalLength` as
nil if you do not know it, never a guess. The full contract is in
[Reference](reference.md#streambytereader).

## Test your integration

`PlaybackStreamingTestSupport` has `LoopbackMediaServer`, a local `Range`-aware HTTP server with fault
knobs: dropped connections, stalls, refused requests, redirects, a server that ignores `Range`.

```swift
import Foundation
import PlaybackStreaming
import PlaybackStreamingTestSupport

let audioData = try Data(contentsOf: fixtureURL)   // your own audio
let server = try LoopbackMediaServer(body: audioData, mimeType: "audio/mpeg")
let source = GrowingFileByteSource(url: server.url, authHeaders: [:], store: .temporary())
server.closesAfterBodyBytes = 40_000   // drop the first connection part-way
```

`server.url` serves the body at `/fixture.mp3` on the loopback interface. The package has no fixtures
of its own for this product, so supply your own audio. Stop the server with `stop()`.

## Next

[Reference](reference.md) lists every public type and member.
