# ADR-0011: Probe budget and junk resync

Status: Accepted
Date: 2026-10-08

## Context

Opening a stream reads bytes before the first audio, and on a network each byte costs latency and
data. Some MP3s carry far more junk before the audio than FFmpeg's own scan of 64 KiB looks through.
media3 peeks up to 128 kB: it accepts a 100 kB prefix and rejects 200 kB.

## Decision

`StreamProbeBudget.default` is 64 KiB and 1 s. When the open fails, an MP3 resync scans up to 1 MiB
(`kMP3ResyncScanBytes`) for 3 chained frame headers (`kMP3ResyncChain`) in `stream_decode.c`, and opens
there (#24). A lone sync word does not chain, so it is not taken. The scan starts from the bytes the
probe already read, and is skipped when the body starts with another format's signature (Ogg, FLAC,
RIFF, FORM, an MP4 `ftyp` box) or a text page (a leading `<` or `{`). A file that opens is read exactly as before.

## Alternatives rejected

- A larger default probe: every file pays the latency, for the few that need it.
- Give up on the junk: the file fails to play although it is plain MP3.
- Accept the first sync word: junk contains them.

## Consequences

- A hopeless file costs at most the probe plus 1 MiB (about 65 s of 128 kbps audio), a bounded few
  seconds of cellular data.
- Junk longer than 1 MiB is not played.
- Header-described formats (FLAC, ALAC, PCM WAV/AIFF) skip the probe altogether when the header gives the codec, rate, channels, format and (WAV aside) duration (#21); the decoder reports `skippedProbe`, and `forcesProbe: true` restores the probe. The budget above only governs the formats that still probe.

Links: [architecture](../architecture.md), [contributing](../contributing.md).
