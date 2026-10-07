# ADR-0004: One recovery layer, in the byte source

Status: Accepted
Date: 2026-10-07

## Context

A dropped or silent connection was being recovered twice. The byte source retried, and the host's
playback code re-seeked when the download frontier stayed flat. The two raced for the same link. The
first growing-file design also restarted every retry, which fetched the unplayed remainder again.

## Decision

Recovery lives only in `GrowingFileByteSource`. A transaction's first request waits 20 s for its
response. Once the response has arrived, a body silent for 6 s ends like a drop. Each retry resumes
from the download frontier when the host answers with the same range and total, and otherwise
restarts at the decoder's position. A 30 s link window covers connection attempts that nothing
answers. The host only detects: it notices starvation and resumes playing.

## Alternatives rejected

- Keep a second recovery rule in the host: it raced the source's retry.
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

`PlaybackStreamingTests` runs the source against `LoopbackMediaServer` with its fault knobs and a
manual clock. The tests show that a dropped connection resumes from the frontier without a new
transaction, that a silent body is ended by the idle timeout and retried, that a host which ignores
`Range` is waited on rather than restarted, and that a link that stays dead ends in a transport error
once the 30 s window is spent.

Links: [architecture](../architecture.md#recovery-and-retry).
