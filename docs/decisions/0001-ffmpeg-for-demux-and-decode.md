# ADR-0001: FFmpeg for demux and decode

Status: Accepted
Date: 2026-09-09 (FFmpeg decode); 2026-10-07 (per-app profiles, static link kept)

Originally recorded in Shuttle Podcasts as ADR-0002.

## Context

The engine needs a streaming demuxer and decoder for whatever container a server sends, including
MP4 with the `moov` atom at the end of the file. Shuttle Podcasts already bundled FFmpeg for its
ad-skip scanner, so the player and the scanner can decode with the same code.

## Decision

We demux and decode with FFmpeg (tag n7.1) through a custom seekable `AVIOContext`. Each app chooses
its formats with a build profile. The `podcast` profile has MP3, AAC (ADTS and LATM), MP4/M4A, Ogg,
Opus and Vorbis. Music formats belong to a `music` profile that is still a stub. FFmpeg stays
statically linked.

## Alternatives rejected

- `AudioFileStream` with `AudioConverter`: cannot stream an MP4 whose `moov` is at the end
  (`kAudioFileStreamError_NotOptimized`). We would write an MP4 sample-table parser and an Ogg
  demuxer ourselves.
- `AVAssetReader`: needs a finished, seekable asset. Given an `https://` URL it yields no frame and
  no error.
- Separate SwiftPM products per format set: two C targets built from the same sources, for no
  consumer.

## Consequences

- A C shim and an FFmpeg build script to maintain. The podcast-profile library is about 2.5 MB per
  platform slice.
- Adding Ogg was a rebuild flag, not a parser.
- Static linking against an LGPL library leaves the relinking question open for closed-source
  consumers. Shuttle2 went dynamic for that reason. Revisit if it matters to a consumer.
- The shim stays codec-agnostic. A missing codec is FFmpeg saying no, never a branch of ours.
- FFmpeg bugs the tag lacks are fixed with local patches. See [FFmpeg](../ffmpeg.md).

Links: [architecture](../architecture.md), [FFmpeg](../ffmpeg.md).
