---
paths:
  - "Sources/CStreamDecode/**"
---

# C decoder and seek modules

- The library is LGPL-2.1 and ships FFmpeg as a dynamic framework each closed-source app embeds (ADR-0001): use only FFmpeg's public
  libav* API, never GPL or nonfree code, and no external library beyond the system zlib.
- Seeks are sample-accurate: the demuxer is put a pre-roll before the target, and the decoder
  decodes and drops up to it. FLAC has no pre-roll (its seek finds a frame by its headers).
- One seek path per format (`seek_mp3.c`, `seek_aac.c`, `seek_flac.c`, `seek_ogg.c`) behind
  `seek.c`; add a format there rather than special-casing in `stream_decode.c`.
- A VBR MP3 seek further from a frame of known time than one seek's byte budget lands by Xing TOC or
  bitrate estimate and is the one inexact landing.
- Any decoder change shows as a golden diff: run the conformance suite
  (`swift test --filter PlaybackDecodeConformance`) and review it. A bug found and not fixed is
  pinned in `KnownIssues.swift`, not left red.
- FFmpeg fixes the pinned tag lacks go in `scripts/ffmpeg-patches/`, not in this C.
- Comments say why in one or two lines; no issue numbers.
