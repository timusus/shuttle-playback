# ADR-0007: One network byte source

Status: Accepted
Date: 2026-10-08

## Context

Shuttle Podcasts reads episodes through `GrowingFileByteSource`. Shuttle2 had its own byte source,
`HTTPRangeByteSource`, which keeps a window of the file around the read position. Two network
sources would mean two recovery layers, two sets of retry rules and two sets of tests.

## Decision

Both apps use `GrowingFileByteSource`. The range-window source does not move into this package
(#23, closed). [ADR-0003](0003-growing-file-playback.md) rejected the window because its
compensation rules were the bug surface, and [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md)
keeps one recovery layer. What Shuttle2 needs that is generic moves into `GrowingFileByteSource`:

- #29: connection policy, meaning pinning and headers scoped across redirects.
- #30: cache keys that carry no token.
- #31: reopening when the path changes.
- #32: a cache budget per host.

## Alternatives rejected

- Move `HTTPRangeByteSource` here as a second source: it brings back the window and a second recovery
  layer, for a saving a music file does not need.
- Leave Shuttle2 on its own source: the two copies would diverge again ([ADR-0005](0005-shared-engine-repo.md)).

## Consequences

- Music is downloaded whole, which costs cellular data on a track that is only sampled. Whether that
  is acceptable is measured first in shuttle2#958.
- The single 1 GiB cache of ADR-0003 changes when #32 lands.
- The four items above are open work, not behaviour of the package today.

Links: [ADR-0003](0003-growing-file-playback.md), [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md),
[architecture](../architecture.md).
