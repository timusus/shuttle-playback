# ADR-0001: FFmpeg for demux and decode

Status: Accepted
Date: 2026-09-09 (FFmpeg decode); 2026-10-07 (static link kept); superseded in part by ADR-0006 (one build, no profiles)

## Context

The engine needs a streaming demuxer and decoder for whatever container a server sends, including
MP4 with the `moov` atom at the end of the file. An app that also runs its own code against
libavformat can then decode with the same FFmpeg as the player.

## Decision

We demux and decode with FFmpeg (tag n7.1) through a custom seekable `AVIOContext`. The build is one
format set shared by both apps (ADR-0006). FFmpeg stays statically linked.

## Alternatives rejected

- `AudioFileStream` with `AudioConverter`: cannot stream an MP4 whose `moov` is at the end
  (`kAudioFileStreamError_NotOptimized`). We would write an MP4 sample-table parser and an Ogg
  demuxer ourselves.
- `AVAssetReader`: needs a finished, seekable asset. Given an `https://` URL it yields no frame and
  no error.
- Separate SwiftPM products per format set: two C targets built from the same sources, for no
  consumer.

## Consequences

- A C shim and an FFmpeg build script to maintain. The library is about 2.6 MB per
  platform slice.
- Adding Ogg was a rebuild flag, not a parser.
- Static linking against an LGPL library leaves the relinking question open for closed-source
  consumers. Revisit if it matters to one.
- The shim stays codec-agnostic. A missing codec is FFmpeg saying no, never a branch of ours.
- FFmpeg bugs the tag lacks are fixed with local patches. See [contributing](../contributing.md#ffmpeg).

Links: [architecture](../architecture.md), [contributing](../contributing.md#ffmpeg).
