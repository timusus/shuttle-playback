# ADR-0010: The decoder owns output format conversion

Status: Accepted
Date: 2026-10-08

## Context

[ADR-0005](0005-shared-engine-repo.md) keeps effects and DSP in the apps. But a player's audio graph
needs one steady format, and some sources change rate or channel layout mid-stream: a stitched MP3
that switched from 44.1 to 48 kHz played the later part at the wrong speed and pitch.

## Decision

The decoder outputs Float32 interleaved at the source rate and channel count by default. When a
frame's rate, layout or sample format changes mid-stream, it resamples to the format reported at open
(commits bba9393, 5718084; #14). An app that needs a fixed output format for a gapless graph can ask
for one with `setOutputFormat` (#20).

Format conversion is part of producing PCM a player can use. Effects (skip-silence, Voice Boost) stay
in the apps, as PCM in and PCM out.

## Alternatives rejected

- Pass format changes through and let each app resample: both apps would need the same code, and a
  wrong-speed bug is silent.
- Always resample to a fixed rate: it costs quality and work for the common case of one steady rate.

## Consequences

- The decoder links a resampler and carries its tail and timing across a format change.
- Seeking into a resampled section is timed by byte offset, never bit-identical (the `stitch_*` fixtures).
- At a non-native output rate a seek is exact in time and frame count, but not bit-identical for its first few frames while the resampler warms up.

Links: [ADR-0005](0005-shared-engine-repo.md), [architecture](../architecture.md).
