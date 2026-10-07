# Contributing: tests, FFmpeg and releases

For the pull-request process (CLA, discuss first) see [CONTRIBUTING.md](../CONTRIBUTING.md). The
commands to build, test, rebuild FFmpeg and release, and the engineering principles, are in
[CLAUDE.md](../CLAUDE.md). This page holds what those do not say. The repository has no hosted CI:
`swift test` locally plus `scripts/release.sh` is the gate.

## Test suites

| Target | Covers |
|---|---|
| `PlaybackDecodeTests` | The decoder against `AVAssetReader` on three committed tone fixtures. |
| `PlaybackDecodeConformanceTests` | Every fixture through a faulting reader, then seeks, against goldens. |
| `PlaybackStreamingTests` | `GrowingFileByteSource`, `DownloadRetry`, `GrowingFileReadRule`, `GrowingFileStore` and the loopback server. Also runs on an iOS simulator. |

`DownloadRetry` and `GrowingFileReadRule` take no clock, lock or network, so their tests use literal
numbers; the byte source's tests drive a manual clock and their own `GrowingFilePathMonitor`, so backoffs
and the 30 s link window run in milliseconds and the machine's network never reaches a test. A test
needing a 30-minute MP3 with no Xing header generates it with a host `ffmpeg` and is skipped without one.

**Conformance suite** ([ADR-0008](decisions/0008-conformance-testing-modelled-on-media3.md)). The point is
that the decoder gives the same audio however the bytes arrive, and that a decoder change shows up as a
golden diff to review. To add a format, add a fixture (`Fixtures/make-fixtures.sh`, which needs `ffmpeg`,
`lame` and `afconvert`; the HE-AAC, Opus and Vorbis outputs are not byte-reproducible, so re-run it only on
purpose) and regenerate with `GOLDEN_UPDATE=1`. A decoder bug found and not fixed is pinned in
`KnownIssues.swift` rather than left as a red test.

**Byte-source contract.** `GrowingFileContractTests` runs media3's `DataSourceContractTest` cases against
the source over `LoopbackMediaServer`. A new server behaviour is one `Resource` in the matrix of
`GrowingFileContractCase`. The loopback server speaks no TLS, so certificate trust is tested as a decision
over real `SecTrust`s (`GrowingFileConnectionPolicyTests`), not through a `URLSession` challenge.

## FFmpeg

`Frameworks/FFmpeg.xcframework` has three slices (ios-arm64, ios-arm64-simulator, macos-arm64), each one
`libffmpeg.a` of libavformat, libavcodec, libswresample and libavutil, plus headers, a `CFFmpeg` module
map, the LGPL text and `VERSION.txt` (tag, exact configure flags, applied patches: read it to see what a
build contains). `CStreamDecode` also links the system `z` and `iconv`.

### Rebuilding FFmpeg

Everything is disabled except the decoders, demuxers and parsers listed at the top of
`scripts/build-ffmpeg.sh`; `--disable-autodetect` stops a system library sneaking in. Formats are added
there, with a fixture and conformance case, because an untested format is not supported. The script needs
Xcode with the iOS SDKs and reads `FFMPEG_TAG`, `FFMPEG_SRC`, `OUT_DIR`, `BUILD_ROOT`, `DEPLOYMENT_TARGET`
and `MACOS_DEPLOYMENT_TARGET` (defaults in the script). After a rebuild:

1. `git diff` on `VERSION.txt` shows only the intended change.
2. `swift test`, conformance suite included, passes.
3. The framework is its own commit: `build: rebuild ffmpeg ...`.

Patches in `scripts/ffmpeg-patches/` are applied by the script to the cloned source and listed in
`VERSION.txt`. Add one only for a bug the pinned tag has and the decoder cannot work around, and say
what it fixes in the patch header (patch 0001: with a source of unknown length the MP3 demuxer discarded
the Xing frame count, losing the gapless trim and the duration).

## Releasing

`scripts/release.sh X.Y.Z` refuses a dirty tree, a branch other than `main`, a bad or existing version,
or a `main` behind `origin/main`. It runs `swift test`, runs `PlaybackStreamingTests` on an iOS simulator
(`IOS_SIM_UDID`, else the first available iPhone), tags the bare semver and pushes. Then bump the
consumer's `Package.swift` if the change matters to it and run its tests. A fix that changes neither API
nor output is a patch; the release note says what moved when PCM does.
