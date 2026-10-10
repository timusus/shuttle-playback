# AudioPlaybackKit

![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Decode and stream the audio AVPlayer won't, as PCM you control. A Swift package over FFmpeg for iOS and macOS.
Used in production by Shuttle Podcasts and Shuttle2.

## Why

AVPlayer is the right choice for most audio. It falls short in four places:

- **Formats.** No Ogg Vorbis, Ogg Opus or FLAC-in-Ogg, and no Matroska/WebM audio (such as Opus in WebM).
- **Files whose index is stored at the end.** An MP4 or M4A like this cannot start until fully downloaded. Here it plays from range requests.
- **PCM access.** Silence trimming, EQ or loudness need the decoded samples; AVPlayer does not hand them over.
- **Flaky networks (PlaybackStreaming).** Range-request resume, stall detection and retry after a dropped connection.

## What's inside

Link only the products you import.

| Product | What it is |
|---|---|
| `PlaybackDecode` | `FFmpegStreamDecoder`: interleaved Float32 PCM from any `StreamByteReader`; `FileByteReader` reads a local file. |
| `PlaybackStreaming` | `GrowingFileByteSource`: plays an HTTP(S) URL while it downloads. |
| `PlaybackStreamingTestSupport` | `LoopbackMediaServer`: a local HTTP server for testing code that streams. |
| `FFmpeg` | The LGPL-only FFmpeg as a dynamic framework, for an app with its own C code against libavformat. |

## Capabilities

- **Formats:** MP3, AAC, M4A/ALAC, Ogg, Matroska/WebM, FLAC, WAV/AIFF. [Full list](docs/usage.md#supported-formats).
- **Sample-accurate seek**, and cancellation of a blocked open, read or seek.
- **Range requests and a sparse on-disk cache** so bytes already fetched are not downloaded again after a seek or restart.
- **Fault-injecting loopback server** (drops, stalls, redirects, ignored `Range`) for deterministic tests.

## Install

```swift
.package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.7.1")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "PlaybackDecode", package: "AudioPlaybackKit"),
    .product(name: "PlaybackStreaming", package: "AudioPlaybackKit"),   // only to play URLs
])
```

Requires iOS 17 or macOS 14, Apple silicon. The API may change before 1.0; a public API change is a minor version bump until then.

## Example

```swift
import PlaybackDecode

let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let format = try decoder.open()                  // sample rate, channel count, duration

while let chunk = decoder.nextChunk() {          // interleaved Float32, up to 4096 frames
    // hand `chunk` to your renderer at format.sampleRate
}
// nil is not always the end of the file: check decoder.endReason
```

`open()`, `nextChunk()` and `seek(toSeconds:)` block, so call them from a thread of your own.

## Not a player

There is no queue, UI, effects or audio output. You schedule the PCM on `AVAudioEngine` or your own output.
Roadmap: a render layer that feeds the PCM to `AVAudioEngine`.

## Documentation

- [Usage](docs/usage.md): decode a file, stream a URL, seek, cancel, show buffering state.
- [Architecture](docs/architecture.md): how the decoder and the download source work.
- [Decisions](docs/decisions/README.md): why it is built this way.
- [Contributing](CONTRIBUTING.md) and [docs/contributing.md](docs/contributing.md): tests, rebuilding FFmpeg, releasing.

## Licence

The package is [MIT](LICENSE). FFmpeg is LGPL-2.1, shipped as a dynamic framework; what an app must do is in
[ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md).
