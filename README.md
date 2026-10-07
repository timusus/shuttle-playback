# shuttle-playback

An audio playback engine for iOS and macOS, written in Swift on top of FFmpeg. It powers
[Shuttle Podcasts](https://shuttlepodcasts.app) and Shuttle2, a music player.

Apple's `AVPlayer` is a black box. You can't edit the audio before it plays, you can't share its
download with anything else, and when it fails mid-stream you get little control. This engine
decodes audio itself, so the app owns every sample on its way to the speaker. That makes it
possible to:

- start playback while the file is still downloading, from any byte source you supply;
- play formats `AVPlayer` handles badly, such as MP4 files with their index at the end, or Ogg and
  Opus;
- get decoded PCM to process however you like, such as trimming silence or boosting voices, without
  the drift and glitches of an `AVPlayer` audio tap.

## What's in it

Each part is a separate Swift package product. An app links only what it imports, so a podcast app
never pays for a music player's features, and the other way round.

| Product | What it does |
|---|---|
| `PlaybackDecode` | Streaming FFmpeg decoder. You give it a `StreamByteReader` (bytes from a file, a download, anything); it gives you PCM. Handles seeking, files still being written, and a configurable probe budget. |
| `FFmpeg` | A static, LGPL-only FFmpeg build. Codecs and containers are chosen per app by a build profile; the `podcast` profile has MP3, AAC, MP4 and Ogg/Opus/Vorbis. |

Requires iOS 17 or macOS 14.

## Using it

```swift
.package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.1.0")
```

Then add the products you need to your target, such as `PlaybackDecode`.

## Status

The engine is in production in Shuttle Podcasts, and the API may still change before 1.0. Planned
next: the growing-file downloader that the decoder streams from, HLS playback, and more effects
from Shuttle2.

## Development

Building, testing (`swift test` on macOS), rebuilding FFmpeg and releasing are covered in
[CLAUDE.md](CLAUDE.md). That file also explains why the FFmpeg xcframework is committed rather
than downloaded.

Doc comments sometimes cite plan paths such as `mobile/ios/docs/plans/...`. Those paths are in the
Shuttle Podcasts repo, where this code started.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need
agreement to a short [Contributor Licence Agreement](CLA.md), so the project can keep its commercial
licence option.

## Licence

Copyright (c) 2026 Tim Malseed. Licensed under the [GPL-3.0](LICENSE).

If the GPL does not suit your project, for example a closed-source app, a commercial licence is
available. Open an issue or get in touch through GitHub.

FFmpeg is LGPL-2.1. Its licence text ships inside `Frameworks/FFmpeg.xcframework`.
