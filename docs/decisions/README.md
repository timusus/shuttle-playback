# Decisions

Short records of why the engine is built the way it is. The template is
[ADR-0000](0000-template.md). The how is in [architecture](../architecture.md).

| ADR | Decision |
|---|---|
| [0001](0001-ffmpeg-for-demux-and-decode.md) | FFmpeg demuxes and decodes (one build, see 0006). |
| [0002](0002-one-player-no-hls.md) | The engine has one decode path and no HLS. |
| [0003](0003-growing-file-playback.md) | One download to disk per transaction, read while it grows. |
| [0004](0004-one-recovery-layer-in-the-byte-source.md) | Network recovery lives only in the byte source. |
| [0005](0005-shared-engine-repo.md) | The decode layer is one shared repo, and effects stay in the apps. |
| [0006](0006-one-superset-ffmpeg.md) | One FFmpeg, the music superset, linked by both apps. |
| [0007](0007-one-network-byte-source.md) | Both apps use `GrowingFileByteSource`; the range-window source stays out. |
| [0008](0008-conformance-testing-modelled-on-media3.md) | Conformance testing follows media3: fault matrix, goldens, a fixture per format. |
| [0009](0009-seeks-are-sample-accurate.md) | A seek decodes a pre-roll and drops it, landing on the requested sample. |
| [0010](0010-the-decoder-owns-output-format-conversion.md) | The decoder resamples mid-stream format changes; effects stay in the apps. |
| [0011](0011-probe-budget-and-junk-resync.md) | A 64 KiB probe, then an MP3 resync scan of up to 1 MiB for chained frames. |

These decisions were first made in the Shuttle Podcasts app and moved here with the code.
