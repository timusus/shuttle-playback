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

A new network path (Wi-Fi gone to cellular, the link back after none) ends the transaction in flight
at once instead of waiting out the 6 s. It is one more failure of this layer, not a second
recovery path: the retry budget decides on it from the same budget, and the retry resumes from the
frontier as after any drop. The signal is one `NWPathMonitor` shared by every source.

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
- The layer is one state machine with no clock, lock, file or network (`GrowingFileDownload`, its
  retry budget `GrowingFileDownload.Retry`), so each rule and each event sequence is tested with
  literal numbers, and the source, its adapter, is tested against a loopback server with fault knobs.

Links: [architecture](../architecture.md).
