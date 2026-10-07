# ADR-0003: Growing-file playback

Status: Accepted
Date: 2026-10-06

## Context

The first streaming byte source used a window: bounded ranges, continuations, a redirect cache, a
footer side-fetch and throttling. Most of its changes were fixes, because every rule compensated for
the window. A host that wanted to read the same bytes it played, for analysis for example, needed a
separate tee. A producer slower than real time also made playback stutter.

## Decision

We download the resource once to a file on disk, as one ranged transaction, with no throttle and no
window. The decoder reads that file, and a read that reaches the end of the written bytes waits at the
frontier. A host that wants the same bytes reads the same file. A body that completes from byte 0 is
renamed into a cache of up to 1 GiB, evicted least recently played first. Partial files die when the
load ends and are swept at launch.

## Alternatives rejected

- Keep the windowed source: the compensation rules were the bug surface.
- Reuse partial files across sessions: a host can change the bytes behind a stable URL, so old
  bytes could differ from what the host now serves.
- Treat cached files as saved downloads: a cache is not something the user asked to keep.

## Consequences

- The window's footer *side-fetch* (a separate request for the tail) is gone. One footer rule remains
  on purpose: FFmpeg's MP3 open seeks to the last 128 bytes for an ID3v1 tag. While the host has set
  `isProbing` around `open()`, a read there past the frontier answers end of file at once, which FFmpeg
  takes as "no footer", so the head download is not cancelled for a look at the tail
  (`GrowingFileReadRule.footerBytes`). Outside the probe the same read waits, or the last frames would
  be cut.

- The whole resource is downloaded, on cellular and in Low Data Mode too, even if the listener
  stops early.
- A killed app restarts the download from scratch.
- A seek far past the frontier restarts the download at the target, into a new file.
- Background URLSession cannot be used, because it hands over the file only when it is finished.

Links: [architecture](../architecture.md).
