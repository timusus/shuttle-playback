# ADR-0016: A 64 KiB overlap check at every join

Status: Accepted, amends ADR-0004 and ADR-0014
Date: 2026-10-10

## Context

A transaction that continues bytes already on disk (a resume from the frontier, ADR-0004; a restart
into a hole of the session file, ADR-0014) trusts the same range, the same total and a strong ETag.
Dynamic ad insertion can keep all three and change the bytes, and the join then plays the end of one
stitched version after the start of another (issue #81).

Measured from macOS on 2026-10-10 (curl, issue #81): Megaphone, Art19 and Simplecast send no strong
ETag; only Acast does. The version sticks to a client identity (user agent; IP untested), so the risk
is that identity changing between two requests, and then only the total length differs. Whether two
ad versions can share a length is unmeasured. Same-identity requests minutes apart are byte-identical. media3 does not guard this:
`ProgressiveMediaPeriod` sends `If-Range` only for a strong ETag and only within one `load()`;
`DefaultHttpDataSource` skips to the position on a `200` to a range request (a silent join);
`CacheDataSource` keys spans on URI and length, with no ETag.

## Decision

Every join is checked against the bytes on disk. A request that continues covered bytes starts up to
`GrowingFileDownload.overlapBytes` (64 KiB) *before* the join, clamped to the covered run it follows,
and its first bytes are compared with the file instead of being written. A mismatch means the
resource changed: the file is discarded and the transaction restarts at the reader's position, the
existing `resource_changed` path. Shared with the Android app, so both apps accept and reject the
same joins.

- **Joins.** A resume (retry, or the end of an ADR-0013 pause) overlaps the frontier backwards. A
  restart into a hole of the session file overlaps the end of the covered range before the hole, and
  when the request is bounded (`Range: bytes=H-E`) it also runs 64 KiB into the covered range after
  the hole, so the far seam is checked too. Where nothing precedes the join (a hole at byte 0, or
  nothing covered within reach) there is nothing to compare, and the request is as before.
- **`If-Range` stays** for a strong ETag, and a `200` to it is *changed*: the resume restarts and
  discards the file (the existing refused-resume path), where media3 would skip to the position and
  join. The overlap is the only check for a host with no validator.
- **Total length stays** as an extra check (a differing total on a response discards the file). It is
  no longer the only guard.
- **A missing validator alone never discards the session file.** The overlap decides.
- **Short bodies (implementer's call, not a decision).** A body that ends or drops inside the overlap
  is an ordinary failure of the transaction (retry budget as before); only complete overlap bytes
  that differ are *changed*.

## Alternatives rejected

- ETag and `Last-Modified` only: three of the four measured hosts send no strong validator.
- Total length only: ad versions often differ in length, but whether they always do is unmeasured, and a host that
  sends no length gives nothing.
- Discard on a missing validator: a rebuilt cache of a perfectly good file at every resume.
- Skip-and-join on a `200` (media3's `DefaultHttpDataSource`): the join this ADR exists to prevent.
- A hash of the whole file at each resume: refetches what the resume exists to avoid.

## Consequences

- Each join costs up to 64 KiB (128 KiB for a bounded restart) of refetch. The probe budget, ADR-0011,
  is the same size.
- ADR-0004's rejection of a 64 KiB overlap is reversed: the session file's join (ADR-0014) needs the
  check anyway.
- Two cases only the check can see: a host whose identity changed between requests (a resume from
  cellular after Wi-Fi), and a hole filled in a later transaction.
- Open (issue #81): whether an IP change alone flips the version; how long a version persists.
- A stream of unknown length (ADR-0017) has no bytes to compare at its restart: it is not a join.

## Implementation

`GrowingFileDownload`: `Request.from` is the overlap start and `Request.end` the extended bound;
`Transaction` records the overlap range to verify, and checks that a `206` starts at it (implementer's
choice, not a decision). The adapter compares
the first chunks with the file (the machine has no file) and reports `overlapChecked(matches:)`;
chunks inside the overlap are not recorded. Tests:

- Machine (`Harness`, `GrowingFileDownloadRetryTests`, `GrowingFileDownloadSessionFileTests`): a resume
  asks `from = frontier - 65536`; a hole restart asks both seams; a mismatch yields `retire(discardFile:
  true)` and a restart at the reader's position; a match records only the new range; a `200` to
  `If-Range` discards; a response with no validator and a matching overlap keeps the file.
- Loopback (`GrowingFileByteSourceTests+Recovery`, `+SessionFile`): `LoopbackMediaServer` serving a
  different body after the Nth request with the same total and no ETag; a dropped body resumes onto
  changed bytes and the played bytes after the join equal the new version from the join on.

Links: [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md), [ADR-0014](0014-one-sparse-file-per-session.md),
[ADR-0011](0011-probe-budget-and-junk-resync.md), issue #81, media3 `ProgressiveMediaPeriod`,
`DefaultHttpDataSource`, `CacheDataSource`.
