# ADR-0002: One decode path, no HLS

Status: Accepted
Date: 2026-09-14

Originally recorded in Shuttle Podcasts as ADR-0003.

## Context

The first plan kept `AVPlayer` as a fallback for HLS, behind a rollout gate. A sample of 42,000 of
the 21 million episodes in Shuttle Podcasts' catalogue contained no `.m3u8` enclosures. 93% were MP3
and 6% were M4A, MP4 or AAC. The `AVPlayer` path also tied playback to the app's scanner through one
resource loader, so a scanner fault could stall audio.

## Decision

The engine has one decode path, `FFmpegStreamDecoder` over a `StreamByteReader`. There is no
`AVPlayer` fallback and no HLS support. An HLS URL fails to open, and the app decides what to show.

## Alternatives rejected

- Keep `AVPlayer` for HLS with a fallback counter: two players to test, for a format almost nothing
  in the catalogue uses.
- FFmpeg's `hls` demuxer: it opens playlists through its own URL protocols and cannot run over
  custom IO. The build also disables protocols and networking.

## Consequences

- An HLS-only show would not play. None is known.
- One path to verify.
- The sample was 42,000 episodes, not the whole catalogue.
- HLS can return later as a separate byte source or a separate product, without touching the decoder.
  It is not planned.

Links: [architecture](../architecture.md).
