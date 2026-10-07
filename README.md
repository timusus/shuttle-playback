# shuttle-playback

An audio decoding engine for iOS and macOS, written in Swift on top of a static FFmpeg. It turns a
byte source, such as a file or a URL that is still downloading, into interleaved Float32 PCM at the
source's own sample rate. You schedule that PCM however you like.

Apple's `AVPlayer` will not play MP4 files with the index at the end, will not play Ogg or Opus, and
does not let you touch the samples. This engine decodes the audio itself, so the app owns every sample
on its way to the speaker. It also plays a file while it downloads, and recovers from dropped
connections.

It is the decode layer of [Shuttle Podcasts](https://shuttlepodcasts.app) and Shuttle2. It knows nothing
about podcasts, queues or UI.

## Products

Each product is a separate library. Link only what you import.

| Product | What it is |
|---|---|
| `PlaybackDecode` | `FFmpegStreamDecoder`: reads a `StreamByteReader`, returns PCM. Seekable and cancellable. `FileByteReader` reads a local file. |
| `PlaybackStreaming` | `GrowingFileByteSource`: plays an HTTP(S) URL while it downloads, and retries and resumes after drops. Depends on `PlaybackDecode`. |
| `PlaybackStreamingTestSupport` | `LoopbackMediaServer`: a local HTTP server with fault knobs, for testing code built on `PlaybackStreaming`. |
| `FFmpeg` | The static, LGPL-only FFmpeg build, for an app with its own C code against libavformat. |

The bundled FFmpeg decodes MP3, AAC (ADTS and LATM), MP4 and M4A, and Ogg with Opus and Vorbis.

## Requirements

iOS 17 or macOS 14. Swift 5.9 or later. Apple silicon only (the bundled FFmpeg has arm64 slices).

## Install

```swift
.package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.3.0")
```

Add the products you need to your target.

## Quick start

```swift
import PlaybackDecode

let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let format = try decoder.open()                  // sample rate, channel count, duration

while let chunk = decoder.nextChunk() {          // interleaved Float32, up to 4096 frames
    // hand `chunk` to your renderer at format.sampleRate
}
// nextChunk() returned nil: check decoder.endReason, it is not always the end of the file
```

## Documentation

- [Integrating](docs/integrating.md): add the package, decode a file, stream a URL, seek, cancel.
- [Architecture](docs/architecture.md): how the decoder and the download source work, with diagrams.
- [Decisions](docs/decisions/README.md): why the engine is built this way.
- [FFmpeg](docs/ffmpeg.md): the committed static build, profiles, patches, rebuilding.
- [Testing and releasing](docs/testing.md): the test suites, the conformance goldens, cutting a release.

## Status

The engine is in production in Shuttle Podcasts. The API may change before 1.0, and a public API
change is a minor version bump until then.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need
agreement to a short [Contributor Licence Agreement](CLA.md), so the project can also be offered under a
commercial licence.

## Licence

Copyright (c) 2026 Tim Malseed. Licensed under the [GPL-3.0](LICENSE).

A commercial licence is available on request, for a closed-source app for example. Open an issue or get
in touch through GitHub.

FFmpeg is LGPL-2.1. Its licence text ships inside `Frameworks/FFmpeg.xcframework`.
