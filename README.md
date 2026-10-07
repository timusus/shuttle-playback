# shuttle-playback

The iOS decode layer shared by Shuttle Podcasts and Shuttle2. It contains:

- a static FFmpeg, built per app profile;
- `FFmpegStreamDecoder`, a pull decoder;
- the skip-silence and Voice Boost DSP stages.

```swift
.package(url: "git@github.com:timusus/shuttle-playback.git", from: "0.1.0")
// products: PlaybackDecode, SilenceGate, VoiceEnhance, FFmpeg
```

Build, test and release are covered in [CLAUDE.md](CLAUDE.md). It also explains why the
xcframework is committed rather than downloaded.

Doc comments sometimes cite plan paths such as `mobile/ios/docs/plans/...`. Those paths are in the
Shuttle Podcasts repo, where this code started.

FFmpeg is LGPL-2.1. Its licence text ships inside `Frameworks/FFmpeg.xcframework`.
