# Decisions

Short records of why the engine is built the way it is: the decision and its reason, not its history.
The template is [ADR-0000](0000-template.md). An ADR that a later one changes says so in its status line
and is kept as history. The overview is in [architecture](../architecture.md).

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-ffmpeg-for-demux-and-decode.md) | FFmpeg demuxes and decodes. | Accepted; one build per 0006 |
| [0002](0002-one-player-no-hls.md) | One decode path and no HLS. | Accepted |
| [0003](0003-growing-file-playback.md) | One download to disk per transaction, read while it grows. | Accepted; cache is per store per 0007; read-ahead cap per 0013; one sparse file per session per 0014 |
| [0004](0004-one-recovery-layer-in-the-byte-source.md) | Network recovery lives only in the byte source. | Accepted; amended by 0016, 0017 |
| [0005](0005-shared-engine-repo.md) | One shared decode repo; effects stay in the apps. | Accepted; amended by 0006, 0007 |
| [0006](0006-one-superset-ffmpeg.md) | One FFmpeg, the music superset, for both apps. | Accepted |
| [0007](0007-one-network-byte-source.md) | Both apps use `GrowingFileByteSource`; no range-window source. | Accepted |
| [0008](0008-conformance-testing-modelled-on-media3.md) | Conformance testing follows media3: fault matrix, goldens, a fixture per format. | Accepted |
| [0009](0009-seeks-are-sample-accurate.md) | A seek decodes a pre-roll and drops it, landing on the requested sample. | Accepted |
| [0010](0010-the-decoder-owns-output-format-conversion.md) | The decoder resamples; effects stay in the apps. | Accepted |
| [0011](0011-probe-budget-and-junk-resync.md) | A 64 KiB probe, then a bounded MP3 resync scan. | Accepted |
| [0012](0012-one-seek-strategy-per-format.md) | Each format's seek rules are one module behind `SeekFormat`; `seek.c` owns the ladder. | Accepted |
| [0013](0013-read-ahead-on-expensive-paths.md) | On an expensive path a source given a read-ahead pauses that far ahead of the decoder. | Accepted |
| [0014](0014-one-sparse-file-per-session.md) | Every transaction of a session writes into one sparse file; a restart keeps its bytes. | Accepted; amended by 0016, 0017 |
| [0015](0015-not-built-on-audiostreaming.md) | Not built on AudioStreaming: no Opus, no Ogg seek, filters cannot drop frames. | Accepted |
| [0016](0016-overlap-check-at-every-join.md) | Every join (resume, session-file restart) is checked by a 64 KiB overlap with the bytes on disk. | Accepted |

These decisions were first made in the Shuttle Podcasts app and moved here with the code.
