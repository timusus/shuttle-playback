# ADR-0007: One network byte source

Status: Accepted
Date: 2026-10-08

## Context

Shuttle Podcasts reads episodes through `GrowingFileByteSource`. Shuttle2 had its own byte source,
`HTTPRangeByteSource`, which keeps a window of the file around the read position. Two network
sources would mean two recovery layers, two sets of retry rules and two sets of tests.

## Decision

Both apps use `GrowingFileByteSource`. The range-window source does not move into this package.
[ADR-0003](0003-growing-file-playback.md) rejected the window because its
compensation rules were the bug surface, and [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md)
keeps one recovery layer. What Shuttle2 needed that is generic went into `GrowingFileByteSource`:

- A connection policy: trusted certificate fingerprints, and headers scoped to the origin across redirects.
- Cache keys that carry no token.
- Reopening when the network path changes.
- A cache budget per `GrowingFileStore`, so each owner has its own directory and ceiling.

## Alternatives rejected

- Move `HTTPRangeByteSource` here as a second source: it brings back the window and a second recovery
  layer, for a saving a music file does not need.
- Leave Shuttle2 on its own source: the two copies would diverge again ([ADR-0005](0005-shared-engine-repo.md)).

## Consequences

- Music is downloaded whole, which costs cellular data on a track that is only sampled. Whether that
  is acceptable is measured first in shuttle2#958.
- The single 1 GiB cache of ADR-0003 is now per store: the default store keeps 1 GiB, and an owner
  that needs a different ceiling makes its own.

Links: [ADR-0003](0003-growing-file-playback.md), [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md),
[architecture](../architecture.md).
