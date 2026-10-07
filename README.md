# shuttle-playback

The iOS decode layer shared by Shuttle Podcasts and Shuttle2. It contains:

- a static FFmpeg, built per app profile;
- `FFmpegStreamDecoder`, a pull decoder;
- the skip-silence and Voice Boost DSP stages.

```swift
.package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.1.0")
// products: PlaybackDecode, SilenceGate, VoiceEnhance, FFmpeg
```

Build, test and release are covered in [CLAUDE.md](CLAUDE.md). It also explains why the
xcframework is committed rather than downloaded.

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
