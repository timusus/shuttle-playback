# ADR-0013: Read-ahead on expensive paths

Status: Accepted, amends ADR-0003
Date: 2026-10-08

## Context

ADR-0003 downloads every file whole, and ADR-0007 left its cellular cost to be measured
(shuttle2#958). The spike fetched 145 MB on cellular against 60 MB heard: all of the difference was
bytes nobody played, mostly of tracks skipped or sampled.

## Decision

A host may give a source a read-ahead in bytes (`GrowingFileReadAhead(bytes:)`). While the shared
path is expensive or constrained, the source cancels its request once the frontier is that far ahead
of the decoder's read position, and resumes from the frontier through the ADR-0004 resume when the
reader comes within half of it. A pause is not a failure: it spends no retry and starts no idle or
link timer. The file, its base and promotion to the cache are unchanged. A host that ignores ranges
is never capped. Nil (the default) and cheap paths download whole.

- **Cancel, not stop reading.** URLSession has no backpressure (a `suspend()`ed task stays active on
  the wire), so we cancel where media3's `ProgressiveMediaPeriod` blocks its loader.
- **Hysteresis**, as in media3's `DefaultLoadControl`: pause at the read-ahead, resume at half of it.
- **The resume is a fresh attempt**: the retry's short response wait, and a link window that starts
  when it goes out, not at the last byte before the pause. A paused source's seek-wait rule keeps
  the download rate measured before the pause until the resumed request delivers. The join starts
  64 KiB back and is overlap-checked (ADR-0016).
- **Cost, not change.** The path's `isExpensive` and `isConstrained` set the cap; a change in cost
  alone reopens nothing, and a move to a cheap path lifts a pause at once.
- **Only a host that answered `206` is capped**: a `200`, even to `bytes=0-`, would answer a resume
  from byte 0 again.

## Alternatives rejected

- A throttle paced by `suspend()`: the task keeps the connection busy, and it is the compensation
  surface ADR-0003 removed.
- A window of bounded ranges: the source ADR-0003 replaced.
- A cap on every path: a whole file on Wi-Fi is what the cache and an uninterrupted play want.

## Consequences

- One request per pause, from the frontier; what was on the wire at each cancel comes twice.
- A preopened track costs about the probe and one read-ahead; when to preopen is the app's call
  (Shuttle2's `PreopenLead`).
- The read-ahead is in bytes: the host converts from seconds with the stream's bitrate. Shuttle2
  uses 60 s; Podcasts passes none.

Links: [ADR-0003](0003-growing-file-playback.md), [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md),
[ADR-0007](0007-one-network-byte-source.md), issue #67, shuttle2#958.
