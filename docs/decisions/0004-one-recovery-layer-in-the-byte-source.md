# ADR-0004: One recovery layer, in the byte source

Status: Accepted
Date: 2026-10-07

Originally recorded in Shuttle Podcasts as ADR-0005.

## Context

A dropped or silent connection was being recovered twice. The byte source retried, and the player's
controller re-seeked when the download frontier stayed flat. The two raced for the same link. The
first growing-file design also restarted every retry, which fetched the unplayed remainder again.

## Decision

Recovery lives only in `GrowingFileByteSource`. A transaction's first request waits 20 s for its
response. Once the response has arrived, a body silent for 6 s ends like a drop. Each retry resumes
from the download frontier when the host answers with the same range and total, and otherwise
restarts at the decoder's position. A 30 s link window covers connection attempts that nothing
answers. The controller above only detects: it notices starvation and resumes playing.

## Alternatives rejected

- Keep a second rule in the controller: it raced the source's retry.
- Restart on every drop: refetches the unplayed remainder.
- Compare a 64 KiB overlap of the old and new bytes: more code than the restart path it would
  replace.

## Consequences

- A resume trusts the same range, the same total and a strong ETag. Dynamic ad insertion can keep all
  three and change the bytes. This was accepted as rarer than the cost of refetching.
- Past the retry budget the read throws a transport error at the frontier. A player should play out
  what it has decoded and then show an error at that position, not the end of the stream.
- The policy is a value type with no clock, lock or network (`DownloadRetry`), so each rule is tested
  with literal numbers, and the source is tested against a loopback server with fault knobs.

## Outcome

Measured on a device when this was adopted, with the player in a host app:

- A dead link (40 s drop) errored at about 30 s with the position held where it stopped.
- A 10 s drop resumed from the frontier with no new transaction.
- A 10 s hang made exactly one request at the frontier and no error.
- A 25 s hang made three requests from one frontier, all answered when the hang ended, and no error.

Links: [architecture](../architecture.md#recovery-and-retry).
