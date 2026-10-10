# AudioPlaybackKit

Audio playback building blocks AVPlayer doesn't give you, for iOS and macOS.

## Why

AVPlayer and AVFoundation are the right choice for most audio. They fall short in a few places:

- **Formats.** No Ogg Vorbis, Opus or FLAC-in-Ogg, and no Matroska/WebM audio.
- **Progressive streaming of awkward files.** An MP4 or M4A whose `moov` index is at the end cannot start
  until the whole file is downloaded. Here it is read with range requests instead.
- **PCM access.** AVPlayer plays; it does not hand you samples. Silence trimming, EQ, loudness or any
  other processing needs the decoded audio.
- **Flaky networks.** HTTP loading stalls and recovers poorly after a dropped connection or a network change.

AudioPlaybackKit is a Swift package over FFmpeg that fills those gaps. You keep control of the output
(`AVAudioEngine` or your own).

## Products

Link only what you import.

| Product | What it gives you |
|---|---|
| `PlaybackDecode` | `FFmpegStreamDecoder` over a `StreamByteReader`: interleaved Float32 PCM out, sample-accurate seek, cancellable. `FileByteReader` reads a local file. |
| `PlaybackStreaming` | `GrowingFileByteSource`: plays an HTTP(S) URL while it downloads, with range requests, a sparse on-disk cache, and stall detection with retry and resume. |
| `PlaybackStreamingTestSupport` | `LoopbackMediaServer`: a local HTTP server with fault injection (drops, stalls, redirects, ignored `Range`) for testing code that streams. |
| `FFmpeg` | The LGPL-only FFmpeg as a dynamic framework, for an app with its own C code against libavformat. |

Formats: MP3, AAC (ADTS and LATM), MP4 and M4A (AAC, ALAC), Ogg and Matroska/WebM (Opus, Vorbis), FLAC,
and PCM WAV/AIFF.

## What it is not

Not a full player. There is no queue, UI, effects, or audio output: you schedule the PCM yourself.

Roadmap: a render layer that feeds the PCM to `AVAudioEngine`.

## Requirements

iOS 17 or macOS 14, Swift 5.9, Apple silicon.

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

`open()`, `nextChunk()` and `seek(toSeconds:)` block, so call them from a thread of your own. Playing a
URL while it downloads, seeking, cancelling and showing buffering state are in [Usage](docs/usage.md).

## Documentation

- [Usage](docs/usage.md): decode a file, stream a URL, seek, cancel, and the behaviour to rely on.
- [Architecture](docs/architecture.md): how the decoder and the download source work, with diagrams.
- [Decisions](docs/decisions/README.md): why it is built this way.
- [Contributing](docs/contributing.md): tests, rebuilding FFmpeg, releasing. Process is in [CONTRIBUTING.md](CONTRIBUTING.md).

The API may change before 1.0; a public API change is a minor version bump until then.

## Licence

The package is [MIT](LICENSE). Used in production by Shuttle Podcasts and Shuttle2.

FFmpeg is LGPL-2.1 and ships as its own dynamic `FFmpeg.framework`, which Xcode embeds in your app, so a
user can replace it with a modified build (LGPL-2.1 section 6; [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html)).
Its licence text ships inside the framework. `scripts/release.sh` writes the exact FFmpeg source,
patches and configure line for each release to `dist/ffmpeg-X.Y.Z-source.tar.xz`, attached to the GitHub
release. A closed-source app shipping it also owes an FFmpeg notice in its About screen and an EULA
that allows reverse engineering to debug such modifications (not Apple's standard EULA); both are the
app's work ([ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md)).
