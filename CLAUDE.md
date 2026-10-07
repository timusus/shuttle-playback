# CLAUDE.md

Public (GPL-3.0) Swift package holding the iOS decode layer shared by **Shuttle Podcasts**
(`timusus/podcasts`) and, later, **Shuttle2** (`timusus/shuttle2`). It holds only codec and DSP
code. Anything about podcasts, ads, queues, players or UI stays in the apps.

## Layout

| Product | Target(s) | What it is |
|---|---|---|
| `PlaybackDecode` | `PlaybackDecode`, `CStreamDecode` | `FFmpegStreamDecoder`: pull decoder over a `StreamByteReader`, Float32 interleaved at the source rate, seekable, cancellable. `FileByteReader` is the plain-file reader. Probe budget is `StreamProbeBudget` (default 64 KiB / 1 s). |
| `SilenceGate` | `SilenceGate` | Skip-silence trimming. Samples in, samples out. `SilenceGateSettings.podcast` is Android's tuning. The savings tally (`SilenceSavingsStore`) is app-side. |
| `VoiceEnhance` | `VoiceEnhance` | Voice Boost: `VoiceEnhanceProcessor` plus `Biquad`, `Compressor`, `LookaheadLimiter`, `KWeightingFilter`, `LufsMeter`. A port of the Android chain; the numbers in the tests are the spec. |
| `FFmpeg` | `CFFmpeg` (binary) | The static FFmpeg. For an app with its own C against libavformat (Podcasts' scanner decode). An app links exactly one FFmpeg. |

`Frameworks/FFmpeg.xcframework` holds three slices (ios-arm64, ios-arm64-simulator, macos-arm64), each one `libffmpeg.a` plus headers and a `CFFmpeg` modulemap. `VERSION.txt` inside it records the FFmpeg tag, the profile and the exact configure flags.

## Where the xcframework lives, and why

It is **committed to git** (about 11 MB, three 2.5 MB static libraries plus headers), not
downloaded:

- **SwiftPM does not run Git LFS.** A consumer resolving by git URL would get LFS pointer files.
- **No hosted CI publishes release assets.** `.binaryTarget(url:checksum:)` would need someone to
  upload a zip and bump a checksum by hand on every FFmpeg rebuild.
- **Committed means it just works.** Anyone who can clone the repo can build. The cost is repo
  growth when FFmpeg is rebuilt, a few MB per FFmpeg bump, which is rare.

`.gitattributes` marks `*.a` as binary so git never diffs or normalises it.

## Build the FFmpeg

```sh
scripts/build-ffmpeg.sh                     # podcast profile -> Frameworks/FFmpeg.xcframework
FFMPEG_PROFILE=music FFMPEG_ALLOW_UNVERIFIED_PROFILE=1 scripts/build-ffmpeg.sh   # stub, see below
```

- `podcast`: mp3, AAC (ADTS and LATM), MP4/M4A, Ogg with Opus and Vorbis.
- `music`: a superset (adds FLAC, ALAC, PCM WAV/AIFF, Matroska). It is a **stub**: the format list
  exists so Shuttle2's migration starts from it, but nothing builds, ships or tests it yet. The
  script refuses it without the override, and it writes `FFmpeg-music.xcframework`, which no
  target references.
- LGPL-2.1 only. Never add `--enable-gpl`, `--enable-version3`, `--enable-nonfree` or an
  external library to a profile: the library links statically into closed-source apps.
- A build takes several minutes. Run it in the foreground and commit the rebuilt framework in its
  own commit (`build: rebuild ffmpeg ...`), with `VERSION.txt` showing the change.

## Test

```sh
swift test
```

This runs on macOS against the macOS slice, with no simulator. The decoder tests compare against
`AVAssetReader` using the committed fixtures in `Tests/PlaybackDecodeTests/Fixtures`. All tests
must pass before tagging. Consumers run their own integration tests: Podcasts runs
`xcodebuild test -scheme Playback-Package` and `scripts/spine-tests.sh`.

## Release

Consumers pin a **tag** (`from: "0.1.0"`), never a branch. Releasing:

```sh
scripts/release.sh 0.1.1
```

It refuses a dirty tree or any branch other than `main`, runs `swift test`, tags `X.Y.Z` (bare
semver, no `v` prefix: SwiftPM matches both, but the existing tags are bare), and pushes `main`
and the tag. Then bump the consumer's `Package.swift` requirement if the change matters to it,
and run the consumer's tests.

Versioning: a public API change is a minor bump while we are at 0.x. A behaviour change in the
decoder or a DSP stage (PCM out differs) is at least a minor bump, and the release note says what
moved.

## Conventions

- Conventional commits (`feat:`, `fix:`, `refactor:`, `build:`, `docs:`, `test:`), pushed straight
  to `main`. No PRs and no AI attribution in any commit.
- Public API is the contract with two apps. Keep it small. Make something `public` only when an
  app needs it, and keep it `Sendable`-friendly.
- Behaviour shared with Android (the silence-gate tuning and the Voice Boost chain) is ported, not
  invented. Change it on both platforms or not at all.
- This repo has no hosted CI. `swift test` locally plus `release.sh` is the gate.
