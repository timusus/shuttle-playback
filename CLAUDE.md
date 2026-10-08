# CLAUDE.md

Public (GPL-3.0) Swift package holding the iOS decode layer shared by **Shuttle Podcasts**
(`timusus/podcasts`) and **Shuttle2** (`timusus/shuttle2`, pins `exact: "0.4.0"`). It holds only decode,
byte-source and FFmpeg code; effects (skip-silence, Voice Boost) and anything about podcasts, ads,
queues, players or UI stay in the apps. Docs are in `docs/`; start at `README.md`.

## Layout

| Product | Target(s) | What it is |
|---|---|---|
| `PlaybackDecode` | `PlaybackDecode`, `CStreamDecode` | `FFmpegStreamDecoder`: pull decoder over a `StreamByteReader`, Float32 interleaved, seekable, cancellable. `FileByteReader` is the plain-file reader. Probe budget is `StreamProbeBudget` (default 64 KiB / 1 s). |
| `PlaybackStreaming` | `PlaybackStreaming` | Opt-in network byte source: `GrowingFileByteSource` over an HTTP(S) URL writing a growing file, with retry/resume. Rules live in the internal state machine `GrowingFileDownload`. Depends on `PlaybackDecode`. Auth headers arrive resolved; no feed or podcast concept. |
| `PlaybackStreamingTestSupport` | same | `LoopbackMediaServer`, no fixtures. |
| `FFmpeg` | `CFFmpeg` (binary) | The static FFmpeg, for an app with its own C against libavformat. An app links exactly one FFmpeg. |

`Frameworks/FFmpeg.xcframework` (ios-arm64, ios-arm64-simulator, macos-arm64) is **committed to git**
(about 11 MB): SwiftPM does not run Git LFS and there is no CI to publish release assets. `*.a` is
binary in `.gitattributes`. `VERSION.txt` inside it records the tag, configure flags and patches.

## FFmpeg

- LGPL-2.1 only, linked statically into closed-source apps. Never add `--enable-gpl`,
  `--enable-version3`, `--enable-nonfree` or an external library beyond the system zlib.
- One music-superset build for both apps (ADR-0006); the lists are at the top of
  `scripts/build-ffmpeg.sh`. Each format needs a conformance fixture.
- `scripts/build-ffmpeg.sh` takes several minutes; run it in the foreground and commit the framework
  alone as `build: rebuild ffmpeg ...`. Patches live in `scripts/ffmpeg-patches/`.

## Commands

```sh
swift test                                          # macOS slice, no simulator; the gate
swift test --filter PlaybackDecodeConformance       # about 30 s
GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance   # after an intended change; review the JSON diff
xcodebuild test -scheme shuttle-playback-Package -only-testing:PlaybackStreamingTests \
  -destination 'platform=iOS Simulator,id=<UDID>'   # UDID from `xcrun simctl list devices available`
scripts/release.sh 0.1.1                            # clean main only: tests, tag (bare semver), push
```

No test is skipped except the 30-minute MP3 one (needs host `ffmpeg`). Conformance details, known
issues and fixtures: `docs/contributing.md`. Consumers pin a tag, never a branch. A public API change
is a minor bump at 0.x; so is any decoder change that alters PCM, and the release note says what moved.

## Conventions

- Engineering principles are in the global rules (`~/.claude/rules/engineering.md`). Repo-specific:
  when in doubt follow androidx/media (media3); cite the class or issue in the ADR or commit, and say
  why when deviating.
- Conventional commits (`feat:`, `fix:`, `refactor:`, `build:`, `docs:`, `test:`), pushed straight to
  `main`. No PRs, no AI attribution, no CI.
- Public API is the contract with two apps: `public` only when an app needs it, `Sendable`-friendly.
