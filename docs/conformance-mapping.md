# Conformance mapping: media3 test cases to this repo

Each row is one test case of an androidx/media extractor test class, and where this repo covers it:
a fixture in `Tests/PlaybackDecodeConformanceTests/Fixtures` (every fixture runs the fault matrix, the
seeks and the golden in `Goldens/` automatically), a named test, or `n/a` with the reason. The media3
assets are copied unmodified (see `Fixtures/NOTICE`, media3 commit `8c6678b657ede1e7883fc164ef73ed483c7796c3`).

To add an extractor: add a section with the same three columns, one row per `@Test` method (a
parameterised method is one row), copy the assets it uses, generate goldens with
`GOLDEN_UPDATE=1 CONFORMANCE_FIXTURE=<file> swift test --filter PlaybackDecodeConformance`, and pin any
finding in `KnownIssues.swift` under an issue number. Raise the fixture count in
`ConformanceMatrix.swift`. Cases about media3's own API (flags, `SeekMap` objects, metadata entries,
sniffing, bitrate getters) are `n/a`: this repo has no such surface; the decoded PCM is what is compared.

`n/a` reasons used below: **API** (a media3 class or flag with no counterpart), **metadata** (ID3 tags,
ReplayGain; this repo decodes audio only), **sniff** (media3's `peekLimit` format sniffing).

## MP3 (`libraries/extractor/.../mp3/`)

### Mp3ExtractorTest

| media3 test | Ours |
|---|---|
| `mp3SampleWithXingHeader` | `bear-vbr-xing-header.mp3` (matrix, goldens, seeks) |
| `mp3SampleWithXingHeader_noTableOfContents` | `bear-vbr-xing-header-no-toc.mp3` |
| `mp3SampleWithInfoHeader` | `test-cbr-info-header.mp3` |
| `mp3SampleWithInfoHeader_usesGaplessDurationAndAverageBitrate` | golden `frames` 44100 (gapless trim) for `test-cbr-info-header.mp3`; bitrate getter is n/a (API) |
| `mp3SampleWithInfoHeader_invalidDataSizeFallsBackToFrameBitrate` | n/a (API: bitrate getter; the file is not modified in the test, so no new input) |
| `mp3SampleWithInfoHeaderAndPcutFrame` | `test-cbr-info-header-pcut-frame.mp3` |
| `mp3SampleWithInfoHeaderAndTrailingGarbage` | `test-cbr-info-header-trailing-garbage.mp3`; finding #50 (unknown length decodes 44100 frames, known length 44975) |
| `mp3SampleWithVbriHeader` | `bear-vbr-vbri-header.mp3` |
| `mp3SampleWithVbriHeaderWithTruncatedToC` | `bear-vbr-vbri-header-truncated-toc.mp3` |
| `mp3SampleWithCbrSeeker` | `bear-cbr-variable-frame-size-no-seek-table.mp3` (flag variants n/a: API) |
| `mp3Sample_withIndexSeekingFlag_usesCbrSeekerForKnownLength` | `bear-vbr-no-seek-table.mp3`; its 1.872 s seek lands 896 frames early in the golden (VBR with no tag, issue #3) |
| `mp3CbrSampleWithIndexSeekingFlagAndUnknownLength_reportsUnsetAverageBitrate` | `bear-cbr-variable-frame-size-no-seek-table.mp3` under the `unknownLength` combinations; bitrate getter is n/a (API) |
| `mp3CbrSampleWithNoSeekTableAndTrailingGarbage` | `bear-cbr-no-seek-table-trailing-garbage.mp3` (golden duration 12.2 s is the bitrate estimate over the garbage; the decoded frames are 2.82 s) |
| `trimmedMp3Sample` | `play-trimmed.mp3`; finding #51 (a single-frame file does not open; the golden records the error) |
| `mp3SampleWithId3` | `bear-id3.mp3` (audio only; metadata n/a) |
| `mp3SampleWithId3NumericGenre` | `bear-id3-numeric-genre.mp3` (audio only; metadata n/a) |
| `cbrSeeker_seekToEndOfStreamAfterPartialRead_doesNotIncorrectlyShortenDuration` | `bear-cbr-variable-frame-size-no-seek-table.mp3`: the end-of-stream seeks in the golden, `EndOfStreamSeekTests` |
| `sampleWith100kBGarbagePrefix_sniffsSuccessfully` | `100kB-garbage-prefix.mp3` decodes (probe budget differs from media3's sniff); `garbage_prefix_80k.mp3` is the older fixture |
| `sampleWith200kBGarbagePrefix_sniffingFailsAfterPeeking128kB` | `200kB-garbage-prefix.mp3` decodes in full, where media3 refuses to sniff it (sniff: n/a) |
| `sampleWithLameReplayGainFast` | `bear-vbr-xing-header-replaygain-fast.mp3` (audio only; ReplayGain n/a) |
| `sampleWithLameReplayGainAccurate` | `bear-vbr-xing-header-replaygain-accurate.mp3` |
| `mp3SampleWithId3_withDisableArtworkFlag_parsesTextButOmitsArtwork` | n/a (metadata) |

### ConstantBitrateSeekerTest (`bear-cbr-constant-frame-size-no-seek-table.mp3`, `bear-cbr-variable-frame-size-no-seek-table.mp3`)

| media3 test | Ours |
|---|---|
| `mp3ExtractorReads_returnSeekableCbrSeeker` | n/a (API); both fixtures seek in their goldens |
| `getSeekPoints_atExplicitDuration_returnsFinalFrameSeekPoint` | n/a (API); end seeks in the goldens |
| `seeking_handlesSeekToZero` / `_handlesSeekToEoF` / `_handlesSeekingBackward` / `_handlesSeekingForward` | golden seeks (0, 1/3, 2/3, end minus 100 ms, end), compared sample-accurately, plus `testMP3SeeksDecodeTheCleanPCMFromTheTargetSample` and `testAFarCBRSeekReadsFromJustBeforeItsTarget` |
| `seeking_variableFrameSize_seeksNearlyExactlyToCorrectFrame` | `bear-cbr-variable-frame-size-no-seek-table.mp3`, same tests |

### IndexSeekerTest (`bear-vbr-xing-header-no-toc.mp3`)

| media3 test | Ours |
|---|---|
| `mp3ExtractorReads_returnsSeekableSeekMap`, `constructor_*` (2) | n/a (API) |
| `mp3ExtractorReads_preservesGaplessDurationAfterEof` | golden `frames` and the end seeks of `bear-vbr-xing-header-no-toc.mp3` |
| `seeking_handlesSeekToZero` / `_handlesSeekToEof` / `_handlesSeekingBackward` / `_handlesSeekingForward` | golden seeks, plus `testXingVBRMP3SeeksExactlyNearAndCheaplyFar` |

### VbriSeekerTest

| media3 test | Ours |
|---|---|
| `getAverageBitrate_returnsAverageFromDataSizeAndDuration` | n/a (API: bitrate getter); VBRI streams are `bear-vbr-vbri-header*.mp3` |

### XingSeekerTest (synthetic header bytes, no asset)

| media3 test | Ours |
|---|---|
| `getTimeUsBeforeFirstAudioFrame`, `getTimeUsAtFirstAudioFrame`, `getTimeUsAtEndOfStream` | n/a (API: unit tests on `XingSeeker`); `vbr_xing.mp3` and `bear-vbr-xing-header.mp3` |
| `getAverageBitrate_*` (2) | n/a (API) |
| `getTimeUsAtEndOfStream_xingLengthLongerThanStream`, `getSeekPointsAtEndOfStream_xingLengthLongerThanStream`, `getTimeForAllPositions_xingLengthLongerThanStream` | `vbr_xing_longer_than_stream.mp3` |
| `getTimeUsAtEndOfStream_streamLengthNotKnown`, `getSeekPointsAtEndOfStream_streamLengthNotKnown`, `getTimeForAllPositions_streamLengthNotKnown` | the `unknownLength` fault combinations of every Xing fixture |
| `getSeekPointsAtStartOfStream`, `getSeekPointsAtEndOfStream`, `getTimeForAllPositions` | golden seeks of the Xing fixtures, `testXingVBRMP3SeeksExactlyNearAndCheaplyFar` |

Not ported: `1024_incrementing_bytes.mp3` (not audio; no MP3 test above uses it).
