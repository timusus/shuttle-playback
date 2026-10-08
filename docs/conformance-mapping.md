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
| `mp3Sample_withIndexSeekingFlag_usesCbrSeekerForKnownLength` | `bear-vbr-no-seek-table.mp3`; its 1.872 s seek lands 896 frames early in the golden (VBR with no tag: a seek far from a frame of known time lands by bitrate estimate, as in media3; accepted) |
| `mp3CbrSampleWithIndexSeekingFlagAndUnknownLength_reportsUnsetAverageBitrate` | `bear-cbr-variable-frame-size-no-seek-table.mp3` under the `unknownLength` combinations; bitrate getter is n/a (API) |
| `mp3CbrSampleWithNoSeekTableAndTrailingGarbage` | `bear-cbr-no-seek-table-trailing-garbage.mp3` (media3 reports 2.82 s, its dump `durationUs` 2821187; ours reports the open-time bitrate estimate, 12.2 s, as media3 does before its correction; at EOF `mediaFramesRead / sampleRate` is 2.8212 s, the golden's `durationAtEofS`, within 0.011 s of media3's; `HeaderlessCBRDurationTests`; issue #53) |
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

`sine-wave-cbr-trailing-id3v1.mp3` is ported but media3 uses it only in `test_utils/.../AssetInfo.java`, not in the five extractor test classes; it is covered here by the conformance matrix and its golden.

Not ported: `1024_incrementing_bytes.mp3` (not audio; no MP3 test above uses it).

## Ogg (`libraries/extractor/.../ogg/`)

Assets are copied from `libraries/test_data/src/test/assets/media/ogg/`; the three `bbb_*` files carry Big Buck Bunny audio (CC BY 3.0, attribution in `Fixtures/NOTICE`). Extra `n/a` reasons: **bytes** (a unit test on hand-built Ogg page bytes, which are not decodable audio, so there is nothing to compare), **codec** (outside our FFmpeg build).

### OggExtractorParameterizedTest

| media3 test | Ours |
|---|---|
| `opus` | `bear.opus` |
| `opus_duplicateHeader` | `bear_duplicate_header.opus` |
| `flac` | `bear_flac.ogg`; finding #57 (resume after an I/O error decodes extra frames) |
| `flacNoSeektable` | `bear_flac_noseektable.ogg`; finding #57 |
| `vorbis` | `bear_vorbis.ogg` |
| `vorbisWithGapBeforeSecondPage` | `bear_vorbis_gap.ogg` |
| `vorbisWithPacketSpanningBetweenPages` | `bear_vorbis_with_large_metadata.ogg` |

### OggExtractorNonParameterizedTest

| media3 test | Ours |
|---|---|
| `read_afterEndOfInput_doesNotThrowIllegalState` | n/a (API); `bear_flac.ogg` decodes to its end in the matrix |
| `sniffVorbis`, `sniffFlac`, `sniffFailsOpusFile`, `sniffFailsInvalidOggHeader`, `sniffInvalidHeader`, `sniffFailsEOF` | n/a (sniff; the assets `vorbis_header`, `flac_header`, `opus_header`, `invalid_ogg_header`, `invalid_header`, `eof_header` are 27 to 35 bytes of header, not audio) |

### OggPacketTest, OggPageHeaderTest, VorbisReaderTest

| media3 test | Ours |
|---|---|
| `readPacketsWithEmptyPage`, `readPacketWithZeroSizeTerminator`, `readContinuedPacketOverTwoPages`, `readContinuedPacketOverFourPages`, `readDiscardContinuedPacketAtStart`, `readZeroSizedPacketsAtEndOfStream` | n/a (bytes: `OggPacket` unit tests on crafted pages, assets of 294 to 1141 bytes with no audio); packets spanning pages are decoded by `bear_vorbis_with_large_metadata.ogg` |
| `parseRealFile` | `bear.opus` |
| `skipToNextPage_*` (3), `populatePageHeader_*` (4) | n/a (API: `OggPageHeader` parsing; `page_header` is 29 bytes) |
| `appendNumberOfSamples`, `readSetupHeaders_withIOExceptions_readSuccess` | n/a (API: `VorbisReader` internals, asset `binary/ogg/vorbis_header_pages` is headers only); I/O errors during Vorbis setup are in the fault matrix of `bear_vorbis.ogg` |

### DefaultOggSeekerTest

| media3 test | Ours |
|---|---|
| `setupWithUnsetEndPositionFails`, `readGranuleOfLastPage_*` (3) | n/a (API: `DefaultOggSeeker`; `three_headers` is 2.4 KB of headers) |
| `seeking` | n/a (bytes: `random_1000_pages` is 1 MB of random pages, not audio; over the size limit); seeks of the Ogg fixtures are in their goldens, all exact |

Playback tests in `exoplayer/.../e2etest/` (`OggPlaybackTest`, `OggOpusPlaybackTest`) are player-level and stay in the apps; their audio assets `bbb_1ch_16kHz_q10_vorbis.ogg` and `bbb_6ch_8kHz_opus.ogg` (mono 16 kHz Vorbis, 6-channel Opus) are ported.

## WAV (`libraries/extractor/.../wav/`)

Assets are copied from `libraries/test_data/src/test/assets/media/wav/`. Seven of these WAVs show the #36 double read under `unknownLength` (pinned per fixture in `KnownIssues.swift`).

### WavExtractorTest

| media3 test | Ours |
|---|---|
| `sample` | `sample.wav` (8-bit and 24-bit variants below) |
| `sample_withTrailingBytes_extractsSameData` | `sample_with_trailing_bytes.wav` |
| `sample_withOddMetadataChunkSize_extractsSameData` | `sample_with_odd_metadata_chunk_size.wav` |
| `sample_imaAdpcm` | `sample_ima_adpcm.wav`; n/a (codec: IMA ADPCM is not in our FFmpeg build, the golden records an open error (`streaming decode failed, status 5`)) |
| `sample_rf64` | `sample_rf64.wav` |
| `sample_wav_format_extensible` | `sample_wav_format_extensible.wav` (6 channels); finding #58 (more bytes before the first audio after an I/O error under partial reads) |
| `sample_float64` | `sample_float64.wav` |

Other WAV assets in media3 (used by the muxer, playback and transformer tests, not `WavExtractorTest`) are ported too, since they widen the format coverage: `sample_8bit.wav`, `sample_float32.wav`, `sample_96khz.wav`, `sample_192khz.wav` (the 192 kHz mono case), `sine_24le.wav`, `sine_32le.wav`, `bbb_2ch_44kHz.wav` and `sample_80KHz_mono_20_repeating_1_samples.wav` (20 frames). No media3 asset in either folder was skipped for size except `random_1000_pages`.

## MP4 (`libraries/extractor/.../mp4/`)

The decoder is audio-only, so a media3 asset with video is ported only when its audio track is the point or the file shows a container structure (fragmentation, a bad box, an empty track); the video decodes are not compared. Assets over 1 MB are skipped. Extra n/a reason: **video** (video, subtitle, metadata or auxiliary track behaviour only), **codec** (a codec outside the FFmpeg build: AC-3, E-AC-3, AC-4, DTS, TrueHD, MPEG-H, IAMF, VVC, AV1, APV).

Exceptions to "every seek has `alignFrames` 0": the goldens of `sample_empty_track.mp4` and `sample_partially_fragmented.mp4` pin -1939 and -4882 (#64), `sample_fragmented.mp4` pins +2942/+2943/+2228/null (#65). In each the PCM after a seek is right and the reported landing is not, because the decoder's time zero (`start_time`) is not where the first output frame sits. Fixing one changes only that fixture's seek goldens; regenerate them with `GOLDEN_UPDATE=1` and expect 0.

### Mp4ExtractorParameterizedTest (one row per asset; each runs the 4 `.N.dump` seek variants and `unknown_length`)

| media3 asset | Ours |
|---|---|
| `sample.mp4` | `sample.mp4` (libfaac: the AAC decoder drops the first frame itself, #63, fixed) |
| `sample_alac.mp4`, `sample_alac_20bit.mp4` | same names |
| `sample_opus.mp4` | `sample_opus.mp4` |
| `sample_mp2_audio.mp4` | `sample_mp2_audio.mp4` (MP3 in MP4) |
| `sample_fpcm_32be/32le/64be/64le.mp4`, `sample_ipcm_16be/24le.mp4`, `sowt_pcm_variable_sample_size.mp4` | same names |
| `sample_fixed_rechunk_no_elst.mp4` | same name (`FixedSampleSizeRechunkerTest` itself is n/a: API) |
| `sample_empty_track.mp4` | same name; finding #64 (seeks land 1939 frames late; libfaac, the 1024-frame decoder trim is #63, fixed) |
| `sample_mdat_too_long.mp4` | same name; finding #60 (unknown length ends in failure) |
| `sample_missing_stsd.mp4` | same name; the golden expects "no decodable audio" (status 4): without an `stsd` the audio track has no codec, so there is nothing to decode |
| `bt601.mov` | same name (QuickTime, AAC audio, libfaac like `sample.mp4`) |
| `sample_2_byte_NAL_length.mp4`, `sample_18byte_nclx_colr.mp4`, `sample_android_slow_motion.mp4`, `sample_with_btrt.mp4`, `sample_with_color_info.mp4`, `sample_with_colr_mdcv_and_clli.mp4`, `sample_with_invalid_nalu.mp4`, `sample_unrecognized_hevc_sei.mp4`, `sample_with_it35_track.mp4`, `sample_with_fake_auxiliary_tracks*.mp4`, `sample_rotate_and_reflect.mp4`, `h265_bframes.mp4`, `sample_with_av1c.mp4`, `water_180_mvhevc_5frames.mov` | n/a (video: audio track identical to `sample.mp4` or none) |
| `sample_with_metadata.mp4`, `sample_with_numeric_genre.mp4`, `sample_with_chapters.mp4`, `sample_with_nero_chapters_only.mp4` | n/a (metadata: tags and chapters; audio is `sample.mp4`'s) |
| `sample_ac3.mp4`, `sample_eac3.mp4`, `sample_eac3joc.mp4`, `sample_ac4*.mp4`, `sample_dthd.mp4`, `sample_dts_express.mp4`, `sample_dts_hd_ma.mp4`, `sample_mhm1_*.mp4`, `sample_mpegh_*.mp4`, `sample_iamf.mp4`, `sample_vvc.mp4` | n/a (codec) |
| `sample_edit_list.mp4` (3.3 MB), `sample_edit_list_no_sync_frame_before_edit.mp4` (3.3 MB), `sample_with_original_quicktime_specification.mov` (4.7 MB), `sample_with_apvc.mp4` (8.5 MB), `h265_4k_bframes_emulation_prevention.mp4` (17 MB), `pixel-motion-photo-2-hevc-tracks.mp4` (3.5 MB) | not ported (over 1 MB; the edit-list asset is video-led, the repo's `aac_edit_list.m4a` covers audio edit lists) |

### Mp4ExtractorNonParameterizedTest

| media3 test | Ours |
|---|---|
| `extract_withMalformedFreeBox_succeeds` | `sample_malformed_free_box.mp4`; finding #59 (fails to open: free box declares size 3); the golden records the failure |
| `getSeekPoints_withEmptyTracks_returnsValidInformation` | `sample_empty_track.mp4` |
| `sniff_reportsUnsupportedBrandsFailure`, `sniff_reportsWrongFragmentationFailure`, `sniff_returnsTrueWithoutPeekingLargeStbl` | n/a (sniff); `large_stbl_truncated_after_moov.m4b` (1.1 MB) not ported |
| `extract_fileHavingAuxiliaryTracks*`, `extract_withOmitTrackSampleTableFlag*`, `extract_h264/h265WithoutGopParsingFlags`, `extract_withPoorlyMuxedIt35Track_*` | n/a (API: flags; video) |

### FragmentedMp4ExtractorParameterizedTest and NonParameterizedTest

| media3 asset or test | Ours |
|---|---|
| `sample_fragmented.mp4` | same name; findings #65 (stream start_time later than the first frame: seeks land early) |
| `sample_fragmented_seekable.mp4`, `sample_fragmented_large_bitrates.mp4` | n/a (decode PCM identical to `sample_fragmented.mp4`; only the sidx/bitrate boxes differ) |
| `sample_partially_fragmented.mp4` | same name; finding #62 (unknown length decodes 0 frames); #64 (first frame far from start_time: seeks land late) |
| `sample_opus_fragmented.mp4` | same name; finding #61 (unknown length stops at 0.5 s) |
| `sample_fragmented_sei.mp4`, `sample_fragmented_uuid.mp4`, `sample_fragmented_sgpd_v2.mp4`, `sample_fragmented_variable_length_sgpd.mp4`, `fragmented_captions*.mp4`, `sample_fragmented_seekable_multiple_sidx.mp4` | n/a (video / metadata: no audio of interest beyond `sample_fragmented.mp4`) |
| `sample_ac3_fragmented.mp4`, `sample_eac3*_fragmented.mp4`, `sample_ac4*_fragmented.mp4`, `sample_ac4_protected.mp4`, `sample_fragmented_dts_*.mp4`, `sample_fragmented_iamf.mp4`, `sample_mhm1_*_fragmented.mp4` | n/a (codec; `sample_ac4_protected.mp4` is also encrypted) |
| `sniff_*`, `extract_h264/h265WithoutGopParsingFlags` | n/a (sniff; API: flags) |
| `FragmentedMp4ExtractorNoSniffingTest` (`sample_fragmented_sideloaded_track.mp4`) | n/a (API: a side-loaded subtitle track; the file alone does not open in FFmpeg, "trun track id unknown", and nothing audible is lost) |
| `FragmentedMp4ExtractorTest`-style other classes (`BoxParserTest`, `MetadataUtilTest`, `PsshAtomUtilTest`) | n/a (API) |

## ADTS and LATM (`libraries/extractor/.../ts/`, `.../mp3/` siblings)

media3 reads raw ADTS with `AdtsExtractor` (`AdtsExtractorTest`, assets under `media/ts/`) and LATM only
inside MPEG-TS (`TsExtractor`).

### AdtsExtractorTest (one row per asset; each runs the 4 `.N.dump` seek variants and `unknown_length`)

| media3 asset or test | Ours |
|---|---|
| `sample`, `sample_withSeeking` | `sample.adts`; no findings |
| `sample_with_id3` | `sample_with_id3.adts` (ID3v2 prefix before the first ADTS frame); no findings |
| `sample_withSeekingAndTruncatedFile` | `sample_cbs_truncated.adts` (stream cut mid-frame); no findings |
| `sample_cbs.adts` | not in the media3 assets (only its dumps exist) |
| `sample_latm.ts` (`TsExtractorTest`) | n/a (MPEG-TS container, which this repo does not support; the repo's own `latm_loas.aac` covers raw LOAS/LATM) |
| `bbb_1ch_8kHz_aac_lc.aac`, `sine.aac` | n/a (used by transformer tests, not an extractor test; `bbb_*` is not copied) |
| the extractor's `FLAG_ENABLE_CONSTANT_BITRATE_SEEKING` | n/a (API: flag; seeks are sample-accurate here) |
