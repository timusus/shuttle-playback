# ADR-0015: Not built on AudioStreaming

Status: Accepted
Date: 2026-10-10

## Context

[AudioStreaming](https://github.com/dimitris-c/AudioStreaming) (release 1.4.5, 2026-09-14) is the
closest Swift library to this one. It streams over `URLSession`, parses with `AudioFileStream`, decodes
with `AudioConverter` and plays through `AVAudioEngine`. Both apps evaluated it and kept an FFmpeg
engine ([podcasts#392](https://github.com/timusus/shuttle-podcasts/issues/392),
[Shuttle2#687](https://github.com/timusus/Shuttle2/issues/687)). Checked against the 1.4.5 source:

- Formats are Apple's AudioFile types plus a custom Ogg Vorbis path, chosen by MIME type or extension
  (`AudioFileType.swift`). There is no Opus. Ogg Vorbis runs over libvorbisfile (`OggVorbisStreamProcessor`).
- It does handle moov-at-end MP4 files (`Mp4Restructure`), so that is not a gap.
- Seeking in Ogg Vorbis is not supported: `OggVorbisStreamProcessor.processSeek()` is empty and
  `isSeekable` is false for Ogg (README, `AudioPlayer.swift`, `OggVorbisStreamProcessor.swift`).
- A frame filter is `(AVAudioPCMBuffer, AVAudioTime) -> Void` on a tap (`FrameFilterProcessor.swift`).
  It observes the output; it cannot drop or replace frames, so cutting silence or an ad from the
  stream is not possible.
- Its failure handling is a timed retry that re-seeks to the current position (`RemoteAudioSource.retryOnError`),
  with no validator or frontier rule ([ADR-0004](0004-one-recovery-layer-in-the-byte-source.md)).

## Decision

We will not adopt or fork AudioStreaming. The decode and stream stack stays our own: FFmpeg
([ADR-0001](0001-ffmpeg-for-demux-and-decode.md)) behind `GrowingFileByteSource`
([ADR-0003](0003-growing-file-playback.md)).

## Alternatives rejected

- Adopt it: no Opus, no Ogg seek, and filters that cannot cut audio.
- Fork it: the gaps are in its design (Apple parsers, a tap-based filter), so a fork would replace
  its decode and filter path and keep only the queue and the engine wiring.

## Consequences

- We own the decode and stream stack and its LGPL FFmpeg build, and with them the conformance suite
  ([ADR-0008](0008-conformance-testing-modelled-on-media3.md)).
- Ideas worth taking from it: a one-object `play(url:)` / `queue(url:)` API, filters that are named and
  insertable at runtime, ICY metadata handling, and its client-certificate (mTLS)
  tests (`MutualTLSIntegrationTests`, `ClientCertificateChallengeTests`).
- Revisit if it gains Opus, Ogg seeking and a filter that can drop frames.

Links: [podcasts#392](https://github.com/timusus/shuttle-podcasts/issues/392),
[Shuttle2#687](https://github.com/timusus/Shuttle2/issues/687).
