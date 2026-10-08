/*
 * decoder.h — the decoder's state and the core helpers the seek modules share (internal).
 *
 * stream_decode.c owns the open, the AVIO glue, the decode pump and the resampler; seek.c owns the
 * seek; the seek_*.c modules answer the per-format questions it asks (see seek.h).
 */
#ifndef CSTREAMDECODE_DECODER_H
#define CSTREAMDECODE_DECODER_H

#include "stream_decode.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>

#include "seek.h"

struct StreamDecoder {
    StreamDecodeCallbacks cb;
    void            *opaque;

    AVIOContext     *avio;
    AVFormatContext *fmt;
    AVCodecContext  *dec;
    SwrContext      *swr;
    /* What `swr` takes in; a frame that differs reconfigures it (see `push_through_swr`). */
    int              swr_in_rate;
    int              swr_in_fmt;
    AVChannelLayout  swr_in_layout;
    AVPacket        *pkt;
    AVFrame         *frame;
    /* A packet read during open (see `skip_unscanned_junk`) that the decoder has not had yet. */
    AVPacket        *held;
    int              has_held;

    /* 1 when the last `open_format` skipped `avformat_find_stream_info` (see
     * `header_described_audio_stream`). */
    int         skipped_probe;
    int         audio_idx;
    int         sample_rate;
    int         channels;
    /* The output grid: what `pending`, `stream_decoder_read` and `position_frames` count in. The
     * source's rate and channels unless `stream_decoder_set_output` asked for a fixed format. */
    int         out_rate;
    int         out_channels;
    int         output_fixed;     /* a read or seek has run; `stream_decoder_set_output` refuses */
    AVRational  time_base;
    int64_t     start_time;   /* stream start_time, or 0 when AV_NOPTS_VALUE */

    /* Decoded-but-not-yet-returned PCM, interleaved float32. `stream_decoder_read` copies out of
     * here and only pumps the decoder again once it is empty, so a caller asking for 4096 frames
     * never loses the tail of a 1152-frame MP3 frame. */
    float      *pending;
    int         pending_cap_floats;
    int         pending_frames;
    int         pending_offset;   /* frames already handed out */

    int64_t     last_frame_pts;   /* best_effort_timestamp of the most recent decoded frame */
    int         decode_errors;    /* consecutive `avcodec_receive_frame` errors, see `sd_pump` */
    int64_t     end_pts;          /* MP4: where the edit list ends the audio (stream time base), else NOPTS */
    int         flushing;         /* a NULL packet has been sent to the decoder */
    int         reopening;        /* draining the codec to reopen it for the held packet's new parameters */
    int         ended;            /* the decoder and the resampler are both drained */

    /* Written by `stream_decoder_cancel` from another thread and only ever read, so a plain flag
     * is enough: the worst a stale read costs is one more callback into a reader that is itself
     * already cancelled. */
    volatile int cancelled;
    /* Same shape as `cancelled`, opposite meaning: a read the caller wants back so it can seek,
     * after which the decoder carries on. Cleared by `stream_decoder_seek`. */
    volatile int interrupted;
    /* The reader refused a seek as `STREAM_READ_UNSEEKABLE` since the last `stream_decoder_seek`
     * began; lets that seek report "cannot seek" instead of a generic failure. */
    int          unseekable;
    int64_t      bytes_read;
    /* The reader itself said end of stream (`STREAM_READ_EOF`) since the last reader seek.
     * libavformat reports a broken read as end of file too, and only this tells them apart. */
    int          source_eof;

    /* Absolute source byte that FFmpeg's offset 0 maps to: the end of the leading ID3v2 tag(s).
     * See `probe_id3_offset`. Zero for everything without one. */
    int64_t      base_offset;

    /* Bytes libavformat may read inside one `avformat_seek_file` before the seek is abandoned.
     * Armed only around that call; see `stream_decoder_seek`. */
    int64_t      seek_budget;
    int64_t      seek_bytes;
    int          seek_budget_armed;
    /* Tests only; see `stream_decoder_set_seek_budget_bytes`. <= 0 means the default. */
    int64_t      seek_budget_override;
    int          seek_budget_blown;

    /* Whole-container facts kept for the byte-estimate seek: media bytes (size minus
     * `base_offset`) and the duration those bytes cover. */
    int64_t      media_bytes;
    double       media_duration;

    /* What a resume needs (see `resume_after_last_packet`): the frame the next read returns, the
     * last packet the codec was given, and whether the last read stopped on an interruption. */
    int64_t      position_frames;
    int64_t      last_pkt_pos;
    int64_t      last_pkt_dts;
    int          has_last_pkt;
    /* The packet `held` started as, while the codec has had nothing since the open. */
    int64_t      first_pkt_pos;
    int64_t      first_pkt_dts;
    int          has_first_pkt;
    int          resumable;

    /* The sample-accurate seek (see `seek_to` in seek.c). Frames that end before `discard_until` are decoded
     * and dropped, and the one that straddles it is cut, so the next read starts exactly there.
     * `next_pts` is where the last decoded frame ended, and `seek_first_pts` where the first frame
     * after the last seek started. All in stream time base. */
    int64_t      discard_until;
    int64_t      next_pts;
    int64_t      seek_first_pts;

    /* The timestamps after the last seek are the stream's true times: everything but a VBR MP3
     * placed by its TOC or bitrate (see `land_exactly` in seek.c). */
    int          landing_exact;
    /* Where the last seek asked the demuxer to go (stream time base), which is also where the
     * decode starts if no frame after it carries a time (see `sd_pump`). */
    int64_t      seek_from;
    /* Tests only: see `stream_decoder_drop_timestamps_for_testing`. */
    int          drop_timestamps;

    /* How this stream seeks (seek.h), chosen by `open_format`, and each format's own state. */
    const SeekFormat *seek_fmt;
    MP3SeekState  mp3;
    FLACSeekState flac;
    AACSeekState  aac;

    /* The first bytes of the media as libavformat read them (offset 0 is `base_offset`), kept so
     * the Xing/Info/VBRI frame can be read without a second request. */
    uint8_t      prologue[4096];
    int          prologue_len;
    /* Bytes the ID3 probe read and could not rewind over (a forward-only source refused the seek),
     * served to libavformat before the reader's next byte. See `probe_id3_offset`. */
    uint8_t      lead[10];
    int          lead_len;
    int          lead_pos;
    int64_t      io_pos;             /* libavformat's read position */
    int64_t      contiguous_read;    /* the end of the run of bytes read from offset 0, past any seeks */

    /* A one-frame MP3 shown to libavformat with a copy of its frame behind it (see
     * `reopen_single_frame_mp3`): `phantom_len` bytes at AVIO offset `phantom_at`. */
    uint8_t      phantom[1792];
    int          phantom_len;
    int64_t      phantom_at;
    int          phantom_samples;    /* the real frame's samples per channel */
};

/* stream_decode.c */
int  sd_pump(StreamDecoder *d);
int  sd_init_swr(StreamDecoder *d);
void sd_pending_reset(StreamDecoder *d);
int  sd_read_audio_packet(StreamDecoder *d);
int  sd_read_failure_status(StreamDecoder *d);
int  sd_hold_first_audio_packet(StreamDecoder *d);
void sd_avio_clear_latched_error(StreamDecoder *d);
int  sd_open_codec(const StreamDecoder *d, const AVCodec *codec, int flags2, AVCodecContext **out);
int  sd_reopen_codec(StreamDecoder *d);

/* seek_mp3.c: fill in what an MPEG audio frame header says. Returns 0 if `p` is not one. */
int  sd_mp3_parse_header(const uint8_t *p, int *spf, int *bitrate, int *sample_rate,
                         int *side_info_bytes);

/* seek_aac.c: where an AAC stream's time zero is (the priming and the decoder's own trim), at the
 * open; the priming's skip-samples on the packet that carries it; SBR seen in a decoded frame. */
int  sd_aac_open(StreamDecoder *d, const AVCodecParameters *par);
void sd_aac_packet_read(StreamDecoder *d, AVPacket *pkt);
void sd_aac_frame_decoded(StreamDecoder *d);
/* `duration_sec` less the priming and the decoder's own trim, which are not audio. */
double sd_aac_audio_duration(const StreamDecoder *d, double duration_sec);
/* What a decode from the first packet starts before time zero, in time base units (0 if not AAC). */
int64_t sd_aac_first_packet_trim(const StreamDecoder *d);

/* Big-endian, `bytes` (1 to 4) long. */
static inline uint32_t sd_read_be(const uint8_t *p, int bytes) {
    uint32_t v = 0;
    for (int i = 0; i < bytes; i++) v = (v << 8) | p[i];
    return v;
}

/* Whether the container gives enough to place a second in the byte stream by linear estimate. */
static inline int sd_can_estimate_bytes(const StreamDecoder *d) {
    return d->media_bytes > 0 && d->media_duration > 0;
}

#endif
