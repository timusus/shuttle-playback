# ADR-0009: Seeks are sample-accurate

Status: Accepted
Date: 2026-10-08

## Context

A seek that lands on a frame boundary is off by up to a frame, and an AAC or Opus decoder that starts
cold produces wrong samples for a while. The first conformance goldens recorded that error as
`alignFrames`. A player that scrubs, resumes or cuts at a sample cannot use it.

## Decision

A seek starts a pre-roll before the target (16384 samples, 32768 for Opus), decodes it and drops
everything before the target sample, so every golden's `alignFrames` is 0. AAC reopens its codec at
every seek, with a longer pre-roll for HE-AAC's SBR, and an MP3's pre-roll is sized from its unpadded
main data. This replaced the frame-coarse landing (commits 8a30035, d3cd08d, ba2da36, 6b1c519).

## Alternatives rejected

- Land on the frame and report the misalignment: the apps would each compensate.
- Apply the Ogg index landing to every demuxer: in a 30-minute CBR MP3 it decoded 12 MB to reach the
  target, so it stays with Ogg, bounded by the anchor gap.

## Consequences

- A seek decodes a pre-roll, so it costs more than a frame-coarse seek.
- One landing is still inexact: a VBR MP3 seek further from a frame of known time than one seek's byte
  budget lands by the Xing TOC or a bitrate estimate, because no MP3 frame carries its time (#3).
- Reporting whether a landing was exact is an idea, not a decision (#26).

Links: [testing](../testing.md), [architecture](../architecture.md).
