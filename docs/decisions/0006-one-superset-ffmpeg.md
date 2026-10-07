# ADR-0006: One superset FFmpeg for both apps

Status: Accepted
Date: 2026-10-08

## Context

The package began with a `podcast` build profile and a `music` stub for Shuttle2. An app links exactly
one FFmpeg, and Shuttle Podcasts runs its own C against libavformat as well as the player, so two
builds would mean two libraries to build, test and keep in step. The extra formats cost about 4% of
the library (about 110 KB per slice).

## Decision

We build one `Frameworks/FFmpeg.xcframework`, the music superset (MP3, AAC, ALAC, FLAC, Opus,
Vorbis, PCM WAV/AIFF, MP4/M4A, Ogg, Matroska), and both apps link it. Shuttle Podcasts carries the
extra formats. Build profiles and `FFmpeg-music.xcframework` are gone.

## Alternatives rejected

- Two profiles, two xcframeworks: a second binary to build and commit, for a size saving of 4%.
- Podcasts keeps a podcast-only FFmpeg: it cannot, since the apps share this package's decoder.

## Consequences

- Every format in the list has a fixture in the conformance corpus; an untested format is not supported.
- Adding a format to either app is a rebuild of the one framework, and the other app gets it too.
- The licence stays LGPL-2.1 only: no GPL flags, and no library beyond the system zlib.

Links: [ADR-0005](0005-shared-engine-repo.md) (amended by this one), [ADR-0001](0001-ffmpeg-for-demux-and-decode.md), [contributing](../contributing.md#ffmpeg).
