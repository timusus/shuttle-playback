# ADR-0012: One seek strategy per format

Status: Accepted
Date: 2026-10-08

## Context

Every format's seek rules lived inline in `stream_decode.c`: MP3 anchors and CBR frame placement,
FLAC's header search, Ogg's page back-off and AAC's codec reopen were all mixed into one placement
function and one landing function, joined by `if` chains on the format. A fix for one format had to
be read against all of them, and the budget and fallback ladder was hard to see among the rules.

## Decision

Each format's seek rules are an internal module in `Sources/CStreamDecode` behind one interface,
`SeekFormat` in `seek.h`, a table of optional hooks (NULL is the generic answer): `place`,
`has_estimate_anchor` and `estimate_anchor` (where to put the demuxer, and the fallback anchor),
`preroll_samples`, `reopens_codec`, `can_resume`, `first_packet` (the open has read the first audio
packet), `reset` (a seek flushes; forget what the last one measured), `landed` (the demuxer is placed,
before the landing decode), `packet_fed` (a packet is about to enter the codec) and `preroll_short`
(the pre-roll fell short, so place again further back). Each format keeps its state in its own struct
in `StreamDecoder`. `mp3_landed` does its own demuxer re-seek, to the frame it landed on with that
frame's true time, so a module's `landed` may move the demuxer again. The AAC open-time time-zero code
(`sd_aac_open`, the priming and the decoder trim) also lives in `seek_aac.c`, with the duration
correction (`sd_aac_audio_duration`), so no core code reads AAC state. The modules are
`seek_mp3.c`, `seek_aac.c`, `seek_flac.c`, `seek_ogg.c` and `seek_generic.c`; the open picks one by
demuxer and codec. `seek.c` owns the 64 KiB budget, the fallback ladder (format placement, then the
format's estimate anchor or the byte estimate, then the paid walk) and the landing, in one place.
This follows media3's `SeekMap` family (`XingSeeker`, `VbriSeeker`, `ConstantBitrateSeeker`,
`FlacBinarySearchSeeker`), where each extractor supplies a seeker and the player owns the rest.

## Alternatives rejected

- Keep one file: every format's rules stay entangled, and the ladder stays hard to find.
- A module per format that also owns its fallbacks: the budget and the ladder would be duplicated
  five times and drift apart.

## Consequences

- A new format's seek is a new module and a line in `sd_seek_format_for`; the ladder is untouched.
- Cross-file helpers in the decode pump (`sd_pump`, `sd_init_swr`, ...) are no longer `static`. They
  are declared in the private `decoder.h`, and the public headers are unchanged.
- The split was a pure refactor: every conformance golden is unchanged.

Links: [ADR-0009](0009-seeks-are-sample-accurate.md), [architecture](../architecture.md), issue #40.
