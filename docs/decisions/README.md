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

These decisions were first made in the Shuttle Podcasts app and moved here with the code.
