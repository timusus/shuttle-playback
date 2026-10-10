# ADR-0017: Live streams of unknown length

Status: Accepted, amends ADR-0004 and ADR-0014
Date: 2026-10-10

## Context

An Icecast station or an open transcode has no end and no length. The engine treats a resource with
no length as a file that has not finished: a drop resumes with `If-Range` from the frontier, a seek
restarts at an offset, and the session file keeps a 64 MiB window (ADR-0014). Resuming a live stream
is wrong (the server answers `200` from "now", and ADR-0004's resume then discards the file and
asks for the reader's old offset), a seek means nothing, and the player gets no way to know any of it
(issue #80).

media3 decides this in the extractor, not the transport: a stream with no length and no duration is
live, and its `SeekMap` is unseekable (`ProgressiveMediaPeriod` with `Extractor`s that return
`SeekMap.Unseekable`; `Mp3Extractor`'s `ConstantBitrateSeeker` needs a length). A drop is a new
`DataSpec` at position 0 of the new body, never a resume. `IcyDataSource` reads ICY titles.

## Decision

**Detection.** A stream is live when both are unknown: the byte source's `totalLength` (no
`Content-Length`, no `Content-Range` total) and the container's duration (`StreamInfo.duration == nil`
after the probe). Neither alone: a chunked file ends and gets a length from a `416` or its end (ADR-0014
still promotes it), and a container can lack a duration while the file has a length. The decoder
makes the call after the probe and exposes `FFmpegStreamDecoder.isLive`; a `StreamByteReader` that can
restart a live body learns it through one optional requirement, `streamIsLive()`, set once.

**No seeking.** A live decoder's `seek(to:)` throws `unseekable`; the host disables its scrubber from
`isLive`. The byte source's `seek` already throws `unseekable` for a position outside the window.

**Recovery is a restart, not a resume.** A live transaction that drops, goes silent (ADR-0004's 6 s)
or follows a path change opens a new request with no `Range` and no `If-Range`, spends the same retry
budget, and keeps ADR-0004's single recovery layer. The new body's first byte takes the offset after
the last byte received (`base = frontier`), so the reader's position stays monotonic and nothing is
discarded. The decoder resyncs on the frame boundary (ADR-0011's junk resync); a format that cannot
resync mid-stream (Ogg without its headers) fails at the join and the host sees a decode error.
There is no overlap check (ADR-0016): live bytes at the join do not exist twice.

**Bounded session file.** Live bytes are never promoted to the cache. The window of ADR-0014 applies
but is lowered for live to `GrowingFileDownload.liveWindowBytes` (4 MiB, about 4 minutes of 128 kbps), since there
is nothing to seek back to; blocks behind it are punched out as before. Past the retry budget the
read throws a transport error at the frontier, as for any stream (ADR-0004).

**Not in scope: ICY metadata.** "Now playing" titles (`Icy-MetaData: 1`, media3 `IcyDataSource`) are
a non-goal by owner decision (issue #80). The request stays without the header, so the body has no
inline metadata blocks to strip; a later ADR can add it.

## Alternatives rejected

- Live = no `Content-Length` alone: a podcast host that streams a transcode with chunked encoding
  is not live and should seek and promote.
- Live decided in the byte source by a content type or `icy-*` headers: Icecast is one of several
  servers; the media3 rule (length and duration) covers the rest.
- Resume live streams with `Range`: servers ignore it and answer `200` from the live edge, and the
  existing refused-resume path would throw the window away on every drop.
- A second recovery path for live in the host: ADR-0004.

## Consequences

- A drop on a live stream loses the audio between the drop and the restart, which is unavoidable.
- `isLive` is known only after the probe; the byte source runs the file rules until then, which is
  harmless (nothing has been seeked or dropped within the probe budget).
- A server that sends a length for a live stream (some transcodes) is a file to us.

## Implementation

`PlaybackDecode`: `isLive` on the decoder, `seek(to:)` throws when live; `StreamByteReader` gains
`streamIsLive()` with a default no-op. `GrowingFileDownload`: a `live` flag on the session; `retryCurrent`
restarts at `frontier` without `Range`/`If-Range` when live (a branch beside `resumable`); the
window is `liveWindowBytes` when live; no promotion. Tests:

- Machine (`Harness`, `GrowingFileDownloadRetryTests`, `GrowingFileDownloadSessionFileTests`): a live
  drop yields a request with no range and no `ifRange`, `base = frontier`, no `discardFile`; the retry
  budget is shared; the window is the live one and nothing promotes.
- Loopback (`GrowingFileByteSourceTests+Recovery`): `LoopbackMediaServer` with `omitsContentLength`
  and an endless body that `closesAfterBodyBytes`; the source restarts, the position is monotonic, and
  the post-drop bytes read are the new body's.
- Decoder (`PlaybackDecodeTests`): an endless ADTS/MP3 source with no length reports `isLive`, a
  seek throws `unseekable`, and a file with a length does not report it.

Links: [ADR-0004](0004-one-recovery-layer-in-the-byte-source.md), [ADR-0014](0014-one-sparse-file-per-session.md),
[ADR-0011](0011-probe-budget-and-junk-resync.md), [ADR-0016](0016-overlap-check-at-every-join.md), issue #80,
media3 `ProgressiveMediaPeriod`, `SeekMap.Unseekable`, `IcyDataSource`.
