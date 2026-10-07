# CLAUDE.md

Public (GPL-3.0) Swift package holding the iOS decode layer shared by **Shuttle Podcasts**
(`timusus/podcasts`) and, later, **Shuttle2** (`timusus/shuttle2`). It holds only decode,
byte-source and FFmpeg code (effects such as skip-silence and Voice Boost live in the apps). Anything about podcasts, ads, queues, players or UI stays in the apps.

## Layout

| Product | Target(s) | What it is |
|---|---|---|
| `PlaybackDecode` | `PlaybackDecode`, `CStreamDecode` | `FFmpegStreamDecoder`: pull decoder over a `StreamByteReader`, Float32 interleaved at the source rate, seekable, cancellable. `FileByteReader` is the plain-file reader. Probe budget is `StreamProbeBudget` (default 64 KiB / 1 s). |
| `PlaybackStreaming` | `PlaybackStreaming` | Opt-in network byte source: `GrowingFileByteSource` (a `StreamByteReader` over an HTTP(S) URL that writes to a growing file and retries/resumes from the frontier: `DownloadRetry`, `GrowingFileReadRule`), `GrowingFileStore`, `GrowingFileSnapshot` and `GrowingFileListener`. Depends on `PlaybackDecode`; a decode-only consumer never links it. Auth headers arrive resolved; no feed or podcast concept lives here. |
| `PlaybackStreamingTestSupport` | `PlaybackStreamingTestSupport` | `LoopbackMediaServer`, no fixtures. Tests of the streaming target are in `PlaybackStreamingTests` (own two tone fixtures). |
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
must pass before tagging. Consumers run their own integration tests.

The streaming tests also run on an iOS simulator, selected by UDID from
`xcrun simctl list devices available` (`release.sh` does this, using `IOS_SIM_UDID` or the first
available iPhone):

```sh
xcodebuild test -scheme shuttle-playback-Package -only-testing:PlaybackStreamingTests \
  -destination 'platform=iOS Simulator,id=<UDID>'
```

No test is skipped on either platform. (A short body is closed a beat late by `LoopbackMediaServer`:
macOS URLSession drops a body's buffered bytes if the connection ends before the delegate has
answered the response.)

**Conformance suite.** `swift test --filter PlaybackDecodeConformance` (about 15 s) decodes every
fixture in `Tests/PlaybackDecodeConformanceTests/Fixtures` (plus the three in
`PlaybackDecodeTests/Fixtures`) through `FaultyByteReader` under all 7 combinations of partial reads,
one-shot I/O errors and unknown length, and requires each to be bit-identical to the clean decode in
the same run. It then seeks to 0, 1/3, 2/3 and the end, and compares with `Goldens/<fixture>.json`
(Int16 per-second PCM hashes, frame count, seek landings, the fixture's own sha256). After an
intended decoder change, or a new fixture, regenerate with
`GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance` and review the JSON diff; it writes
a golden only if the fault matrix passes against it. Fixtures
are made by `Fixtures/make-fixtures.sh` (needs ffmpeg, lame, afconvert; the HE-AAC, Opus and Vorbis
files are not byte-reproducible, so re-run it only on purpose); the three androidx/media files are
listed in `Fixtures/NOTICE`. A resumed decode must match the clean one per second outside the
warm-ups (MP3 and MP4 resume bit-exactly), and bytes before the first audio are budgeted under every
combination. A decoder bug the suite found and nobody has fixed is pinned in `KnownIssues.swift`:
fixture, kind, exact fault combinations and the exact finding, with its issue number, under
`XCTExpectFailure`. A different value, or a pinned finding that stops happening, fails; update or
remove the rule. MP3 seek misalignment (#3) is pinned as `alignFrames` in the goldens instead.
`CONFORMANCE_FIXTURE=<file name>` runs one fixture. `CONFORMANCE_PLANT_DEFECT=1` drops a frame from
the clean decode to prove the suite fails. FFmpeg fixes the tag lacks live in
`scripts/ffmpeg-patches/`, applied by `build-ffmpeg.sh` and listed in `VERSION.txt`.

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
- This repo has no hosted CI. `swift test` locally plus `release.sh` is the gate.
