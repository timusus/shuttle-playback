/*
 * stream_decode.h — the PLAYBACK decoder, for iOS.
 *
 * It takes a *byte reader* — a file, or an HTTP range transaction that may block for a second —
 * and hands back the source's OWN rate and channel count, interleaved float32, a chunk at a time,
 * seekably, cancellably. That is what a player schedules; resampling it would be a second, lossy,
 * pointless conversion. Position is media time: after a seek it comes from the decoded frames'
 * timestamps, not from the request.
 *
 * THE SEEK CALLBACK IS NOT OPTIONAL. With a read callback alone `pb->seekable` is 0, and
 * libavformat's `mov` demuxer then read-discards the entire `mdat` to reach a trailing `moov`
 * (`aviobuf.c` forward-seek path, `mov.c` retry gated on AVIO_SEEKABLE_NORMAL). On a 60 MB file
 * that is 60 MB of cellular data to learn where the audio starts. `StreamDecodeTests` measures it.
 *
 * Threading: one decoder is driven by exactly one thread. `stream_decoder_cancel` is the single
 * exception — it may be called from any thread and only sets a flag the callbacks read.
 */
#ifndef STREAM_DECODE_H
#define STREAM_DECODE_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    STREAM_DECODE_OK = 0,
    STREAM_DECODE_EOF = 1,          /* the stream ended; not an error */
    STREAM_DECODE_ERR_ALLOC = 2,
    STREAM_DECODE_ERR_OPEN = 3,     /* not a container this build can demux */
    STREAM_DECODE_ERR_NO_AUDIO = 4, /* container opened, no audio stream */
    STREAM_DECODE_ERR_DECODER = 5,  /* no decoder for the codec, or it would not open */
    STREAM_DECODE_ERR_RESAMPLE = 6,
    STREAM_DECODE_ERR_IO = 7,       /* the reader could not deliver bytes */
    STREAM_DECODE_ERR_SEEK = 8,     /* avformat_seek_file refused */
    STREAM_DECODE_ERR_CANCELLED = 9,
    STREAM_DECODE_ERR_ARGS = 10,
    /* The caller asked for the current read to come back so it could seek. Unlike a cancel this is
     * not terminal: the decoder stays open and the next `stream_decoder_seek` clears it. */
    STREAM_DECODE_ERR_INTERRUPTED = 11
} StreamDecodeStatus;

/**
 * The byte source, as C. `opaque` is passed back untouched; the Swift wrapper puts an unmanaged
 * pointer to the box holding its `StreamByteReader` there.
 *
 * `read` MUST NOT return 0: libavformat treats a 0-length read as "try again" and spins. Report
 * end of stream as `STREAM_READ_EOF`, a cancel as `STREAM_READ_CANCELLED`, an interruption as
 * `STREAM_READ_INTERRUPTED`, and any transport failure as `STREAM_READ_ERROR`; anything > 0 is a
 * byte count.
 */
#define STREAM_READ_EOF         (-1)
#define STREAM_READ_CANCELLED   (-2)
#define STREAM_READ_ERROR       (-3)
/* The reader was interrupted so the caller could seek. Recoverable; see
 * `stream_decoder_interrupt`. */
#define STREAM_READ_INTERRUPTED (-4)

typedef struct {
    /** Copy up to `n` bytes at the current position into `buf`; advance by the count. */
    int (*read)(void *opaque, uint8_t *buf, int n);
    /** Move the current position to `offset`. 0 on success, `STREAM_READ_*` otherwise. */
    int (*seek)(void *opaque, int64_t offset);
    /** Total length in bytes, or < 0 when unknown (a live stream, or chunked with no length). */
    int64_t (*size)(void *opaque);
} StreamDecodeCallbacks;

/** What the container says about the audio, filled in by `stream_decoder_open`. */
typedef struct {
    int    sample_rate;      /* the SOURCE's rate; the player runs at it */
    int    channel_count;
    double duration_sec;     /* 0 when the container does not know (AV_NOPTS_VALUE) */
    char   codec_name[32];   /* "mp3", "aac", ... */
    char   container_name[64];
} StreamAudioInfo;

typedef struct StreamDecoder StreamDecoder;

/**
 * Open `callbacks` as an audio stream. Returns a handle on success and writes `info`; returns NULL
 * on failure and writes the reason to `status`.
 *
 * A failed open is ALWAYS a failure, never silence: a caller can fall back to another player on
 * it, and a decoder that opened nothing but reported success would present as a stream that plays
 * no audio and never ends.
 */
StreamDecoder *stream_decoder_open(const StreamDecodeCallbacks *callbacks,
                                   void *opaque,
                                   StreamAudioInfo *info,
                                   int *status);

/** The probe budget `stream_decoder_open` uses: 64 KiB and 1 s of analysis (stream_decode.c says
 *  why a single-stream audio container needs no more). */
#define STREAM_DECODE_DEFAULT_PROBE_BYTES 65536
#define STREAM_DECODE_DEFAULT_MAX_ANALYZE_US 1000000

/** How much `stream_decoder_open_with` may spend identifying the stream. A field <= 0 takes its
 *  default above. */
typedef struct {
    int64_t probe_bytes;              /* AVFormatContext.probesize */
    int64_t max_analyze_duration_us;  /* AVFormatContext.max_analyze_duration, AV_TIME_BASE units */
} StreamDecodeOptions;

/**
 * `stream_decoder_open` with a caller-chosen probe budget; `options` may be NULL, which is exactly
 * `stream_decoder_open`. A larger budget buys more container analysis (better stream info for
 * unusual files) at the cost of bytes read before the first frame.
 */
StreamDecoder *stream_decoder_open_with(const StreamDecodeCallbacks *callbacks,
                                        void *opaque,
                                        const StreamDecodeOptions *options,
                                        StreamAudioInfo *info,
                                        int *status);

/**
 * Seek to `seconds` and report where the stream actually landed in `landed_seconds`.
 *
 * The landed value is the time of the first sample the next `read` returns, in seconds, taken from
 * the decoded frames' timestamps — NOT the number that was asked for. It is the requested sample
 * wherever the stream's timestamps allow; a VBR MP3 placed by its Xing TOC or bitrate estimate
 * lands where that estimate says, and a seek past the end lands where the audio ends. The caller's
 * position must follow the audio, not the request, or the scrubber lies and every seek computed
 * from the position is against a time nobody played.
 *
 * The frame decoded to find that timestamp is held and returned by the next `read`, so no audio is
 * lost to the probe. Returns a `StreamDecodeStatus`.
 *
 * Clears any interruption first: an interrupt exists precisely so that the seek that follows it can
 * run, so leaving the flag latched would make every interrupted read permanent.
 */
int stream_decoder_seek(StreamDecoder *decoder, double seconds, double *landed_seconds);

/**
 * Fill `out` with up to `max_frames` frames of interleaved float32 in [-1, 1] at the source's rate
 * and channel count. `out` must hold `max_frames * info.channel_count` floats.
 *
 * Writes the frame count to `frames`. Zero frames is not by itself an error: the status says
 * whether it was `STREAM_DECODE_EOF`, a cancel, or an IO failure. Returns a `StreamDecodeStatus`.
 */
int stream_decoder_read(StreamDecoder *decoder, float *out, int max_frames, int *frames);

/** Bytes the reader has been asked for since the decoder opened. Diagnostics and tests only. */
int64_t stream_decoder_position_bytes(const StreamDecoder *decoder);

/**
 * Override the byte budget one seek may spend before it is abandoned for the byte estimate.
 * **Tests only.** Everything the fixtures contain seeks by an index or a table of contents and
 * lands well inside the real budget, so the fallback — and the AVIO state the abandoned seek
 * leaves behind — is otherwise only reachable on a container no test holds. A value <= 0 restores
 * the default.
 */
void stream_decoder_set_seek_budget_bytes(StreamDecoder *decoder, int64_t bytes);

/**
 * Strip the timestamps from every packet before the codec sees it, so no decoded frame carries a
 * time. **Tests only.** The demuxers in this build stamp every packet after a seek, so the
 * decoder's handling of a frame with no time is otherwise unreachable.
 */
void stream_decoder_drop_timestamps_for_testing(StreamDecoder *decoder);

/**
 * Abort any blocked or future callback. Safe from any thread, idempotent. The reader's own
 * `cancel` still has to unblock a call that is already waiting; this only stops the decoder
 * starting another one.
 */
void stream_decoder_cancel(StreamDecoder *decoder);

/**
 * Make the callback that is running right now return promptly, WITHOUT ending the decode.
 *
 * The seek race this exists for: the player's pull loop can be blocked inside a read on a stalled
 * connection, and a seek queued behind it would not be applied until the network answered — which
 * on a dead link is never. Cancelling would answer the seek but destroy the decoder; this leaves it
 * open and reusable, and `stream_decoder_seek` clears the flag. `stream_decoder_read` then reports
 * `STREAM_DECODE_ERR_INTERRUPTED`, which the caller must not read as end of stream.
 *
 * Safe from any thread, idempotent. The reader's own `interrupt` still has to unblock a call that
 * is already waiting.
 */
void stream_decoder_interrupt(StreamDecoder *decoder);

/** Clear an interruption without seeking. Safe on NULL. */
void stream_decoder_clear_interrupt(StreamDecoder *decoder);

/** Release everything. Safe on NULL. */
void stream_decoder_close(StreamDecoder *decoder);

#endif
