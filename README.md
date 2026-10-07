# shuttle-playback

The audio decode layer for iOS and macOS, written in Swift over a static FFmpeg. It turns a byte source,
such as a file or a URL still downloading, into interleaved Float32 PCM that your app schedules however
it likes.

Apple's frameworks do not decode Ogg Vorbis or Opus, and cannot stream an MP4 whose `moov` index is at
the end of the file. This engine demuxes and decodes with FFmpeg behind a pull interface, so the app owns
every sample on its way to the speaker. It also plays a file while it downloads and recovers from dropped
connections.

It is the decode layer of [Shuttle Podcasts](https://shuttlepodcasts.app) (in production) and, later,
Shuttle2. It knows nothing about podcasts, queues or UI; effects such as skip-silence live in the apps.

## Products

Link only what you import.

| Product | What it is |
|---|---|
| `PlaybackDecode` | `FFmpegStreamDecoder` over a `StreamByteReader`: seekable, cancellable. `FileByteReader` reads a local file. |
| `PlaybackStreaming` | `GrowingFileByteSource`: plays an HTTP(S) URL while it downloads, retrying and resuming after drops. |
| `PlaybackStreamingTestSupport` | `LoopbackMediaServer`, a local HTTP server with fault knobs, for tests. |
| `FFmpeg` | The static LGPL-only FFmpeg, for an app with its own C code against libavformat. |

Formats: MP3, AAC (ADTS and LATM), MP4 and M4A (AAC, ALAC), Ogg and Matroska/WebM (Opus, Vorbis), FLAC,
and PCM WAV/AIFF. Requires iOS 17 or macOS 14, Swift 5.9, Apple silicon.

## Quick start

```swift
.package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.3.0")
```

```swift
import PlaybackDecode

let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let format = try decoder.open()                  // sample rate, channel count, duration

while let chunk = decoder.nextChunk() {          // interleaved Float32, up to 4096 frames
    // hand `chunk` to your renderer at format.sampleRate
}
// nil is not always the end of the file: check decoder.endReason
```

## Documentation

- [Usage](docs/usage.md): decode a file, stream a URL, seek, cancel, and the behaviour to rely on.
- [Architecture](docs/architecture.md): how the decoder and the download source work, with diagrams.
- [Decisions](docs/decisions/README.md): why the engine is built this way.
- [Contributing](docs/contributing.md): tests, rebuilding FFmpeg, releasing. Process is in [CONTRIBUTING.md](CONTRIBUTING.md).

The API may change before 1.0; a public API change is a minor version bump until then.

## Licence

Copyright (c) 2026 Tim Malseed. Licensed under the [GPL-3.0](LICENSE). A commercial licence is available
on request, for a closed-source app for example; contributions need agreement to the
[CLA](CLA.md) so that is possible. FFmpeg is LGPL-2.1, and its licence text ships inside
`Frameworks/FFmpeg.xcframework`.
