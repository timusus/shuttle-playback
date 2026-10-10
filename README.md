# AudioPlaybackKit

![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Decode and stream the audio AVPlayer won't, as PCM you control. A Swift package over FFmpeg for iOS and macOS.

## Why

AVPlayer is the right choice for most audio. It falls short in four places:

- **Formats.** No Ogg Vorbis, Opus or FLAC-in-Ogg, and no Matroska/WebM audio.
- **Awkward files.** An MP4 or M4A with its `moov` index at the end cannot start until fully downloaded. Here it plays from range requests.
- **PCM access.** Silence trimming, EQ or loudness need the decoded samples; AVPlayer does not hand them over.
- **Flaky networks.** HTTP loading stalls and recovers poorly after a dropped connection or a network change.

## What's inside

Link only the products you import.

| Product | What it is |
|---|---|
| `PlaybackDecode` | `FFmpegStreamDecoder`: interleaved Float32 PCM from any `StreamByteReader`; `FileByteReader` reads a local file. |
| `PlaybackStreaming` | `GrowingFileByteSource`: plays an HTTP(S) URL while it downloads. |
| `PlaybackStreamingTestSupport` | `LoopbackMediaServer`: a local HTTP server for testing code that streams. |
| `FFmpeg` | The LGPL-only FFmpeg as a dynamic framework, for an app with its own C code against libavformat. |

## Capabilities

- **Formats:** MP3, AAC (ADTS and LATM), MP4/M4A (AAC, ALAC), Ogg and Matroska/WebM (Opus, Vorbis), FLAC, PCM WAV/AIFF.
- **Sample-accurate seek**, and cancellation of a blocked open, read or seek.
- **Range requests and a sparse on-disk cache** so bytes already fetched are not downloaded again after a seek or restart.
- **Stall detection with retry and resume** after a dropped connection.
- **Fault-injecting loopback server** (drops, stalls, redirects, ignored `Range`) for deterministic tests.

## Install

```swift
.package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.7.1")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "PlaybackDecode", package: "AudioPlaybackKit"),
])
```

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
- [Contributing](docs/contributing.md): tests, rebuilding FFmpeg, releasing.

Requires iOS 17 or macOS 14, Apple silicon. The API may change before 1.0; a public API change is a minor version bump until then.
Used in production by Shuttle Podcasts and Shuttle2.

## Licence

The package is [MIT](LICENSE).

FFmpeg is LGPL-2.1 and ships as its own dynamic `FFmpeg.framework`, which Xcode embeds in your app, so a
user can replace it with a modified build (LGPL-2.1 section 6; [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html)).
Its licence text ships inside the framework. `scripts/release.sh` writes the exact FFmpeg source,
patches and configure line for each release to `dist/ffmpeg-X.Y.Z-source.tar.xz`, attached to the GitHub
release. A closed-source app shipping it also owes an FFmpeg notice in its About screen and an EULA
that allows reverse engineering to debug such modifications (not Apple's standard EULA); both are the
app's work ([ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md)).
