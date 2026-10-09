# Contributing: tests, FFmpeg and releases

For the pull-request process (CLA, discuss first) see [CONTRIBUTING.md](../CONTRIBUTING.md). The
commands to build, test and release, the FFmpeg licence rules, the layout and the engineering
principles are in [CLAUDE.md](../CLAUDE.md). This page holds what those do not say. The repository has no hosted CI:
`swift test` locally plus `scripts/release.sh` is the gate.

## Test suites

| Target | Covers |
|---|---|
| `PlaybackDecodeTests` | The decoder against `AVAssetReader` on three committed tone fixtures. |
| `PlaybackDecodeConformanceTests` | Every fixture through a faulting reader, then seeks, against goldens. |
| `PlaybackStreamingTests` | `GrowingFileByteSource`, its state machine `GrowingFileDownload`, `GrowingFileStore` and the loopback server. Also runs on an iOS simulator. |

`GrowingFileDownload` (with its `ReadRule` and `Retry`) takes no clock, lock, file or network, so its
tests feed it event sequences with literal times and check the effects it answers with; the byte
source's tests are contract tests against the loopback server, on a manual clock and their own `GrowingFilePathMonitor`, so backoffs
and the 30 s link window run in milliseconds and the machine's network never reaches a test. A test
needing a 30-minute MP3 with no Xing header generates it with a host `ffmpeg` and is skipped without one (and on the simulator, which has none).

**Conformance suite** ([ADR-0008](decisions/0008-conformance-testing-modelled-on-media3.md)). The point is
that the decoder gives the same audio however the bytes arrive, and that a decoder change shows up as a
golden diff to review. To add a format, add a fixture (`Fixtures/make-fixtures.sh`, which needs `ffmpeg`,
`lame` and `afconvert`; the HE-AAC, Opus and Vorbis outputs are not byte-reproducible, so re-run it only on
purpose) and regenerate with `GOLDEN_UPDATE=1`. A decoder bug found and not fixed is pinned in
`KnownIssues.swift` rather than left as a red test. Fixtures copied from androidx/media, and which
media3 test case each one answers, are listed in [conformance-mapping.md](conformance-mapping.md).

Each fixture (plus the three tone fixtures; the `stitch_*_64k.mp3` pair is skipped, since a seek into
its resampled half is timed by byte offset and never bit-identical) is decoded through
`FaultyByteReader` under all 7 combinations of partial reads, one-shot I/O errors and unknown length,
and each must be bit-identical to the clean decode of the same run. Seeks to 0, 1/3, 2/3, 100 ms
before the end and the end are compared with `Goldens/<fixture>.json` (Int16 per-second PCM hashes,
frame count, seek landings, the fixture's sha256). `GOLDEN_UPDATE=1` writes a golden only if the
fault matrix passes against it. Seeks are sample-accurate (`alignFrames` is 0 in every golden); the
exception is a VBR MP3 seek far from a frame of known time, which lands by Xing TOC or bitrate
estimate. A pinned finding in `KnownIssues.swift` names fixture, kind, exact fault combinations and
issue number under `XCTExpectFailure`: a different value, or a finding that stops happening, fails.
A resumed decode must match the clean one per second outside the warm-ups. Bytes before the first audio
are budgeted under every fault combination. A seek to the end lands where the clean decode ends, with an
empty window. VBR MP3 seeks are covered by `testXingVBRMP3SeeksExactlyNearAndCheaplyFar`, and a seek into
the `stitch_*_64k.mp3` resampled half by `testSeekIntoTheResampledHalfLandsWhereItSays`. Fixture licences
are in `Tests/PlaybackDecodeConformanceTests/Fixtures/NOTICE`.
`CONFORMANCE_FIXTURE=<file name>` runs one fixture; `CONFORMANCE_PLANT_DEFECT=1` drops a frame from
the clean decode to prove the suite fails.

**Byte-source contract.** `GrowingFileContractTests` runs media3's `DataSourceContractTest` cases against
the source over `LoopbackMediaServer`. A new server behaviour is one `Resource` in the matrix of
`GrowingFileContractCase`. The loopback server speaks no TLS, so certificate trust is tested as a decision
over real `SecTrust`s (`GrowingFileConnectionPolicyTests`), not through a `URLSession` challenge.

## FFmpeg

`Frameworks/FFmpeg.xcframework` has three slices (ios-arm64, ios-arm64-simulator, macos-arm64), each one
dynamic `FFmpeg.framework` of libavformat, libavcodec, libswresample and libavutil linked against the
system `z`, `iconv` and the CoreMedia family, plus the LGPL text and `VERSION.txt` (tag, exact configure
flags, applied patches, linkage: read it to see what a build contains). The script also installs the
headers into `Sources/CFFmpeg/include`, beside the hand-written `CFFmpeg` module map.

### Rebuilding FFmpeg

Everything is disabled except the decoders, demuxers and parsers listed at the top of
`scripts/build-ffmpeg.sh`; `--disable-autodetect` stops a system library sneaking in. Formats are added
there, with a fixture and conformance case, because an untested format is not supported. The script needs
Xcode with the iOS SDKs and reads `FFMPEG_TAG`, `FFMPEG_SRC`, `OUT_DIR`, `BUILD_ROOT`, `DEPLOYMENT_TARGET`
and `MACOS_DEPLOYMENT_TARGET` (defaults in the script). After a rebuild:

1. `git diff` on `VERSION.txt` shows only the intended change.
2. `swift test`, conformance suite included, passes.
3. The framework is its own commit: `build: rebuild ffmpeg ...`; changed headers go with it.

Patches in `scripts/ffmpeg-patches/` are applied by the script to the cloned source and listed in
`VERSION.txt`. Add one only for a bug the pinned tag has and the decoder cannot work around, and say
what it fixes in the patch header (patch 0001: with a source of unknown length the MP3 demuxer discarded
the Xing frame count, losing the gapless trim and the duration).

## Releasing

`scripts/release.sh X.Y.Z NOTES.md` refuses missing notes, a dirty tree, a branch other than `main`, a bad or existing version,
or a `main` behind `origin/main`. It also runs from the landing worktree on a detached HEAD, which must
equal `origin/main` (`git checkout --detach origin/main`); it pushes only the tag. It runs `swift test`, runs `PlaybackStreamingTests` on an iOS simulator
(`IOS_SIM_UDID`, else the first available iPhone), tags the bare semver, pushes, and publishes the GitHub
release with the notes and the FFmpeg source tarball attached. Then bump the
consumer's `Package.swift` if the change matters to it and run its tests. A fix that changes neither API
nor output is a patch; the release note says what moved when PCM does.
