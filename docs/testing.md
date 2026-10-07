# Testing and releasing

Reference for the test suites and how to run them, with the steps to regenerate the conformance
goldens and cut a release. The repository has no hosted CI. `swift test` locally plus `scripts/release.sh` is the gate.

## Suites

| Test target | What it covers | Run with |
|---|---|---|
| `PlaybackDecodeTests` | The decoder against `AVAssetReader` on three committed 20 s tone fixtures (MP3, M4A with `moov` first, M4A with `moov` last). Also asserts how many bytes a trailing `moov` costs to open. | `swift test` |
| `PlaybackDecodeConformanceTests` | Every fixture through a faulting reader, then seeks, compared against goldens. | `swift test --filter PlaybackDecodeConformance` (about 30 s) |
| `PlaybackStreamingTests` | `GrowingFileByteSource`, `DownloadRetry`, `GrowingFileReadRule`, `GrowingFileStore`, the loopback server and decode equality over a growing file, against two tone fixtures. | `swift test`, and on an iOS simulator |

All of them run on macOS against the macOS slice of the FFmpeg xcframework, with no simulator. All
tests must pass before tagging. A test that needs a 30-minute MP3 with no Xing header generates it
with a host `ffmpeg` binary (the path is in `StreamTestSupport.swift`). It is skipped where there is
no such binary, and always on an iOS device or simulator. A test whose committed fixture file is
missing is skipped too. For why the suites are built this way, see
[Architecture](architecture.md#why-the-tests-are-shaped-this-way).

`LoopbackMediaServer` closes a short body a beat late. macOS URLSession drops a body's buffered
bytes if the connection ends before the delegate has answered the response.

## The iOS simulator step

The streaming tests also run on an iOS simulator, picked by UDID:

```sh
xcrun simctl list devices available
xcodebuild test -scheme shuttle-playback-Package -only-testing:PlaybackStreamingTests \
  -destination 'platform=iOS Simulator,id=<UDID>'
```

`scripts/release.sh` does this for you, using `IOS_SIM_UDID` if set, otherwise the first available
iPhone.

## The conformance suite

**Fixtures.** 28 files in `Tests/PlaybackDecodeConformanceTests/Fixtures`, plus the three in
`PlaybackDecodeTests/Fixtures`. They cover MP3 variants (Xing, VBRI, CBR, junk before the first frame,
ID3v1 footer, a sample-rate change, and noise that leans on the bit reservoir: 32 kbps CBR, an Info
tagged CBR, 8 kHz MPEG-2.5), AAC in ADTS and MP4 (including a fragmented MP4 with a `sidx`),
HE-AAC v1 and v2 in MP4 and in ADTS (where the header says AAC-LC), Opus and Vorbis. Three come from
the androidx/media project and are listed in `Fixtures/NOTICE`. `Fixtures/make-fixtures.sh` makes the
rest and needs `ffmpeg`, `lame` and `afconvert`. The HE-AAC, Opus and Vorbis files (Ogg and Matroska) are not
byte-reproducible, so re-run it only on purpose.

**Fault matrix.** Each fixture is decoded through `FaultyByteReader` under all 7 combinations of three
switches: partial reads, one-shot I/O errors, and unknown length. Each result must be bit-identical
to the clean decode in the same run. A resumed decode must match the clean one per second outside the
warm-up frames after a seek. MP3 and MP4 resume bit-exactly. Bytes read before the first audio are
budgeted under every combination.

**Seeks and goldens.** The suite then seeks to 0, 1/3, 2/3, 100 ms before the end and the end of
each fixture, and compares with `Goldens/<fixture>.json`. The seek to the end lands on end of stream
and pins no audio; the near-end one pins the last of it. A golden holds Int16 per-second PCM hashes,
the frame count, the seek landings and the fixture's own SHA-256.

**Regenerate goldens** after an intended decoder change, or a new fixture:

```sh
GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance
```

Then review the JSON diff. The suite writes a golden only if the fault matrix passes against it.

| Variable | Effect |
|---|---|
| `GOLDEN_UPDATE=1` | Rewrite the goldens. |
| `CONFORMANCE_FIXTURE=<file name>` | Run one fixture. |
| `CONFORMANCE_PLANT_DEFECT=1` | Drop a frame from the clean decode, to prove the suite fails. |

**Known issues.** A decoder bug that the suite found and that is not fixed is pinned in
`KnownIssues.swift`. A rule names the fixture, the kind of check, the exact fault combinations and
the exact finding, with its GitHub issue, and runs under `XCTExpectFailure`. A different value, or a
pinned finding that stops happening, fails the suite. When the bug is fixed, remove the rule. Rules
exist at present for #21 and #28, and `alignFrames` is 0 in every seek of every golden because
seeks land on
the requested sample. A seek to the end lands where the clean decode ends, so its empty window
counts as 0 too.

**MP3 seeks.** `MP3SeekTests` checks what the goldens cannot, since they compare a seek's PCM after a
warm-up: every MP3 fixture sought to seven places must decode bit-identically to the clean decode from
the target on, and a far CBR seek must read from at most 2 KiB before its target. A VBR MP3 with no
Xing header that drops from 112 to 32 kbps (`SeekFixtures/`, kept out of the matrix because its far
seeks land by estimate, issue #3) must decode a bit-exact stretch of the clean decode after each far
seek: it fails with a pre-roll counted from the first frame's bitrate alone.

**FFmpeg fixes.** Bugs in the pinned FFmpeg tag are fixed with patches that `build-ffmpeg.sh` applies. See
[FFmpeg](ffmpeg.md#local-patches).

## Release

Consumers pin a tag, such as `from: "0.3.0"`, never a branch.

```sh
scripts/release.sh 0.3.1
```

The script refuses:

- a dirty working tree,
- any branch other than `main`,
- a version that is not `X.Y.Z`, or a tag that exists,
- a `main` that is behind `origin/main`.

It then runs `swift test`, runs `PlaybackStreamingTests` on an iOS simulator, tags `X.Y.Z` (bare semver,
no `v` prefix), and pushes `main` and the tag. Afterwards, bump the consumer's `Package.swift`
requirement if the change matters to it, and run the consumer's own tests.

Versioning at 0.x:

- A public API change is a minor bump.
- A behaviour change in the decoder, where the PCM it produces differs, is at least a minor bump.
  The release note says what moved.
- A fix with no change to output or API is a patch.

Commits use conventional prefixes (`feat:`, `fix:`, `refactor:`, `build:`, `docs:`, `test:`) and go
straight to `main`.
