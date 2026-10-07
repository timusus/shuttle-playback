# ADR-0003: Growing-file playback

Status: Accepted
Date: 2026-10-06

Originally recorded in Shuttle Podcasts as ADR-0004.

## Context

The first streaming byte source used a window: bounded ranges, continuations, a redirect cache, a
footer side-fetch and throttling. It was 1,755 lines and 14 of its 23 commits were fixes, because every
rule compensated for the window. A host application that wanted the same bytes for something else,
such as an analysis pass, needed a separate tee. A producer slower than real time also made playback
stutter.

## Decision

We download the resource once to a file on disk, as one ranged transaction, with no throttle and no
window. The decoder reads that file, and a read that reaches the end of the written bytes waits at the
frontier. A host that wants the same bytes reads the same file. A body that completes from byte 0 is
renamed into a cache of up to 1 GiB, evicted least recently played first. Partial files die when the
load ends and are swept at launch.

## Alternatives rejected

- Keep the windowed source: the compensation rules were the bug surface.
- Reuse partial files across sessions: hosts can re-stitch ads behind a stable URL, so old bytes
  could replay a different ad load.
- Treat cached files as saved downloads: a cache is not something the user asked to keep.

## Consequences

- The whole resource is downloaded, on cellular and in Low Data Mode too, even if the listener
  stops early.
- A killed app restarts the download from scratch.
- A seek far past the frontier restarts the download at the target, into a new file.
- Background URLSession cannot be used, because it hands over the file only when it is finished.

Links: [architecture](../architecture.md#the-growing-file-byte-source).
