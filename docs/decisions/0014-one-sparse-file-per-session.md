# ADR-0014: One sparse file per source session

Status: Accepted, amends ADR-0003
Date: 2026-10-10

## Context

ADR-0003 gives every transaction its own file and promotes only a body that ran from byte 0 to the
end. A restart deletes the partial, so a podcast resumed from a saved position, an MP4 with `moov`
at the end (head, tail, then `mdat`) and a seek back behind the first transaction's base all
download again on every play and never reach the cache (issue #76).

## Decision

A `GrowingFileByteSource` writes every transaction of its session into one file, at each byte's
resource offset, and keeps a set of the ranges on disk. A restart retires the transaction and keeps
its bytes.

- A read inside a covered range is served from the file, with no transaction needed.
- A read in a hole waits or restarts by ADR-0004's rule (`gap / rate < responseLatency`), measured
  from the transaction's frontier to the read. A new transaction starts at the first hole at or
  after the read and asks only up to the next covered range (`Range: bytes=H-E`), as media3's
  `CacheDataSource` bounds a network read by the next cached `CacheSpan`. Nothing covered is
  fetched again.
- The file is promoted once `[0, total)` is covered, whichever transactions wrote it.
- Retry and resume stay per transaction (If-Range, strong ETag, same total). A new transaction
  whose total or strong ETag differs from the session's discards the whole file: the resource
  changed. A failure no retry fixes (a page, a full disk) deletes the file, as before.
- With no known total the file is bounded: once the reader is more than
  `GrowingFileDownload.unknownLengthWindowBytes` (64 MiB) past a range, the range is dropped and its
  blocks punched out of the file (`F_PUNCHHOLE`). 64 MiB keeps an hour at 128 kbps whole, so a
  typical episode from a host that sends no length still promotes, and it stays under the 200 MiB
  of headroom the store keeps free. A live stream (Icecast) or a transcode of unknown length stays
  within it and never promotes. A host that ignores ranges but gives a total is bounded by that
  total, like any file, and still promotes.

## Alternatives rejected

- Spans across sessions (media3's `SimpleCache` keeps them): a host can change the bytes behind a
  stable URL, and ADR-0003 refused stale partials for that reason. The session is the span's life.
- One file per transaction plus an index: the reader would have to pick a file per read, and
  promotion would have to stitch them.
- Fetching every hole before a cancel: a cost on the network the listener did not ask for.
  Promotion happens only when the reads themselves covered the file.

## Consequences

- `GrowingFileSnapshot.base`/`frontier` name the covered run the reader is in (or the current
  transaction's when the reader is in a hole), not one transaction's file; `fileURL` is the
  session's file.
- A late chunk of a retired transaction can land in the file; it is the same resource's bytes at
  their own offsets, and unrecorded.
- Seeking back more than the window into a stream of unknown length fetches again.

Links: [ADR-0003](0003-growing-file-playback.md), [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md),
[ADR-0013](0013-read-ahead-on-expensive-paths.md), issue #76, media3 `CacheDataSource`,
`SimpleCache`/`CacheSpan`, `ProgressiveMediaPeriod.seekToUs`.
