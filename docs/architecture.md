# Architecture

This page explains how the engine is put together and why it has the shape it has. It describes
three things: the package layout, the decode pipeline, and the growing-file byte source. It does not
tell you how to use them. For that, see [Integrating](integrating.md).

The decisions behind this design are in [decisions/](decisions/README.md).

## Package layout

The package has four products. A consumer links only the ones it imports.

```mermaid
flowchart TD
    subgraph consumer["Your app"]
        app["App code"]
    end

    subgraph products["Products"]
        PS["PlaybackStreaming"]
        PD["PlaybackDecode"]
        FF["FFmpeg"]
        TS["PlaybackStreamingTestSupport"]
    end

    subgraph targets["Internal targets"]
        CSD["CStreamDecode<br/>C shim over libavformat"]
        CFF["CFFmpeg<br/>binary target, static libs"]
    end

    app --> PS
    app --> PD
    app -. "own C code against libavformat" .-> FF
    app -. "tests only" .-> TS
    PS --> PD
    PD --> CSD
    CSD --> CFF
    FF --> CFF
```

- `PlaybackDecode` holds `FFmpegStreamDecoder`, the `StreamByteReader` protocol and `FileByteReader`.
  It links the C shim `CStreamDecode`, which links the static FFmpeg.
- `PlaybackStreaming` depends on `PlaybackDecode`. It adds the network byte source. A consumer that
  only decodes local files never links it.
- `FFmpeg` is the same static library exposed as its own product, for an app that has C code of its
  own against libavformat. An app links exactly one copy of FFmpeg, because two copies of the same
  static symbols are a duplicate-symbol link error.
- `CStreamDecode` is not a product. Its header is not public API.
- `PlaybackStreamingTestSupport` is a loopback HTTP server for tests. It depends on nothing.

The engine has no notion of podcasts, ads, queues, players or UI. Effects such as silence skipping
stay in the apps. See [ADR-0005](decisions/0005-shared-engine-repo.md).

## The decode pipeline

`FFmpegStreamDecoder` is a pull decoder. The caller asks for a chunk of PCM, and the decoder reads as
many bytes from its reader as it needs to produce it. Nothing is decoded ahead of the caller.

```mermaid
flowchart LR
    R["StreamByteReader<br/>file, download, anything"]
    B["ReaderBox<br/>Swift to C bridge"]
    A["Custom AVIOContext<br/>read, seek, size callbacks<br/>ID3v2 offset hidden"]
    D["libavformat demuxer<br/>mp3, aac, mov, ogg"]
    C["libavcodec decoder<br/>one thread"]
    S["libswresample<br/>sample format only"]
    P["pending buffer"]
    O["nextChunk<br/>4096 frames of interleaved Float32"]

    R --> B --> A --> D -->|packets| C -->|frames| S --> P --> O
```

Points worth knowing:

- **The reader is blocking.** `read` may wait for bytes to arrive. The decoder calls it on its own
  thread. `cancel()` and `interrupt()` are the only calls made from another thread.
- **The seek callback is not optional.** With a read callback alone, FFmpeg treats the source as
  unseekable and the MP4 demuxer reads the whole `mdat` to reach a `moov` atom at the end of the file.
  The AVIO context has a size callback too (`AVSEEK_SIZE`), so a reader that knows its length lets
  FFmpeg jump to the end with one seek. A reader with no length answers "unknown", never a guess.
- **Leading ID3v2 tags are stepped over before FFmpeg sees them.** An MP3 with embedded cover art can
  carry megabytes of tag, and FFmpeg's MP3 demuxer reads all of it. The decoder reads the tag
  headers itself, seeks past them, and gives FFmpeg an offset-0 that is the first MPEG frame. The
  AVIO callbacks translate offsets, so the reader always sees real file offsets.
- **Output is at the source's own rate and channel count.** The resampler is configured with the same
  rate and channel layout in and out. It only interleaves and converts whatever sample format the
  codec produced to Float32. Nothing is resampled.
- **A chunk is `framesPerChunk` = 4096 frames.** About 93 ms at 44.1 kHz. Decoded audio that does not
  fit the chunk stays in the pending buffer for the next call.

### Open and probe

```mermaid
sequenceDiagram
    participant Caller
    participant Dec as FFmpegStreamDecoder
    participant C as CStreamDecode
    participant FF as libavformat
    participant R as StreamByteReader

    Caller->>Dec: open()
    Dec->>C: stream_decoder_open_with
    C->>R: read 10 bytes (ID3v2 header?)
    R-->>C: bytes
    Note over C,R: if a tag: seek past it, repeat for stacked tags
    C->>FF: avformat_open_input, probesize 64 KiB
    FF->>R: reads and seeks through AVIO
    C->>FF: avformat_find_stream_info, 1 s analysis
    C->>FF: av_find_best_stream (audio)
    Note over C,FF: MP3 only: read the first packet. If junk precedes the first frame, reopen at the frame.
    C->>C: open codec, build resampler
    C-->>Dec: StreamAudioInfo
    Dec-->>Caller: StreamAudioFormat
```

The probe budget is `StreamProbeBudget`. The default is 64 KiB and 1 s. FFmpeg's own defaults are a
5 MB probe and 5 s of analysis, which is too much when the bytes are cellular data. A caller whose
files need more analysis passes a larger budget to `FFmpegStreamDecoder.init`.

`open()` always throws on failure. It never returns a decoder that silently produces nothing.

### Seek

`seek(toSeconds:)` returns where the stream actually landed. The return value is the answer, not the
argument.

```mermaid
flowchart TD
    S["seek to t"] --> CL["clear interrupt on reader and decoder"]
    CL --> RS{"resumable and t equals<br/>the frame the next read returns?"}
    RS -- yes --> RE["resume: put the demuxer back on the last packet<br/>codec state kept, no flush"]
    RE -->|found| DONE
    RE -->|not found| TR
    RS -- no --> TR["avformat_seek_file backward<br/>with a 64 KiB read budget"]
    TR -->|landed inside the budget| FL["flush codec, reset resampler"]
    TR -->|budget spent or seek failed| EST{"length and duration known?"}
    EST -- yes --> BYTE["byte-estimate seek<br/>t over duration times media bytes"]
    EST -- no --> WALK["unbudgeted seek: pay for the walk"]
    BYTE --> FL2["flush codec, reset resampler"]
    WALK --> FL2
    FL --> PUMP["decode to the first frame"]
    FL2 --> PUMP
    PUMP --> LAND["landed time = first frame pts<br/>byte estimate: the estimate itself"]
    LAND --> DONE["return landed time"]
```

- **Landing is at or before the request, on a frame boundary.** The seek is backward-leaning, so
  nothing between the request and the landing is skipped unheard. After a seek the decoder decodes
  eagerly to the first frame and reports that frame's timestamp. The result is exact to a codec
  frame (1152 samples for MP3, 1024 for AAC), not to a single sample. A caller that sets its position
  to the requested time instead of the returned one drifts from the audio.
- **The budget exists because of MP3 without a table of contents.** For those files FFmpeg's generic
  seek decodes forward from the start until timestamps reach the target. Measured on a fixture, one
  seek to 25 minutes read 12 MB. Once a seek has read 64 KiB, the next read is refused, the walk
  aborts, and the decoder places the seek by byte ratio instead. This is exact for constant bitrate
  and close for the rest. The estimate is reported as the landed time.
- **A source with no length and no container duration has nothing to estimate from.** The walk is then
  the only seek there is, so it is allowed to run.
- **FFmpeg's fast-seek flag is set**, so an MP3 uses its Xing table of contents when it has one.
- **`mediaFramesRead` is media time.** After a seek it is set from the landed time and advances by the
  frames handed out.

### Interrupt, cancel and errors

Two calls can be made from another thread, and they mean different things.

| Call | Effect |
|---|---|
| `cancel()` | Ends the stream. The blocked read throws `cancelled`; `nextChunk()` returns nil with `endReason == .cancelled`. Final. |
| `interrupt()` | Ends the current blocked call only. The decoder stays open. The next `seek(toSeconds:)` clears it. |

`interrupt()` exists because a player's pull loop can be blocked in a read on a dead connection while a
seek waits behind it on the same queue. Cancelling would answer the seek by destroying the stream.

```mermaid
stateDiagram-v2
    [*] --> running: open
    running --> eof: reader returns 0
    running --> failure: IO or decoder error
    running --> cancelled: cancel
    running --> interrupted: interrupt
    interrupted --> running: seek
    eof --> running: seek
    failure --> running: seek succeeds
    cancelled --> [*]
    eof --> [*]
```

`nextChunk()` returning nil is not by itself the end of the stream. `endReason` says which of
`eof`, `failure`, `cancelled` or `interrupted` it was, and a caller must treat them differently.
Reporting a network failure as the end of the stream is the worst mistake available here.

An interrupted decode can resume without audible damage. If the next seek is to exactly the frame the
interrupted read would have returned, the decoder does not flush the codec. It puts the demuxer back
on the last packet it handed to the codec, reads that packet again and drops it, and carries on. MP3
and MP4 resume bit-exactly. Where the demuxer has no per-packet index (Ogg), the decoder falls back to
an ordinary seek.

Errors reach the caller as `StreamDecoderError`: `failed(status:)` for FFmpeg refusing the bytes,
`cancelled`, `interrupted` and `invalidState`. A reader error that is not a cancel or an interrupt
becomes an IO failure. A read that returns zero bytes means end of stream and is passed to FFmpeg as
EOF, never as zero, because FFmpeg treats a zero-length read as "try again" and spins forever.

## The growing-file byte source

`GrowingFileByteSource` is a `StreamByteReader` over an HTTP(S) URL. It plays a file while it
downloads. The download is one ranged request, written into a file on disk. The decoder reads that
file, and a read that reaches the end of the written bytes waits for more.

```mermaid
flowchart LR
    NET["HTTP host"]
    URLS["URLSession<br/>delegate queue"]
    FILE[("Growing file<br/>holds base to frontier")]
    SRC["GrowingFileByteSource<br/>one lock and condition"]
    DEC["FFmpegStreamDecoder<br/>decoder thread"]
    SNAP["GrowingFileSnapshot"]
    LIS["GrowingFileListener<br/>and onEvent"]
    STORE["GrowingFileStore<br/>.partial and .audio files"]

    NET -->|body chunks| URLS
    URLS -->|pwrite, advance frontier| FILE
    URLS --> SRC
    DEC -->|read, seek| SRC
    SRC -->|pread| FILE
    SRC -->|makePartial, promote| STORE
    STORE --- FILE
    SRC --> SNAP
    SNAP --> LIS
    SRC -->|events| LIS
```

### Terms

- **Transaction.** One `GET` with `Range: bytes=<base>-` and the caller's auth headers. Each
  transaction writes one file. A restart is a new transaction, a new file, a new `base` and a new
  generation number.
- **Base.** The resource offset of the file's first byte.
- **Frontier.** One past the last byte on disk and readable. The file holds `[base, frontier)`.
- **Generation.** Counts transactions from 1. A resume after a drop keeps its generation. A restart
  or a host that ignores the range changes it.

### The read rule

Every read at a position is decided by `GrowingFileReadRule`. The decision is made at the first read at
a position, never at the seek. The MP3 footer probe seeks to the last 128 bytes, reads them and
seeks back. Deciding at the seek would cancel the head download for a read that never needed the
network.

```mermaid
flowchart TD
    A["read at position p"] --> B{"base <= p < frontier"}
    B -- yes --> SERVE["serve from the file"]
    B -- no --> C{"p >= total length"}
    C -- yes --> EOS["end of stream, return 0"]
    C -- no --> D{"p < base"}
    D -- yes --> RES["restart at p, new file"]
    D -- no --> E{"download complete"}
    E -- yes --> EOS
    E -- no --> F{"probing and p in the last 128 bytes"}
    F -- yes --> EOS
    F -- no --> G{"p == frontier, or host ignored Range"}
    G -- yes --> WAIT["wait for bytes"]
    G -- no --> H{"gap divided by download rate < 3 s"}
    H -- yes --> WAIT
    H -- "no, or no rate sample yet" --> RES
```

The footer rule applies only while `isProbing` is set around the decoder's `open()`. Outside the
probe, the same read waits, or the last frames would be cut.

A parked read looks again every second (`recheckSeconds`). The measured download rate decays while no
bytes arrive, and nothing else wakes the read to notice.

A seek far ahead of the frontier is therefore a restart: the old transaction is cancelled and a new
one opens at the target, into a new file. A seek behind `base` is a restart too, since the file does not hold it.

### Recovery and retry

All network recovery lives in this class and nowhere else. `DownloadRetry` is the policy. It is a pure
value type with no clock or lock, so every branch is tested with literal numbers.

Failures come in two kinds:

- **Answered.** The host replied: a refused status, a body that ended short, a `200` where a `206`
  was needed. Each spends one of 3 attempts.
- **Unanswered.** Nothing came back: no network, a refused connection, no response in time, a body
  that went silent. These spend no attempt. They are retried while the next attempt can start inside
  the 30 s link window, measured from when the link went quiet. Only a response resets the window.

Backoff starts at 0.1 s, doubles on every failure in a row, and stops at 2 s.

```mermaid
stateDiagram-v2
    [*] --> Requesting: transaction opens
    Requesting --> Streaming: response accepted, link up
    Requesting --> Backoff: no response in 20 s (8 s on a retry)
    Requesting --> Backoff: refused status or page
    Streaming --> Backoff: connection dropped
    Streaming --> Backoff: body silent for 6 s
    Streaming --> Backoff: body ended short
    Streaming --> Complete: body whole
    Backoff --> Resume: file holds the decoder position
    Backoff --> Restart: it does not, or host ignores ranges
    Backoff --> Failed: attempts spent, or link window over
    Resume --> Streaming: 206 from the frontier, same total
    Resume --> Restart: 200, 416, other range, or changed total
    Resume --> Backoff: no response, or refused
    Restart --> Requesting: new file at the decoder position
    Complete --> [*]
    Failed --> [*]: read throws transport
```

- **Header wait.** A transaction's first request waits 20 s for its response, to allow a cold origin
  or a long redirect chain. A retry goes straight to the end of the redirect chain it remembers and
  waits 8 s. Neither waits past the end of the link window. The session's own timeout is a backstop.
- **Idle body.** Once a response has arrived, a body that goes 6 s without a byte is ended by the source
  and handled like a drop. With URLSession's default, a silent link held the read for 60 s.
- **Resume.** A retry whose file holds the decoder's position asks for `Range: bytes=<frontier>-`,
  with `If-Range` when the host gave a strong ETag. The bytes append to the same file under the same
  generation, so nothing already on disk is fetched again. The resume is accepted only if the host
  answers `206` starting at the frontier with the same total length.
- **Restart.** A retry whose file does not hold the position, or a refused resume, opens a new transaction at the
  decoder's position into a new file.
- **A refused or unanswered request to the remembered chain end** forgets that end. A signed redirect may
  have expired, so the next request walks the chain from the original URL once.
- **A non-audio response is a failure.** An HTML `Content-Type` is refused. When the type is not
  audio, video or Ogg, the first 12 bytes of the body are checked for a media signature instead, so
  a login page is never decoded.
- **Past the retry budget the read throws** `StreamByteReaderError.transport`. Bytes already
  downloaded are still read first. The error stays until the next seek, which opens a fresh transaction
  with a fresh budget.
- **Progress resets the budget.** The frontier passing the decoder's position, or a restart nobody's
  failure caused, resets `DownloadRetry`.

If the host ignores `Range` and answers `200`, the source marks the range as ignored. It re-declares the
file as starting at byte 0 under a new generation, and every later read ahead of the frontier waits
instead of restarting, because a restart would only be answered from byte 0 again.

### Files and the store

`GrowingFileStore` owns the directory, by default `Caches/growing`. The file name is the state.

| File | Meaning |
|---|---|
| `<uuid>.partial` | One per transaction. Deleted on restart, on `cancel()`, and swept at launch. Never reused by a later session. |
| `<sha256 of URL>.audio` | A transaction that completed from byte 0, renamed into place. Kept up to a 1 GiB budget, least recently played first out. |

`completedFile(for:)` returns the cached file for a URL, to be played with `FileByteReader`. Before a
transaction starts, the store evicts to make room if the volume would be left with less than 200 MB.

Partial files are never reused across sessions because hosts can re-stitch ads behind a stable URL,
and old bytes would replay a different ad load. See
[ADR-0003](decisions/0003-growing-file-playback.md).

### Snapshot and events

The decoder is the only thing that reads the byte source directly. Everyone else reads
`GrowingFileSnapshot`, a thread-safe copy of the state: `base`, `frontier`, `totalLength`,
`isComplete`, `fileURL`, `transactionGeneration`, `seekGeneration` and `downloadBytesPerSecond`
(averaged over 2 s).

A host can watch the source in two ways:

- `onEvent`, a closure passed to the initialiser, receives `GrowingFileEvent`: `transaction` when a
  response is accepted, `download` at most once a second while bytes arrive and once at
  completion, and `seekLanded` when a seek was answered from the file already there.
- A `GrowingFileListener` receives the same events with a snapshot taken just after. It is also told
  when playback starts and when the player will seek, so a transaction opened by a seek can be
  paired with its target. It reads the file back through `fileURL`, so it can never see a byte the
  decoder did not have, and it never makes a second fetch.

`willSeek(generation:)` is how a player tags a seek. The next read that opens a transaction carries
that generation, and a read answered from the existing file reports the seek as landed instead.

## Threading

| Thread | Does |
|---|---|
| Decoder thread | `open`, `seek`, `nextChunk`, and the byte source's `read` and `seek`. Blocking. |
| URLSession delegate queue (serial) | Writes body bytes, advances the frontier, runs the retry policy. |
| Any thread | `cancel()`, `interrupt()`, `snapshot`. |

The decoder thread and the delegate queue meet under one lock and condition inside the byte source.
File I/O runs outside the lock. `GrowingFileByteSource.cancel()` must always be called, because a
running task retains its delegate, which is the source.
