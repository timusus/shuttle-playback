/*
 * stream_decode.c — see stream_decode.h.
 *
 * The open follows the usual libavformat order: open, best-effort find_stream_info,
 * find_best_stream, decoder, swresample. Around it is what a player needs and a whole-buffer decode
 * does not: a seekable AVIO over a blocking reader, a pull-at-a-time decode loop with its own state,
 * seek, and cancel.
 */
#include "stream_decode.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

struct StreamDecoder {
    StreamDecodeCallbacks cb;
    void            *opaque;

    AVIOContext     *avio;
    AVFormatContext *fmt;
    AVCodecContext  *dec;
    SwrContext      *swr;
    AVPacket        *pkt;
    AVFrame         *frame;
    /* A packet read during open (see `skip_unscanned_junk`) that the decoder has not had yet. */
    AVPacket        *held;
    int              has_held;

    int         audio_idx;
    int         sample_rate;
    int         channels;
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
    int         flushing;         /* a NULL packet has been sent to the decoder */
    int         ended;            /* the decoder and the resampler are both drained */

    /* Written by `stream_decoder_cancel` from another thread and only ever read, so a plain flag
     * is enough: the worst a stale read costs is one more callback into a reader that is itself
     * already cancelled. */
    volatile int cancelled;
    /* Same shape as `cancelled`, opposite meaning: a read the caller wants back so it can seek,
     * after which the decoder carries on. Cleared by `stream_decoder_seek`. */
    volatile int interrupted;
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

    /* The sample-accurate seek (see `seek_to`). Frames that end before `discard_until` are decoded
     * and dropped, and the one that straddles it is cut, so the next read starts exactly there.
     * `next_pts` is where the last decoded frame ended, and `seek_first_pts` where the first frame
     * after the last seek started. All in stream time base. */
    int64_t      discard_until;
    int64_t      next_pts;
    int64_t      seek_first_pts;

    /* MP3 only. The first audio frame, which every other frame's index is counted from. */
    int64_t      first_pkt_size;
    int          mp3_header_ok;
    uint32_t     mp3_header;          /* its first four bytes, for "same stream" comparisons */
    int          mp3_spf;             /* samples per frame */
    int          mp3_tag;             /* MP3_TAG_*: what the frame before the first audio says */
    int          vbri_toc;            /* the VBRI table: its offset in `prologue`, and its shape */
    int          vbri_entries;        /* 0: no usable table */
    int          vbri_entry_size;
    int          vbri_scale;
    int          vbri_frames_per_entry;
    /* The last seek went to a frame whose time was known exactly (see `demux_seek`). */
    int          anchored;
    /* The timestamps after the last seek are the stream's true times: everything but a VBR MP3
     * placed by its TOC or bitrate (see `land_exactly`). */
    int          landing_exact;
    /* An AAC stream has been seen to carry SBR (HE-AAC v1 or v2), by its parameters or by a frame
     * the codec decoded: an ADTS header says plain AAC-LC either way. Never cleared. */
    int          sbr;
    /* Where the last seek asked the demuxer to go (stream time base), which is also where the
     * decode starts if no frame after it carries a time (see `pump`). */
    int64_t      seek_from;
    /* A Layer III seek's pre-roll, measured as it goes into the codec (see `mp3_measure_preroll`):
     * whether it is still being watched, the frames and main data bytes fed so far, the time of the
     * next frame, and whether it came up short of what the frames from the target need. */
    int          mp3_watch;
    int          mp3_watch_frames;
    int64_t      mp3_watch_bytes;
    int64_t      mp3_watch_next;
    int          mp3_preroll_short;
    /* Tests only: see `stream_decoder_drop_timestamps_for_testing`. */
    int          drop_timestamps;

    /* The first bytes of the media as libavformat read them (offset 0 is `base_offset`), kept so
     * the Xing/Info/VBRI frame can be read without a second request. */
    uint8_t      prologue[4096];
    int          prologue_len;
    int64_t      io_pos;             /* libavformat's read position */
};

enum { MP3_TAG_NONE = 0, MP3_TAG_INFO, MP3_TAG_VBR };

/* ── AVIO glue ───────────────────────────────────────────────────────────── */

static int avio_read_packet(void *opaque, uint8_t *buf, int buf_size) {
    StreamDecoder *d = (StreamDecoder *)opaque;
    if (d->cancelled || d->interrupted) return AVERROR_EXIT;
    /* A seek that has already spent its budget is a demuxer walking the file packet by packet to
     * build an index it has no table for. Refusing the read aborts the walk; the caller
     * falls back to the byte estimate, which costs one transaction instead of megabytes. */
    if (d->seek_budget_armed && d->seek_bytes >= d->seek_budget) {
        d->seek_budget_blown = 1;
        return AVERROR(EIO);
    }
    int n = d->cb.read(d->opaque, buf, buf_size);
    if (n > 0) {
        d->bytes_read += n;
        if (d->seek_budget_armed) d->seek_bytes += n;
        /* Only a contiguous run from offset 0 is kept. */
        if (d->io_pos <= d->prologue_len && d->io_pos < (int64_t)sizeof(d->prologue)) {
            int keep = (int)sizeof(d->prologue) - (int)d->io_pos;
            if (keep > n) keep = n;
            memcpy(d->prologue + d->io_pos, buf, (size_t)keep);
            if (d->io_pos + keep > d->prologue_len) d->prologue_len = (int)(d->io_pos + keep);
        }
        d->io_pos += n;
        return n;
    }
    /* Never 0: libavformat reads a 0 as "nothing yet, ask again" and spins on it forever. */
    switch (n) {
        case STREAM_READ_EOF:       d->source_eof = 1; return AVERROR_EOF;
        /* Latch it. During `stream_decoder_open` there is no handle for the caller's `cancel` to
         * reach, so the reader's own refusal is the only evidence that this was a cancel and not a
         * broken file — and the two must not be reported the same way. */
        case STREAM_READ_CANCELLED: d->cancelled = 1; return AVERROR_EXIT;
        /* Latched for the same reason a cancel is: the reader is the only one that knows its read
         * came back early, and the pull loop above must be able to tell an interruption from a
         * broken file. */
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return AVERROR_EXIT;
        default:                    return AVERROR(EIO);
    }
}

static int64_t avio_seek_packet(void *opaque, int64_t offset, int whence) {
    StreamDecoder *d = (StreamDecoder *)opaque;
    if (d->cancelled || d->interrupted) return AVERROR_EXIT;

    if (whence == AVSEEK_SIZE) {
        int64_t size = d->cb.size(d->opaque);
        /* ENOSYS is the documented "I do not know", and it is the ONLY honest answer for a source
         * with no length: a made-up size sends the mov demuxer seeking past the end. */
        return size >= 0 ? size - d->base_offset : AVERROR(ENOSYS);
    }

    int64_t target;
    switch (whence) {
        case SEEK_SET: target = offset; break;
        case SEEK_CUR: target = -1; break;   /* resolved below */
        case SEEK_END: {
            int64_t size = d->cb.size(d->opaque);
            if (size < 0) return AVERROR(ENOSYS);
            target = (size - d->base_offset) + offset;
            break;
        }
        default: return AVERROR(EINVAL);
    }
    if (whence == SEEK_CUR) {
        /* libavformat resolves SEEK_CUR itself for buffered IO, but a custom context can still be
         * handed one; the reader knows its own position, so ask it. */
        return AVERROR(ENOSYS);
    }
    if (target < 0) return AVERROR(EINVAL);

    int rc = d->cb.seek(d->opaque, target + d->base_offset);
    if (rc == 0) { d->source_eof = 0; d->io_pos = target; return target; }
    switch (rc) {
        case STREAM_READ_CANCELLED:   d->cancelled = 1; return AVERROR_EXIT;
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return AVERROR_EXIT;
        default:                      return AVERROR(EIO);
    }
}

/* ── the ID3v2 prologue ──────────────────────────────────────────────────── */

/*
 * How many bytes of leading ID3v2 tag(s) to hide from libavformat.
 *
 * **This is the streaming player's largest single bandwidth cost, and it is not hypothetical.**
 * Measured on a published 108 MB MP3: a 13 782 278-byte
 * ID3v2 tag holding a 3000x3000 PNG cover, which `mp3_read_header` READS — not seeks over, because
 * it parses every APIC frame and turns the picture into an attached-pic stream nobody asked for.
 * `stream_decoder_open` cost 13.8 MB of cellular data before a note was heard. `probesize` does not
 * bound it: the tag is consumed before the demuxer ever gets to probe audio.
 *
 * So the tag is stepped over here and FFmpeg's byte 0 is the first MPEG frame. The decoder reports
 * no tag metadata or artwork; a caller that wants them reads the tag itself. Byte offsets the
 * caller sees (`stream_decoder_position_bytes`, the reader's positions) stay the SOURCE's, since
 * the translation lives in the AVIO callbacks and nowhere else.
 *
 * Returns the absolute offset to start at, and leaves the reader positioned there. On anything
 * that is not ID3v2 it returns 0 and rewinds, which is every m4a and most mp3s.
 */
static int64_t probe_id3_offset(StreamDecoder *d) {
    int64_t offset = 0;
    for (;;) {
        uint8_t header[10];
        int got = 0;
        while (got < (int)sizeof(header)) {
            int n = d->cb.read(d->opaque, header + got, (int)sizeof(header) - got);
            /* Latched as the AVIO glue latches them: a probe cut short is not "no tag". */
            if (n == STREAM_READ_CANCELLED) d->cancelled = 1;
            if (n == STREAM_READ_INTERRUPTED) d->interrupted = 1;
            if (n <= 0) { got = -1; break; }
            got += n;
        }
        if (got != (int)sizeof(header)) {
            if (d->cancelled || d->interrupted) return 0;
            break;
        }
        if (header[0] != 'I' || header[1] != 'D' || header[2] != '3') break;
        if (header[3] == 0xFF || header[4] == 0xFF) break;   /* not a version we can trust */
        /* Syncsafe: seven bits per byte, high bit always clear. */
        if ((header[6] | header[7] | header[8] | header[9]) & 0x80) break;
        int64_t size = ((int64_t)header[6] << 21) | ((int64_t)header[7] << 14)
                     | ((int64_t)header[8] << 7)  |  (int64_t)header[9];
        int64_t span = 10 + size + ((header[5] & 0x10) ? 10 : 0);   /* bit 4 is "has footer" */
        if (span <= 0) break;
        offset += span;
        /* Tags can be stacked; step to the next one and look again. */
        if (d->cb.seek(d->opaque, offset) != 0) return 0;
    }
    /* Either there was no tag or the last read was past the last one: go back to where the media
     * (or the file) starts. */
    if (d->cb.seek(d->opaque, offset) != 0) return 0;
    return offset;
}

/* ── resampler ───────────────────────────────────────────────────────────── */

/* Same rate, same layout, float32 out: the resampler is here ONLY to interleave and to convert
 * whatever sample format the codec produces (mp3float is planar float, aac is planar float, and a
 * fixed-point build would be planar s16) into the one buffer format the player schedules. */
static int init_swr(StreamDecoder *d) {
    swr_free(&d->swr);

    AVChannelLayout out_layout = { 0 };
    /* Zero-initialised: av_channel_layout_copy uninitialises its destination first, so a free() of
     * stack garbage is an intermittent SIGABRT. */
    AVChannelLayout in_layout = { 0 };
    if (d->dec->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&in_layout, &d->dec->ch_layout);
    } else {
        av_channel_layout_default(&in_layout, d->channels > 0 ? d->channels : 1);
    }
    av_channel_layout_copy(&out_layout, &in_layout);

    int rc = swr_alloc_set_opts2(&d->swr,
                                 &out_layout, AV_SAMPLE_FMT_FLT, d->sample_rate,
                                 &in_layout, d->dec->sample_fmt, d->dec->sample_rate,
                                 0, NULL);
    av_channel_layout_uninit(&in_layout);
    av_channel_layout_uninit(&out_layout);
    if (rc < 0 || !d->swr) return STREAM_DECODE_ERR_RESAMPLE;
    if (swr_init(d->swr) < 0) return STREAM_DECODE_ERR_RESAMPLE;
    return STREAM_DECODE_OK;
}

static int pending_reserve(StreamDecoder *d, int frames) {
    int need = (d->pending_frames + frames) * d->channels;
    if (need <= d->pending_cap_floats) return 1;
    int cap = d->pending_cap_floats ? d->pending_cap_floats : 8192 * d->channels;
    while (cap < need) cap *= 2;
    float *nb = (float *)realloc(d->pending, (size_t)cap * sizeof(float));
    if (!nb) return 0;
    d->pending = nb;
    d->pending_cap_floats = cap;
    return 1;
}

/* Push `frame` (NULL flushes) through the resampler into `pending`. Returns 0 on allocation
 * failure, 1 otherwise; `pending_frames` says how much arrived. */
static int push_through_swr(StreamDecoder *d, AVFrame *frame) {
    int in_samples = frame ? frame->nb_samples : 0;
    int64_t delay = swr_get_delay(d->swr, d->sample_rate);
    int out_samples = (int)av_rescale_rnd(delay + in_samples, d->sample_rate, d->sample_rate,
                                          AV_ROUND_UP);
    if (out_samples <= 0) return 1;
    if (!pending_reserve(d, out_samples)) return 0;

    uint8_t *out = (uint8_t *)(d->pending + (size_t)d->pending_frames * d->channels);
    int converted = swr_convert(d->swr, &out, out_samples,
                                frame ? (const uint8_t **)frame->extended_data : NULL, in_samples);
    if (converted > 0) d->pending_frames += converted;
    return 1;
}

/* ── the decode pump ─────────────────────────────────────────────────────── */

static void pending_reset(StreamDecoder *d) {
    d->pending_frames = 0;
    d->pending_offset = 0;
}

/* HE-AAC v1 or v2: AAC with SBR. The AAC codec sets the profile per frame, from what it decoded. */
static int is_sbr(enum AVCodecID codec_id, int profile) {
    return codec_id == AV_CODEC_ID_AAC
        && (profile == AV_PROFILE_AAC_HE || profile == AV_PROFILE_AAC_HE_V2);
}

static void mp3_measure_preroll(StreamDecoder *d, const AVPacket *pkt);

/*
 * Advance until `pending` holds audio, or the stream is over.
 *
 * Precondition: `pending` is fully consumed. Returns STREAM_DECODE_OK with pending_frames > 0,
 * STREAM_DECODE_EOF when there is nothing left, or an error status. Every exit is a status: a
 * decode that quietly produced nothing would present as a recording that stops in the middle and
 * reports it finished.
 */
static int pump(StreamDecoder *d) {
    pending_reset(d);
    if (d->ended) return STREAM_DECODE_EOF;

    for (;;) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;

        int rc = avcodec_receive_frame(d->dec, d->frame);
        if (rc == 0) {
            if (is_sbr(d->dec->codec_id, d->dec->profile)) d->sbr = 1;
            /* The rate this frame came out at: for HE-AAC that is the SBR rate, twice the core
             * rate an implicitly signalled stream's header gives. */
            int rate = d->frame->sample_rate > 0 ? d->frame->sample_rate : d->sample_rate;
            /* Where this frame starts: its timestamp, or, for a frame with none, where the one
             * before it ended. */
            int64_t pts = d->frame->best_effort_timestamp;
            if (pts == AV_NOPTS_VALUE) pts = d->next_pts;
            if (pts == AV_NOPTS_VALUE && d->discard_until != AV_NOPTS_VALUE) {
                /* No frame since the seek has said what time it is. The demuxer was asked for
                 * `seek_from` and seeks backward, so the decode starts there or at most one frame
                 * before it: the frames are timed from there and the pre-roll is dropped as
                 * usual, which lands within a frame of the target (exactly, from the start).
                 * Keeping everything instead would play the whole pre-roll, seconds of audio
                 * before the target, reported as the target. */
                pts = d->seek_from;
                if (pts > d->start_time) d->landing_exact = 0;
            }
            if (pts != AV_NOPTS_VALUE) {
                d->next_pts = pts + av_rescale_q(d->frame->nb_samples,
                                                 (AVRational){ 1, rate }, d->time_base);
                if (d->seek_first_pts == AV_NOPTS_VALUE) d->seek_first_pts = pts;
            }
            int64_t cut = 0;
            if (d->discard_until != AV_NOPTS_VALUE) {
                if (pts == AV_NOPTS_VALUE) {
                    d->discard_until = AV_NOPTS_VALUE;   /* nothing to place it by: keep it all */
                } else {
                    cut = av_rescale_q(d->discard_until - pts, d->time_base,
                                       (AVRational){ 1, rate });
                    if (cut >= d->frame->nb_samples) {   /* wholly before the seek target */
                        av_frame_unref(d->frame);
                        continue;
                    }
                    if (cut < 0) cut = 0;
                    d->discard_until = AV_NOPTS_VALUE;
                }
            }
            d->last_frame_pts = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE
                : pts + av_rescale_q(cut, (AVRational){ 1, rate }, d->time_base);
            int ok = push_through_swr(d, d->frame);
            av_frame_unref(d->frame);
            if (!ok) return STREAM_DECODE_ERR_ALLOC;
            /* Same rate in and out, so the resampler holds nothing back: frame sample N is
             * pending frame N. */
            d->pending_offset = cut < d->pending_frames ? (int)cut : d->pending_frames;
            if (d->pending_frames > d->pending_offset) return STREAM_DECODE_OK;
            pending_reset(d);
            continue;   /* the resampler is still filling; ask for another frame */
        }
        if (rc == AVERROR_EOF) {
            /* The decoder is drained; whatever libswresample still holds is the last of it. */
            if (!push_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
            d->ended = 1;
            return d->pending_frames > 0 ? STREAM_DECODE_OK : STREAM_DECODE_EOF;
        }
        if (rc != AVERROR(EAGAIN)) return STREAM_DECODE_ERR_DECODER;

        if (d->flushing) {
            /* EAGAIN after a NULL packet cannot happen, but treat it as the end rather than
             * looping: an unbounded loop here is a hung player. */
            if (!push_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
            d->ended = 1;
            return d->pending_frames > 0 ? STREAM_DECODE_OK : STREAM_DECODE_EOF;
        }

        int read = 0;
        if (d->has_held) {
            av_packet_move_ref(d->pkt, d->held);
            d->has_held = 0;
        } else {
            read = av_read_frame(d->fmt, d->pkt);
        }
        if (read < 0) {
            av_packet_unref(d->pkt);
            if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
            if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
            if (read == AVERROR_EXIT) return STREAM_DECODE_ERR_CANCELLED;
            if (read == AVERROR_EOF) {
                avcodec_send_packet(d->dec, NULL);
                d->flushing = 1;
                continue;
            }
            return STREAM_DECODE_ERR_IO;
        }
        /* A read that was cut short still hands back what it had: `av_get_packet` returns the
         * bytes it got as a truncated packet. The codec would reject it and its audio would be
         * gone, so it is dropped here and read again whole after the resume. */
        if (d->cancelled || d->interrupted) {
            av_packet_unref(d->pkt);
            return d->cancelled ? STREAM_DECODE_ERR_CANCELLED : STREAM_DECODE_ERR_INTERRUPTED;
        }
        if (d->pkt->stream_index != d->audio_idx) {
            av_packet_unref(d->pkt);
            continue;
        }
        if (d->drop_timestamps) d->pkt->pts = d->pkt->dts = AV_NOPTS_VALUE;
        d->last_pkt_pos = d->pkt->pos;
        d->last_pkt_dts = d->pkt->dts;
        d->has_last_pkt = d->pkt->pos >= 0 && d->pkt->dts != AV_NOPTS_VALUE;
        d->has_first_pkt = 0;
        if (d->mp3_watch) mp3_measure_preroll(d, d->pkt);
        int sent = avcodec_send_packet(d->dec, d->pkt);
        av_packet_unref(d->pkt);
        /* A packet the decoder rejects is a corrupt frame, not the end of the stream: skip it and
         * keep going, which is what every player does with a bad MP3 frame. */
        (void)sent;
    }
}

/* ── public API ──────────────────────────────────────────────────────────── */

static int  open_format(StreamDecoder *d, const StreamDecodeOptions *options);
static void close_format(StreamDecoder *d);
static int  skip_unscanned_junk(StreamDecoder *d, const StreamDecodeOptions *options);
static void avio_clear_latched_error(StreamDecoder *d);

StreamDecoder *stream_decoder_open(const StreamDecodeCallbacks *callbacks,
                                   void *opaque,
                                   StreamAudioInfo *info,
                                   int *status) {
    return stream_decoder_open_with(callbacks, opaque, NULL, info, status);
}

StreamDecoder *stream_decoder_open_with(const StreamDecodeCallbacks *callbacks,
                                        void *opaque,
                                        const StreamDecodeOptions *options,
                                        StreamAudioInfo *info,
                                        int *status) {
    int local_status = STREAM_DECODE_ERR_ALLOC;
    if (!callbacks || !callbacks->read || !callbacks->seek || !callbacks->size || !info) {
        if (status) *status = STREAM_DECODE_ERR_ARGS;
        return NULL;
    }
    /* libav's own diagnostics go to stderr at AV_LOG_INFO and say nothing the caller acts on; the
     * status codes are the channel that is read, and a host app's console stays its own. */
    av_log_set_level(AV_LOG_QUIET);
    memset(info, 0, sizeof(*info));

    StreamDecoder *d = (StreamDecoder *)calloc(1, sizeof(StreamDecoder));
    if (!d) { if (status) *status = STREAM_DECODE_ERR_ALLOC; return NULL; }
    d->cb = *callbacks;
    d->opaque = opaque;
    d->audio_idx = -1;
    d->last_frame_pts = AV_NOPTS_VALUE;
    d->discard_until = AV_NOPTS_VALUE;
    d->next_pts = AV_NOPTS_VALUE;
    d->seek_first_pts = AV_NOPTS_VALUE;
    d->seek_from = AV_NOPTS_VALUE;

    /* Before anything reads: hide the ID3v2 tag, which on a real published MP3 is megabytes of
     * cover art that libavformat would otherwise consume in full. */
    d->base_offset = probe_id3_offset(d);
    if (d->cancelled) { local_status = STREAM_DECODE_ERR_CANCELLED; goto fail; }
    if (d->interrupted) { local_status = STREAM_DECODE_ERR_INTERRUPTED; goto fail; }

    local_status = open_format(d, options);
    if (local_status != STREAM_DECODE_OK) goto fail;
    local_status = skip_unscanned_junk(d, options);
    if (local_status != STREAM_DECODE_OK) goto fail;
    local_status = STREAM_DECODE_ERR_ALLOC;

    AVStream *stream = d->fmt->streams[d->audio_idx];
    AVCodecParameters *par = stream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) { local_status = STREAM_DECODE_ERR_DECODER; goto fail; }

    d->dec = avcodec_alloc_context3(codec);
    if (!d->dec) goto fail;
    if (avcodec_parameters_to_context(d->dec, par) < 0) { local_status = STREAM_DECODE_ERR_DECODER; goto fail; }
    /* One thread: FFmpeg's audio decoders have no frame threading to gain from, and the
     * pull loop is single-threaded by contract. */
    d->dec->thread_count = 1;
    /* Without it the codec cannot move a frame's timestamp past the encoder delay it trims
     * (decode.c discard_samples), and the first frame after the start is labelled as though the
     * trimmed samples were still in it. */
    d->dec->pkt_timebase = stream->time_base;
    if (avcodec_open2(d->dec, codec, NULL) < 0) { local_status = STREAM_DECODE_ERR_DECODER; goto fail; }

    d->sample_rate = d->dec->sample_rate > 0 ? d->dec->sample_rate : par->sample_rate;
    d->channels = d->dec->ch_layout.nb_channels > 0 ? d->dec->ch_layout.nb_channels
                                                    : par->ch_layout.nb_channels;
    if (d->sample_rate <= 0 || d->channels <= 0) { local_status = STREAM_DECODE_ERR_DECODER; goto fail; }
    d->sbr = is_sbr(par->codec_id, par->profile);
    d->time_base = stream->time_base;
    d->start_time = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;

    local_status = init_swr(d);
    if (local_status != STREAM_DECODE_OK) goto fail;

    d->frame = av_frame_alloc();
    if (!d->frame) { local_status = STREAM_DECODE_ERR_ALLOC; goto fail; }

    info->sample_rate = d->sample_rate;
    info->channel_count = d->channels;
    /* Format duration first, stream duration second (an MP3's Xing frame count reaches the stream
     * before it reaches the format).
     *
     * A source with NO TOTAL LENGTH still gets the Xing duration: stock n7.1 mp3dec stored the
     * negative "unknown" `avio_size()` in a uint64_t and discarded the tag, which the local patch
     * scripts/ffmpeg-patches/0001 fixes (issue #1). A length-less MP3 with no Xing tag reports 0,
     * and the caller falls back to whatever duration it has from elsewhere. */
    if (d->fmt->duration != AV_NOPTS_VALUE) {
        info->duration_sec = (double)d->fmt->duration / (double)AV_TIME_BASE;
    } else if (stream->duration != AV_NOPTS_VALUE) {
        info->duration_sec = (double)stream->duration * av_q2d(stream->time_base);
    }
    /* Kept for the byte-estimate seek: what the media occupies in bytes and how long it lasts. */
    {
        int64_t total = d->cb.size(d->opaque);
        d->media_bytes = total > d->base_offset ? total - d->base_offset : 0;
        d->media_duration = info->duration_sec;
    }
    snprintf(info->codec_name, sizeof(info->codec_name), "%s", avcodec_get_name(par->codec_id));
    if (d->fmt->iformat && d->fmt->iformat->name) {
        snprintf(info->container_name, sizeof(info->container_name), "%s", d->fmt->iformat->name);
    }

    if (status) *status = STREAM_DECODE_OK;
    return d;

fail:
    if (status) *status = local_status;
    stream_decoder_close(d);
    return NULL;
}

/* Undo `open_format`: the format context and the AVIO context it reads through. */
static void close_format(StreamDecoder *d) {
    if (d->fmt) avformat_close_input(&d->fmt);
    /* avformat_close_input frees the format context but not the AVIO one, and libavformat may have
     * replaced the buffer we handed it, so free the CURRENT pointer. */
    if (d->avio) {
        av_freep(&d->avio->buffer);
        avio_context_free(&d->avio);
    }
    d->audio_idx = -1;
}

static void hold_first_packet(StreamDecoder *d);

/*
 * Open libavformat over the reader, starting at `base_offset`, and find the audio stream.
 * Returns a StreamDecodeStatus.
 */
static int open_format(StreamDecoder *d, const StreamDecodeOptions *options) {
    const int avio_buf_size = 32 * 1024;
    uint8_t *avio_buf = (uint8_t *)av_malloc(avio_buf_size);
    if (!avio_buf) return STREAM_DECODE_ERR_ALLOC;

    /* Read AND seek: with a NULL seek callback `pb->seekable` is 0 and the mov demuxer walks the
     * whole `mdat` to find a trailing `moov` (see the header). */
    d->avio = avio_alloc_context(avio_buf, avio_buf_size, 0, d, avio_read_packet, NULL,
                                 avio_seek_packet);
    if (!d->avio) { av_free(avio_buf); return STREAM_DECODE_ERR_ALLOC; }

    d->fmt = avformat_alloc_context();
    if (!d->fmt) return STREAM_DECODE_ERR_ALLOC;
    d->fmt->pb = d->avio;
    /* Bound what probing costs in BYTES, because for a streaming source bytes are cellular data.
     * The defaults are a 5 MB probe and 5 s of analysis, and libavformat spends them eagerly:
     * measured on `tone_moov_last.m4a`, open() alone read 42% of the file, all of it before a
     * single frame was played. Spoken-word and music audio is one stream in a container the first packets
     * already describe, so a 64 KiB probe and 1 s of analysis identify it just as well. Those are
     * the defaults; a caller with a different trade-off passes `StreamDecodeOptions`. */
    d->fmt->probesize = (options && options->probe_bytes > 0)
        ? options->probe_bytes : STREAM_DECODE_DEFAULT_PROBE_BYTES;
    d->fmt->max_analyze_duration = (options && options->max_analyze_duration_us > 0)
        ? options->max_analyze_duration_us : STREAM_DECODE_DEFAULT_MAX_ANALYZE_US;
    /* Seek by the table of contents the container carries rather than by binary search. Without
     * this `mp3_seek` only trusts a Xing TOC on a file it has decided is CBR, and for everything
     * else it runs `ff_seek_frame_binary`, which probes and re-syncs its way through the file: on
     * the 160 KB tone fixture one seek to 10 s read 72 KB, and on an hour-long file it is the walk the
     * budget below exists to stop. The TOC is a coarser landing (a percent of the file per entry)
     * and the caller's position follows the frame that is actually decoded, so the cost of taking
     * it is nothing this player can observe. */
    d->fmt->flags |= AVFMT_FLAG_FAST_SEEK;
    /* With no total length, stop the MP4 header at the moov and mdat (issue #9). mov reads root
     * atoms until it has both AND the last one ends at `avio_size()` (mov.c mov_read_default); with
     * no size that never holds, so it skipped to the end of the mdat, read past the end of the
     * source for a next atom, and the first packet seeked back and read its 32 KiB again. IGNIDX
     * is the flag that condition also stops on, and in this build mov is the only demuxer that
     * reads it: it stops there and leaves the rest of the file to `next_root_atom`, which is how
     * mov reads a source that cannot seek.
     *
     * It stays set for the life of the decoder. A fragmented MP4 reads each later moof the same
     * way, from `next_root_atom` while it plays or from its fragment index (sidx, tfra) when it
     * seeks, and that read has to stop at the fragment's mdat for the same reason: with the flag
     * cleared it read on through every remaining fragment to the end of the file, reported that
     * as the end, and playback stopped after the first fragment. */
    if (d->cb.size(d->opaque) < 0) d->fmt->flags |= AVFMT_FLAG_IGNIDX;

    int opened = avformat_open_input(&d->fmt, NULL, NULL, NULL);
    if (opened < 0) {
        d->fmt = NULL;   /* avformat_open_input freed it; the AVIO context is still ours */
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        /* Not "unsupported": the caller answers that with another player, and an interrupt is
         * only a seek arriving while the stream opens. */
        return d->interrupted ? STREAM_DECODE_ERR_INTERRUPTED : STREAM_DECODE_ERR_OPEN;
    }
    /* Best effort: some containers decode fine with thinner metadata. */
    (void)avformat_find_stream_info(d->fmt, NULL);
    /* Not when it was cut short, though: an interrupted probe leaves out what it had not reached,
     * an MP3's bitrate duration among it, and every later seek then takes another path and lands
     * somewhere else (issue #5). Such an open fails, and opening again costs only the probe. */
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;

    d->audio_idx = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (d->audio_idx < 0) return STREAM_DECODE_ERR_NO_AUDIO;
    return STREAM_DECODE_OK;
}

/* How far `mp3_read_header` looks for the first frame (`for (i = 0; i < 64 * 1024; i++)`). */
static const int64_t kMP3JunkScanBytes = 64 * 1024;
/* The largest MPEG audio frame (`MPA_MAX_CODED_FRAME_SIZE`); a first packet larger than this has
 * junk in it. */
static const int kMP3MaxFrameBytes = 1792;

/* Move the reader to `offset` for a reopen. A cancel or an interrupt is latched and reported as
 * itself; any other refusal is STREAM_DECODE_ERR_IO. */
static int reopen_seek(StreamDecoder *d, int64_t offset) {
    switch (d->cb.seek(d->opaque, offset)) {
        case 0:                       return STREAM_DECODE_OK;
        case STREAM_READ_CANCELLED:   d->cancelled = 1; return STREAM_DECODE_ERR_CANCELLED;
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return STREAM_DECODE_ERR_INTERRUPTED;
        default:                      return STREAM_DECODE_ERR_IO;
    }
}

/*
 * Step over junk before the first MP3 frame that libavformat itself did not.
 *
 * mp3dec looks 64 KiB past its start for two consecutive frames and, finding none, takes byte 0 as
 * the start of the audio. Decoding still works, because the parser resyncs on the first real frame,
 * but every byte-based estimate is then wrong: the duration counts the junk as audio, and a seek
 * puts its bitrate guess inside the junk and plays from the start of the file (issue #2). The first
 * packet says where the audio really starts; reopening there gives the demuxer the file it should
 * have seen, with its duration and its seeks. Otherwise the packet is kept for the decoder, so
 * nothing is read twice.
 */
static int skip_unscanned_junk(StreamDecoder *d, const StreamDecodeOptions *options) {
    d->pkt = av_packet_alloc();
    d->held = av_packet_alloc();
    if (!d->pkt || !d->held) return STREAM_DECODE_ERR_ALLOC;
    if (!d->fmt->iformat || strcmp(d->fmt->iformat->name, "mp3") != 0) return STREAM_DECODE_OK;

    int rc;
    while ((rc = av_read_frame(d->fmt, d->held)) >= 0 && d->held->stream_index != d->audio_idx) {
        av_packet_unref(d->held);
    }
    if (rc < 0) {
        /* No packet at all is the decode's to report, not the open's; an interrupted or cancelled
         * read is the open's. */
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        avio_clear_latched_error(d);
        return STREAM_DECODE_OK;
    }
    int64_t end = d->held->pos + d->held->size;
    if (d->held->pos < 0 || d->held->size <= kMP3MaxFrameBytes || end <= kMP3JunkScanBytes) {
        hold_first_packet(d);
        return STREAM_DECODE_OK;
    }
    /* The parser hands the junk over glued to the first frame, so the frame is somewhere in the
     * packet's last `kMP3MaxFrameBytes`. Reopening there leaves less junk than mp3dec's own scan
     * covers, and that scan finds the frame exactly. */
    int64_t junk = end - kMP3MaxFrameBytes;
    av_packet_unref(d->held);
    close_format(d);
    d->base_offset += junk;
    rc = reopen_seek(d, d->base_offset);
    if (rc == STREAM_DECODE_ERR_IO) {
        /* The reader cannot serve the frame's offset. Open where the demuxer first did and keep
         * the junk: that decodes, as it did before this reopen existed, and only the byte
         * estimates are off. */
        d->base_offset -= junk;
        rc = reopen_seek(d, d->base_offset);
        if (rc == STREAM_DECODE_ERR_IO) return STREAM_DECODE_ERR_OPEN;
    }
    if (rc != STREAM_DECODE_OK) return rc;
    d->io_pos = 0;
    d->prologue_len = 0;
    rc = open_format(d, options);
    if (rc != STREAM_DECODE_OK) return rc;
    /* The first frame again, for the same reason as above: every seek counts frames from it. The
     * decoder would read it next anyway, so this costs nothing. */
    int read;
    while ((read = av_read_frame(d->fmt, d->held)) >= 0 && d->held->stream_index != d->audio_idx) {
        av_packet_unref(d->held);
    }
    if (read >= 0) {
        hold_first_packet(d);
    } else {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        avio_clear_latched_error(d);
    }
    return STREAM_DECODE_OK;
}

/* ── MP3 frame counting ──────────────────────────────────────────────────── */

/* Fill in what an MPEG audio frame header says. Returns 0 if `p` is not one. */
static int mp3_parse_header(const uint8_t *p, int *spf, int *bitrate, int *sample_rate,
                            int *side_info_bytes) {
    static const int kbps[2][3][16] = {
        { { 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 },
          { 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 },
          { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 } },
        { { 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 },
          { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
          { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 } },
    };
    static const int rates[3] = { 44100, 48000, 32000 };
    uint32_t h = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
    if ((h & 0xFFE00000u) != 0xFFE00000u) return 0;
    int version = (h >> 19) & 3;          /* 0: MPEG 2.5, 1: reserved, 2: MPEG 2, 3: MPEG 1 */
    int layer = 4 - (int)((h >> 17) & 3); /* 4 is reserved */
    int br = (h >> 12) & 15, sr = (h >> 10) & 3;
    if (version == 1 || layer == 4 || br == 0 || br == 15 || sr == 3) return 0;
    int lsf = version != 3;
    *bitrate = kbps[lsf][layer - 1][br] * 1000;
    *sample_rate = rates[sr] >> (version == 3 ? 0 : version == 2 ? 1 : 2);
    *spf = layer == 1 ? 384 : (layer == 3 && lsf) ? 576 : 1152;
    int mono = ((h >> 6) & 3) == 3;
    *side_info_bytes = lsf ? (mono ? 9 : 17) : (mono ? 17 : 32);
    return 1;
}

/* What the frame before the first audio frame declares: LAME's "Info" is a CBR stream, "Xing" and
 * "VBRI" a VBR one. Read from the prologue, which holds those bytes already. */
static uint32_t read_be(const uint8_t *p, int bytes) {
    uint32_t v = 0;
    for (int i = 0; i < bytes; i++) v = (v << 8) | p[i];
    return v;
}

/*
 * Keep a VBRI frame's table of contents, which mp3dec reads the frame count from and otherwise
 * ignores (libavformat/mp3dec.c mp3_parse_vbri_tag). Unlike a Xing TOC, which gives a share of the
 * file per percent of the duration, entry k is the exact byte length of `frames per entry` frames
 * counted from the end of the VBRI frame, so the frame it ends on, and its time, are exact. A
 * table whose entries add up to more bytes, or more frames, than the header says is not used.
 */
static void mp3_read_vbri_toc(StreamDecoder *d, const uint8_t *vbri, const uint8_t *end) {
    uint32_t bytes = read_be(vbri + 10, 4), frames = read_be(vbri + 14, 4);
    int entries = (int)read_be(vbri + 18, 2), scale = (int)read_be(vbri + 20, 2);
    int size = (int)read_be(vbri + 22, 2), per_entry = (int)read_be(vbri + 24, 2);
    if (size < 1 || size > 4 || scale < 1 || per_entry < 1 || entries < 1) return;
    if (vbri + 26 + (int64_t)entries * size > end) return;
    if ((int64_t)entries * per_entry > (int64_t)frames + per_entry) return;
    int64_t sum = 0;
    for (int k = 0; k < entries; k++) sum += (int64_t)read_be(vbri + 26 + k * size, size) * scale;
    if (sum > bytes) return;
    d->vbri_toc = (int)(vbri + 26 - d->prologue);
    d->vbri_entries = entries;
    d->vbri_entry_size = size;
    d->vbri_scale = scale;
    d->vbri_frames_per_entry = per_entry;
}

/*
 * The last VBRI table entry at or before `ts`, as the byte position and exact timestamp of the
 * frame it starts; before the first entry, the first frame. Returns 0 when there is no table.
 */
static int mp3_vbri_anchor(const StreamDecoder *d, int64_t ts, int64_t *pos, int64_t *dts) {
    if (!d->vbri_entries || !d->mp3_header_ok) return 0;
    int64_t samples = av_rescale_q(ts - d->first_pkt_dts, d->time_base, (AVRational){ 1, d->sample_rate });
    int64_t k = samples / ((int64_t)d->vbri_frames_per_entry * d->mp3_spf);
    if (k > d->vbri_entries) k = d->vbri_entries;
    if (k < 0) k = 0;
    int64_t at = d->first_pkt_pos;
    for (int64_t i = 0; i < k; i++) {
        at += (int64_t)read_be(d->prologue + d->vbri_toc + i * d->vbri_entry_size, d->vbri_entry_size)
              * d->vbri_scale;
    }
    *pos = at;
    *dts = d->first_pkt_dts + av_rescale_q(k * d->vbri_frames_per_entry * d->mp3_spf,
                                           (AVRational){ 1, d->sample_rate }, d->time_base);
    return 1;
}

static int mp3_find_tag(StreamDecoder *d) {
    int64_t limit = d->first_pkt_pos < d->prologue_len ? d->first_pkt_pos : d->prologue_len;
    for (int64_t p = 0; p + 4 <= limit; p++) {
        int spf, br, sr, side;
        if (!mp3_parse_header(d->prologue + p, &spf, &br, &sr, &side)) continue;
        const uint8_t *xing = d->prologue + p + 4 + side;
        const uint8_t *vbri = d->prologue + p + 36;
        if (xing + 4 <= d->prologue + limit) {
            if (!memcmp(xing, "Info", 4)) return MP3_TAG_INFO;
            if (!memcmp(xing, "Xing", 4)) return MP3_TAG_VBR;
        }
        if (vbri + 26 <= d->prologue + limit && !memcmp(vbri, "VBRI", 4)) {
            mp3_read_vbri_toc(d, vbri, d->prologue + limit);
            return MP3_TAG_VBR;
        }
    }
    return MP3_TAG_NONE;
}

/* Keep `d->held`, the first audio packet, for the decoder, and note what frame counting needs. */
static void hold_first_packet(StreamDecoder *d) {
    d->has_held = 1;
    d->first_pkt_pos = d->held->pos;
    d->first_pkt_dts = d->held->dts;
    d->first_pkt_size = d->held->size;
    d->has_first_pkt = d->held->pos >= 0 && d->held->dts != AV_NOPTS_VALUE;
    int spf, br, sr, side;
    if (d->has_first_pkt && d->held->size >= 4
        && mp3_parse_header(d->held->data, &spf, &br, &sr, &side)) {
        d->mp3_header_ok = 1;
        d->mp3_header = ((uint32_t)d->held->data[0] << 24) | ((uint32_t)d->held->data[1] << 16)
                      | ((uint32_t)d->held->data[2] << 8) | d->held->data[3];
        d->mp3_spf = spf;
        d->mp3_tag = mp3_find_tag(d);
    }
}

/* The header fields that make two frames the same stream: version, layer, bitrate, sample rate
 * and channel mode. Padding, CRC and the mode extension change frame to frame and do not count. */
static const uint32_t kMP3SameStreamMask = 0xFFFEFCC0u;

/*
 * The true timestamp of `pkt`, the first packet after an estimated MP3 seek; AV_NOPTS_VALUE when
 * there is no better answer than the demuxer's.
 *
 * An MP3 frame carries no timestamp. `mp3_seek` places a seek by the Xing TOC or by bitrate,
 * syncs to the next frame after that byte and labels the frame with the time it was ASKED for
 * (or, with an Info frame count, a rounded share of it), not the time of the frame it found
 * (issue #3). In a constant-bitrate stream the frame's index follows from its byte offset: frames
 * after the first are spf * bitrate / (8 * rate) bytes long on average and padding keeps each
 * within one byte of that, so the offset from the end of the first frame, divided and rounded, counts them exactly
 * (the first frame is measured, not assumed, because it is the one an encoder cuts short). A
 * stream is constant-bitrate when its Info frame says so, or when it has no tag frame, every
 * estimate this decoder makes already assumes it and the landed frame is the first one's twin.
 * A VBR stream has no such relation and keeps the demuxer's estimate.
 */
static int64_t mp3_exact_dts(const StreamDecoder *d, const AVPacket *pkt) {
    if (!d->mp3_header_ok || d->mp3_tag == MP3_TAG_VBR) return AV_NOPTS_VALUE;
    if (d->mp3_tag == MP3_TAG_NONE && d->cb.size(d->opaque) < 0) return AV_NOPTS_VALUE;
    if (pkt->pos < 0 || pkt->dts == AV_NOPTS_VALUE || pkt->size < 4) return AV_NOPTS_VALUE;
    uint32_t h = ((uint32_t)pkt->data[0] << 24) | ((uint32_t)pkt->data[1] << 16)
               | ((uint32_t)pkt->data[2] << 8) | pkt->data[3];
    /* An Info frame vouches for the bitrate of the frames after the first, which may itself be a
     * short one at another bitrate; with no tag, only the first frame's twin is trusted. */
    uint32_t mask = d->mp3_tag == MP3_TAG_INFO ? (kMP3SameStreamMask & ~0xF000u) : kMP3SameStreamMask;
    int spf, br, sr, side;
    if ((h & mask) != (d->mp3_header & mask) || !mp3_parse_header(pkt->data, &spf, &br, &sr, &side)) {
        return AV_NOPTS_VALUE;
    }
    int64_t index = 0;
    if (pkt->pos != d->first_pkt_pos) {
        int64_t second = d->first_pkt_pos + d->first_pkt_size;
        if (pkt->pos < second) return AV_NOPTS_VALUE;
        index = 1 + llround((double)(pkt->pos - second) * 8.0 * sr / ((double)spf * br));
    }
    return d->first_pkt_dts + av_rescale_q(index * d->mp3_spf,
                                           (AVRational){ 1, d->sample_rate }, d->time_base);
}

/* What a Layer III frame header says about the frame. */
typedef struct {
    int spf, bitrate, sample_rate, side_info_bytes, lsf;
    int bytes;   /* the whole frame, padding included */
} MP3Frame;

static int mp3_frame_of(uint32_t h, MP3Frame *f) {
    const uint8_t p[4] = { (uint8_t)(h >> 24), (uint8_t)(h >> 16), (uint8_t)(h >> 8), (uint8_t)h };
    if (((h >> 17) & 3) != 1) return 0;   /* Layer III only: the one with a bit reservoir */
    if (!mp3_parse_header(p, &f->spf, &f->bitrate, &f->sample_rate, &f->side_info_bytes)) return 0;
    f->lsf = ((h >> 19) & 3) != 3;
    f->bytes = (int)((int64_t)f->spf / 8 * f->bitrate / f->sample_rate) + (int)((h >> 9) & 1);
    return 1;
}

/*
 * Judge a seek's pre-roll by the frames it actually fed the codec, one frame at a time as each goes
 * in: `mp3_preroll_short` is set when the frames from the target on will not decode as an unbroken
 * run decodes them, and `seek_to` then places the seek further back.
 *
 * A Layer III frame's main data begins `main_data_begin` bytes before the frame's own, inside the
 * main data of the frames before it, and a codec that was never fed those bytes decodes the frame
 * from nothing. Main data runs in frame order, so once one frame's begins inside what was fed, every
 * later frame's does too. The output from the target depends on the frame the target falls in and
 * the two before it (each frame's overlap into the next, and in MPEG-2 the overlap into that), so
 * the frame two before the target's is the one judged: its `main_data_begin` against the main data
 * of the frames fed before it, as read from their headers and side info, whatever the first frame's
 * bitrate said. A pre-roll that starts on that frame or after it, with nothing before to overlap
 * from, is short too, unless it starts on the first audio frame, where the decode is the unbroken
 * one. A frame that is not Layer III, or is cut short, ends the watch unjudged: Layers I and II
 * have no reservoir, and a free-format frame's header does not give its size.
 */
static void mp3_measure_preroll(StreamDecoder *d, const AVPacket *pkt) {
    MP3Frame f;
    int side = pkt->size >= 4 && mp3_frame_of(read_be(pkt->data, 4), &f)
             ? 4 + ((pkt->data[1] & 1) ? 0 : 2) : -1;   /* the side info follows the CRC, if any */
    if (side < 0 || pkt->size < side + f.side_info_bytes || d->discard_until == AV_NOPTS_VALUE) {
        d->mp3_watch = 0;
        return;
    }
    if (d->mp3_watch_frames == 0 && pkt->pos >= 0 && pkt->pos == d->first_pkt_pos) {
        d->mp3_watch = 0;
        return;
    }
    int begin = f.lsf ? pkt->data[side] : (pkt->data[side] << 1) | (pkt->data[side + 1] >> 7);
    int64_t duration = av_rescale_q(f.spf, (AVRational){ 1, f.sample_rate }, d->time_base);
    int64_t dts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts
                : d->mp3_watch_frames > 0 ? d->mp3_watch_next : d->seek_from;
    if (dts != AV_NOPTS_VALUE && dts + 3 * duration > d->discard_until) {
        d->mp3_preroll_short = d->mp3_watch_frames == 0 || begin > d->mp3_watch_bytes;
        d->mp3_watch = 0;
        return;
    }
    d->mp3_watch_frames++;
    d->mp3_watch_bytes += pkt->size - side - f.side_info_bytes;
    d->mp3_watch_next = dts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : dts + duration;
}

/* The header of the frames after the first in a constant-bitrate Layer III stream, 0 when that is
 * not known. With an Info frame the first audio frame may be a short one at another bitrate, so the
 * second frame is read from the prologue; with no tag frame only the first frame's twins are trusted
 * (as in `mp3_exact_dts`, which this agrees with on every frame it accepts). */
static uint32_t mp3_cbr_header(const StreamDecoder *d) {
    MP3Frame f;
    if (!d->mp3_header_ok || d->mp3_tag == MP3_TAG_VBR || !mp3_frame_of(d->mp3_header, &f)) return 0;
    if (d->mp3_tag == MP3_TAG_NONE) return d->cb.size(d->opaque) < 0 ? 0 : d->mp3_header;
    int64_t second = d->first_pkt_pos + d->first_pkt_size;
    if (second < 0 || second + 4 > d->prologue_len) return 0;
    uint32_t h = read_be(d->prologue + second, 4);
    uint32_t mask = kMP3SameStreamMask & ~0xF000u;
    return (h & mask) == (d->mp3_header & mask) && mp3_frame_of(h, &f) ? h : 0;
}

/*
 * The frame `ts` (stream time base) falls in, in a constant-bitrate Layer III stream, found by
 * reading the few bytes where it has to be: `*pos` and `*dts` are its byte position and exact time,
 * or `*pos` is -1 when this cannot say (the caller seeks by estimate instead). Returns
 * STREAM_DECODE_OK, or the status of a cancel or an interruption.
 *
 * Frame k starts within a byte or two of `second + (k - 1) * spf * bitrate / (8 * rate)`, which is
 * the relation `mp3_exact_dts` counts frames by. mp3_seek finds a frame near a byte estimate too,
 * but first rewinds 4096 bytes before it (mp3_sync's SEEK_WINDOW) and reads them: on a stream still
 * downloading, a far seek restarts the download there and waits for all of them, a quarter of a
 * second at twice a 64 kbps bitrate, before the first byte it needs. This reads from the frame. A
 * header there, the next frame's header after it, and the count agreeing is the frame.
 */
static int mp3_cbr_frame(StreamDecoder *d, int64_t ts, int64_t *pos, int64_t *dts) {
    *pos = -1;
    MP3Frame f;
    uint32_t h = mp3_cbr_header(d);
    if (!h || !mp3_frame_of(h, &f) || d->first_pkt_dts == AV_NOPTS_VALUE || d->first_pkt_pos < 0) {
        return STREAM_DECODE_OK;
    }
    int64_t samples = av_rescale_q(ts - d->first_pkt_dts, d->time_base, (AVRational){ 1, d->sample_rate });
    int64_t index = samples / d->mp3_spf;
    if (index < 1) return STREAM_DECODE_OK;

    enum { kSlack = 4 };
    uint8_t buf[2 * kSlack + 1441 + 1 + 4];   /* the largest Layer III frame, and the next header */
    int need = 2 * kSlack + f.bytes + 1 + 4;
    if (need > (int)sizeof(buf)) return STREAM_DECODE_OK;
    int64_t second = d->first_pkt_pos + d->first_pkt_size;
    double frame_bytes = (double)f.spf * f.bitrate / (8.0 * f.sample_rate);
    int64_t lo = second + llround((double)(index - 1) * frame_bytes) - kSlack;
    if (lo < second) lo = second;

    int got = avio_seek(d->fmt->pb, lo, SEEK_SET) < 0 ? -1 : avio_read(d->fmt->pb, buf, need);
    if (got < need) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        avio_clear_latched_error(d);
        return STREAM_DECODE_OK;
    }
    for (int off = 0; off <= 2 * kSlack; off++) {
        uint32_t here = read_be(buf + off, 4);
        MP3Frame g;
        if ((here & kMP3SameStreamMask) != (h & kMP3SameStreamMask) || !mp3_frame_of(here, &g)) continue;
        if (off + g.bytes + 4 > got) continue;
        if ((read_be(buf + off + g.bytes, 4) & kMP3SameStreamMask) != (h & kMP3SameStreamMask)) continue;
        if (1 + llround((double)(lo + off - second) / frame_bytes) != index) continue;
        *pos = lo + off;
        *dts = d->first_pkt_dts + av_rescale_q(index * d->mp3_spf, (AVRational){ 1, d->sample_rate },
                                               d->time_base);
        return STREAM_DECODE_OK;
    }
    return STREAM_DECODE_OK;
}

/* Bytes one `avformat_seek_file` may read before it is judged to be walking the file. Two AVIO
 * refills: enough for a mov index landing or an mp3 TOC landing, and small enough that the walk it
 * exists to stop is cut off after a fraction of a second of audio rather than the 12 MB a single
 * seek to 25 minutes cost on the measured fixture. */
static const int64_t kSeekBudgetBytes = 64 * 1024;

/* Finish a seek: flush the codec and the resampler and clear the pull loop's state. */
static void after_seek_reset(StreamDecoder *d) {
    avcodec_flush_buffers(d->dec);
    pending_reset(d);
    av_packet_unref(d->held);
    d->has_held = 0;
    d->has_last_pkt = 0;
    d->has_first_pkt = 0;
    d->flushing = 0;
    d->ended = 0;
    d->last_frame_pts = AV_NOPTS_VALUE;
    d->discard_until = AV_NOPTS_VALUE;
    d->next_pts = AV_NOPTS_VALUE;
    d->seek_first_pts = AV_NOPTS_VALUE;
    d->mp3_watch = 0;
    d->mp3_watch_frames = 0;
    d->mp3_watch_bytes = 0;
    d->mp3_watch_next = AV_NOPTS_VALUE;
    d->mp3_preroll_short = 0;
}

/*
 * Carry on after an interrupted read, as if it had never happened (issues #3 and #7).
 *
 * A seek to the frame the next read would have returned is a resume, and an ordinary seek is the
 * wrong tool for it: it lands on a packet boundary at or before the target and flushes the codec,
 * so the resumed decode repeats or drops audio, and an MP3 loses its bit reservoir. The codec and
 * the resampler still hold exactly the state the last packet left. So the demuxer alone is put
 * back on that packet (by its own index, which an exact timestamp and AVSEEK_FLAG_ANY make
 * precise), the packet is read again and dropped, and the next one is the one the interruption
 * cost. When the codec has had nothing yet (interrupted straight after the open), the packet the
 * open read is found the same way and kept for the codec instead. Anything that does not find
 * its packet again returns an error and the caller seeks normally; an interruption or cancel is
 * returned as itself.
 */
static int resume_after_last_packet(StreamDecoder *d) {
    AVStream *st = d->fmt->streams[d->audio_idx];
    int keep = !d->has_last_pkt;
    int64_t pos = keep ? d->first_pkt_pos : d->last_pkt_pos;
    int64_t dts = keep ? d->first_pkt_dts : d->last_pkt_dts;

    /* Only an index can put the demuxer back on one packet. The generic one (mp3) holds the
     * packets already read but may have thinned them, so the entry is added back; a container's
     * own index (mov) has the sample already and must not have it rewritten. A demuxer with
     * neither (ogg) seeks by bisection, which lands on a page, not a packet. */
    /* An Ogg packet's position is its page's, shared with every packet on the page, so (pos, dts)
     * names no single packet. With a length, the seek bisects and labels packets from the pages'
     * granules, and the packet is found. Without one it goes by the index, which labels the
     * page's first packet with `dts`: the "found" packet was the page's first and the resume
     * repeated up to a page of audio. The ordinary seek lands on the sample exactly instead. */
    if (d->media_bytes <= 0 && d->fmt->iformat->name && strcmp(d->fmt->iformat->name, "ogg") == 0) {
        return STREAM_DECODE_ERR_SEEK;
    }
    int at = av_index_search_timestamp(st, dts, AVSEEK_FLAG_ANY);
    const AVIndexEntry *entry = at >= 0 ? avformat_index_get_entry(st, at) : NULL;
    if (!entry || entry->timestamp != dts) {
        if (!(d->fmt->iformat->flags & AVFMT_GENERIC_INDEX)) return STREAM_DECODE_ERR_SEEK;
        av_add_index_entry(st, pos, dts, 0, 0, AVINDEX_KEYFRAME);
    }
    /* FAST_SEEK sends mp3 to its TOC or a bitrate guess; without it, an mp3 seeks by the index. */
    int flags = d->fmt->flags;
    d->fmt->flags &= ~AVFMT_FLAG_FAST_SEEK;
    int rc = avformat_seek_file(d->fmt, d->audio_idx, dts, dts, dts, AVSEEK_FLAG_ANY);
    d->fmt->flags = flags;

    for (int i = 0; rc >= 0 && i < 64; i++) {
        rc = av_read_frame(d->fmt, d->pkt);
        if (rc < 0) break;
        int ours = d->pkt->stream_index == d->audio_idx;
        int found = ours && d->pkt->pos == pos && d->pkt->dts == dts;
        int past = ours && d->pkt->dts != AV_NOPTS_VALUE && d->pkt->dts > dts;
        if (found && keep) {
            av_packet_unref(d->held);
            av_packet_move_ref(d->held, d->pkt);
            d->has_held = 1;
            return STREAM_DECODE_OK;
        }
        av_packet_unref(d->pkt);
        if (found) return STREAM_DECODE_OK;
        if (past) break;
    }
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
    return STREAM_DECODE_ERR_SEEK;
}

/* Whether the container gives enough to place a second in the byte stream by linear estimate. */
static int can_estimate_bytes(const StreamDecoder *d) {
    return d->media_bytes > 0 && d->media_duration > 0;
}

/*
 * Clear the error `AVIOContext` latches.
 *
 * Every refusal this file makes — a cancel, an interruption, a seek that blew its byte budget —
 * reaches libavformat as a failed read, and `AVIOContext` keeps it: `error` holds the code and
 * `eof_reached` stays 1. `avio_seek` resets `eof_reached` and nothing resets `error`, so the reads
 * that follow come straight back with the OLD failure without asking the byte source for anything:
 * an interrupted decoder reported a cancel on its next seek, and a seek that fell back to the byte
 * estimate reported `STREAM_DECODE_ERR_IO` after landing correctly. A seek is precisely the point
 * at which those refusals stop being true, so it is where they are cleared.
 */
static void avio_clear_latched_error(StreamDecoder *d) {
    if (!d->avio) return;
    d->avio->error = 0;
    d->avio->eof_reached = 0;
}

static int seek_to(StreamDecoder *decoder, double seconds, double *landed_seconds);
static int demux_seek(StreamDecoder *decoder, double seconds, int64_t target, double *landed_seconds);
static int land_exactly(StreamDecoder *d, int64_t target);

/* `demux_seek`'s "the demuxer is placed, land by the timestamps" result; no STREAM_DECODE_ code. */
static const int kSeekPlaced = 1000;

/* How far before its target a seek puts the demuxer, in samples, so the codec has converged by the
 * target: an MP3's bit reservoir spans a few frames (more at a low VBR quality), and Opus's CELT
 * state takes about 30000 samples after a reset to decode bit-identically to an unbroken run.
 *
 * HE-AAC's SBR and PS headers come every so many frames, not in each, and a codec opened mid-stream
 * decodes without them until the next one arrives. An HE-AAC v2 stream from Apple's encoder decoded
 * bit-identically to an unbroken run only after more than 65536 samples at the output rate (98304
 * were enough); 131072, about 3 s, leaves a margin for an encoder that repeats them less often.
 *
 * A constant-bitrate Layer III stream gets what its reservoir can reach and no more. Every byte of
 * pre-roll is a byte a far seek on a stream still downloading waits for before it plays: 16384
 * samples is 2976 bytes at 64 kbps, which held a seek past the fetched bytes silent 186 ms longer
 * at twice the bitrate. A frame's main data starts at most 511 bytes (255 in MPEG-2 and 2.5) before
 * its own, in the frames before it, and the frame before the target has to have decoded exactly
 * for its overlap to be right. So: the frames those bytes can span, the one before the target, and
 * one of margin; 5 frames at 64 kbps. With the frame placed exactly (`mp3_cbr_frame`), one fewer
 * still decoded every conformance fixture bit-identically to an unbroken run from the target on,
 * and two fewer did not.
 *
 * That count is a first guess, from one frame. A stream with no tag frame is taken for
 * constant-bitrate on its first frame's word, and a VBR one that opens loud and goes on quiet has
 * frames carrying a third of the first one's main data where the seek lands. So every Layer III
 * pre-roll is also judged by the frames it actually feeds the codec, and placed further back when
 * they fall short (`mp3_measure_preroll`, `seek_to`). */
static int64_t seek_preroll_samples(const StreamDecoder *d) {
    if (d->sbr) return 131072;
    if (d->dec->codec_id == AV_CODEC_ID_OPUS) return 32768;
    uint32_t h = d->dec->codec_id == AV_CODEC_ID_MP3 ? mp3_cbr_header(d) : 0;
    MP3Frame f;
    if (h && mp3_frame_of(h, &f)) {
        int main_bytes = f.bytes - 4 - f.side_info_bytes - (((h >> 16) & 1) ? 0 : 2);
        int reservoir = f.lsf ? 255 : 511;
        if (main_bytes > 0) {
            int64_t samples = (int64_t)((reservoir + main_bytes - 1) / main_bytes + 2) * f.spf;
            if (samples < 16384) return samples;
        }
    }
    return 16384;
}

/* The furthest before its target an exact MP3 anchor is used from: about 1.5 s at 44.1 kHz. */
static const int64_t kMaxAnchorGapSamples = 65536;

/*
 * Whether to decode forward from an exact MP3 anchor `gap` (stream time base) before the target
 * rather than seek by estimate.
 *
 * A constant-bitrate stream lands exactly by its estimate (see `mp3_exact_dts`), so its anchors only
 * serve the first second or so. A VBR stream has no exact landing but this one (issue #3): a Xing
 * TOC places a time to 1/256 of the file and a bitrate guess worse, and mp3dec labels the frame it
 * finds there with the time asked for. Nothing in an MP3 frame says what time it is, so the only
 * true time is one counted frame by frame from a frame whose time is known. That count is taken
 * whenever it reads no more than a seek is allowed to (`kSeekBudgetBytes`), a few seconds at a
 * speech bitrate; further than that, the estimate is all there is.
 */
static int mp3_anchor_in_reach(const StreamDecoder *d, int64_t gap) {
    int64_t samples = av_rescale_q(gap, d->time_base, (AVRational){ 1, d->sample_rate });
    if (samples <= kMaxAnchorGapSamples) return 1;
    if (d->mp3_tag != MP3_TAG_VBR) return 0;
    int64_t bit_rate = d->fmt->bit_rate > 0 ? d->fmt->bit_rate
                                            : d->fmt->streams[d->audio_idx]->codecpar->bit_rate;
    if (bit_rate <= 0) return 0;
    return (double)samples / d->sample_rate * (double)bit_rate / 8.0 <= (double)kSeekBudgetBytes;
}

int stream_decoder_seek(StreamDecoder *decoder, double seconds, double *landed_seconds) {
    if (!decoder || !landed_seconds) return STREAM_DECODE_ERR_ARGS;
    int status = seek_to(decoder, seconds, landed_seconds);
    if (status == STREAM_DECODE_OK || status == STREAM_DECODE_EOF) {
        decoder->position_frames = llround(*landed_seconds * decoder->sample_rate);
    }
    return status;
}

static int seek_to(StreamDecoder *decoder, double seconds, double *landed_seconds) {
    *landed_seconds = seconds;
    if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    /* The seek IS the answer to the interruption: clearing it here, before anything reads, is what
     * makes an interrupted decoder reusable rather than dead. */
    decoder->interrupted = 0;
    avio_clear_latched_error(decoder);
    if (seconds < 0) seconds = 0;

    /* A seek to exactly where an interrupted read stopped is a resume. */
    int resumable = decoder->resumable;
    decoder->resumable = 0;
    if (resumable && (decoder->has_last_pkt || decoder->has_first_pkt)
        && llround(seconds * decoder->sample_rate) == decoder->position_frames) {
        int resumed = resume_after_last_packet(decoder);
        if (resumed == STREAM_DECODE_OK || resumed == STREAM_DECODE_ERR_CANCELLED) return resumed;
        if (resumed == STREAM_DECODE_ERR_INTERRUPTED) {
            decoder->resumable = 1;
            return resumed;
        }
        avio_clear_latched_error(decoder);
    }

    double tb = av_q2d(decoder->time_base);
    int64_t target = decoder->start_time + (int64_t)llround(seconds / (tb > 0 ? tb : 1.0));
    int64_t preroll = av_rescale_q(seek_preroll_samples(decoder),
                                   (AVRational){ 1, decoder->sample_rate }, decoder->time_base);

    /* Sample-accurate (issues #3 and #6). The demuxer is put down a pre-roll BEFORE the target and
     * the decode runs forward from there, dropping what comes before the target and cutting the
     * frame that straddles it, so the next read starts on the requested sample and the codec has
     * converged by then. A demuxer only lands on what it can find: an Ogg page start (each about a
     * second of audio here, so seeks landed up to a second early, more at the end), an MP3 frame
     * after a byte estimate, an MP4 sample. Landing early costs a little decoding; what is heard
     * starts where it was asked for. One that lands AFTER its target (an Ogg bisection with no
     * length to bound it) is placed again further back, then from the start.
     *
     * An MP3 pre-roll is placed again too when the frames it fed the codec turn out not to hold the
     * bit reservoir the frames from the target need (`mp3_measure_preroll`), which the frame count
     * `seek_preroll_samples` takes from one frame's bitrate cannot promise. Each placement goes four
     * times further back; three re-placements reach 64 times the first pre-roll, 192 frames at the
     * least, which covers frames carrying as little as 2 bytes of main data each (the least a
     * Layer III frame without a CRC carries is 3, at 8 kbps and 24 kHz in stereo). */
    int64_t back = preroll;
    for (int attempt = 0;; attempt++, back *= 4) {
        int64_t from = target - back;
        /* Never a decode from the start just to be exact: on a long file that is the whole
         * file (12 MB measured). After two re-placements the landing stands, reported as it is. */
        int last = attempt >= 2;
        int from_start = from <= decoder->start_time;
        if (from_start) from = decoder->start_time;
        int placed = demux_seek(decoder, seconds, from, landed_seconds);
        if (placed != kSeekPlaced) return placed;

        decoder->seek_from = from;
        int status = land_exactly(decoder, target);
        if (status == STREAM_DECODE_OK && !from_start && !last && decoder->seek_first_pts != AV_NOPTS_VALUE
            && decoder->seek_first_pts > target) {
            continue;
        }
        if (status == STREAM_DECODE_OK && !from_start && attempt < 3 && decoder->mp3_preroll_short) {
            continue;
        }
        if (status == STREAM_DECODE_OK && decoder->last_frame_pts != AV_NOPTS_VALUE) {
            *landed_seconds = (double)(decoder->last_frame_pts - decoder->start_time) * tb;
        } else if (status == STREAM_DECODE_EOF && decoder->landing_exact
                   && decoder->next_pts != AV_NOPTS_VALUE) {
            /* Every frame after the placement ended before the target, so the stream is over where
             * the last of them ended: exactly where an unbroken decode ends. A container's
             * duration can be shorter than its audio (an AAC's last frame runs past the edit
             * list's length), and the position would have been reported short of the end. */
            *landed_seconds = (double)(decoder->next_pts - decoder->start_time) * tb;
        } else if (status == STREAM_DECODE_EOF && decoder->media_duration > 0
                   && seconds >= decoder->media_duration - 1.0 / decoder->sample_rate) {
            /* At or past the declared end, and the stream agrees: it is over there. That length
             * (an MP3's Xing frame count, a container's duration) is exact where a VBR MP3's
             * timestamps after a TOC or bitrate estimate are not. */
            *landed_seconds = seconds < decoder->media_duration ? seconds : decoder->media_duration;
        } else if (status == STREAM_DECODE_EOF && decoder->next_pts != AV_NOPTS_VALUE
                   && decoder->next_pts < target) {
            /* The target is past the last sample: the stream is over where the audio ends. */
            *landed_seconds = (double)(decoder->next_pts - decoder->start_time) * tb;
        }
        if (*landed_seconds < 0) *landed_seconds = 0;
        return status;
    }
}

/*
 * Replace the codec with a freshly opened one.
 *
 * `avcodec_flush_buffers` does not put every codec back where opening left it: AAC's noise
 * substitution draws from a generator seeded once, in init (aacdec.c `random_state`), and flush
 * leaves it running. Two seeks to the same place then decoded differently, by the history before
 * them (a seek retried after an interruption decoded other noise than one that was not). A new
 * codec makes a seek's audio depend on nothing but where it went.
 *
 * Every AAC stream is reopened, HE-AAC included. A flushed HE-AAC codec keeps its SBR and PS state,
 * so what it decoded after a seek depended on the frames before (an ADTS HE-AAC seek retried after
 * an I/O error decoded differently from one that was not). A fresh one has no SBR or PS header
 * until the next arrives, which the longer pre-roll for SBR streams covers
 * (`seek_preroll_samples`). The other codecs' flush leaves nothing behind that matters.
 */
static int codec_outlives_flush(const StreamDecoder *d) {
    return d->dec->codec_id == AV_CODEC_ID_AAC;
}

static int reopen_codec(StreamDecoder *d) {
    AVStream *stream = d->fmt->streams[d->audio_idx];
    const AVCodec *codec = d->dec->codec;
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    if (!dec) return STREAM_DECODE_ERR_ALLOC;
    if (avcodec_parameters_to_context(dec, stream->codecpar) < 0) {
        avcodec_free_context(&dec);
        return STREAM_DECODE_ERR_DECODER;
    }
    dec->thread_count = 1;
    dec->pkt_timebase = stream->time_base;
    if (avcodec_open2(dec, codec, NULL) < 0) {
        avcodec_free_context(&dec);
        return STREAM_DECODE_ERR_DECODER;
    }
    avcodec_free_context(&d->dec);
    d->dec = dec;
    return STREAM_DECODE_OK;
}

/* Set the decoder going from where the demuxer was just put: a clean codec, the MP3 anchor, and
 * every frame before `target` dropped. Returns `pump`'s status. */
static int land_exactly(StreamDecoder *d, int64_t target) {
    int index_seek = d->anchored;
    after_seek_reset(d);
    if (codec_outlives_flush(d)) {
        int codec_rc = reopen_codec(d);
        if (codec_rc != STREAM_DECODE_OK) return codec_rc;
    }
    int swr_rc = init_swr(d);   /* drop whatever the resampler still held from before */
    if (swr_rc != STREAM_DECODE_OK) return swr_rc;
    d->landing_exact = 1;
    if (d->mp3_header_ok && !index_seek) {
        int rc;
        while ((rc = av_read_frame(d->fmt, d->held)) >= 0 && d->held->stream_index != d->audio_idx) {
            av_packet_unref(d->held);
        }
        /* Otherwise the pump reads again and meets the same end, error or interruption. */
        if (rc >= 0) d->has_held = 1;
        int64_t dts = rc >= 0 ? mp3_exact_dts(d, d->held) : AV_NOPTS_VALUE;
        d->landing_exact = dts != AV_NOPTS_VALUE;
        if (dts != AV_NOPTS_VALUE && dts != d->held->dts) {
            /* The demuxer is told the frame's real time the one way it takes one: an index entry,
             * sought to exactly. Every timestamp after it, and the encoder padding it trims at the
             * end by those timestamps, then follows from the truth. */
            AVStream *st = d->fmt->streams[d->audio_idx];
            int64_t pos = d->held->pos;
            av_packet_unref(d->held);
            d->has_held = 0;
            av_add_index_entry(st, pos, dts, 0, 0, AVINDEX_KEYFRAME);
            int flags = d->fmt->flags;
            d->fmt->flags &= ~AVFMT_FLAG_FAST_SEEK;
            rc = avformat_seek_file(d->fmt, d->audio_idx, dts, dts, dts, AVSEEK_FLAG_ANY);
            d->fmt->flags = flags;
            if (rc < 0) {
                if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
                return STREAM_DECODE_ERR_SEEK;
            }
        }
    }
    d->discard_until = target;
    d->mp3_watch = d->mp3_header_ok && d->dec->codec_id == AV_CODEC_ID_MP3;
    return pump(d);
}

/*
 * Put the demuxer at or before `target` (stream time base), within the seek byte budget.
 *
 * Returns `kSeekPlaced` when the packets that follow carry timestamps to land by, and otherwise
 * the seek's final status with `*landed_seconds` set: a byte estimate (no timestamps to land by),
 * the end of the stream, or an error. `seconds` is the caller's request, which the estimate uses.
 */
static int demux_seek(StreamDecoder *decoder, double seconds, int64_t target, double *landed_seconds) {
    /* An MP3 frame whose place and time are both known exactly is sought to directly rather than
     * by the TOC or bitrate estimate FAST_SEEK picks: the first frame (which `mp3_sync` skips when
     * an encoder cut it short, playing a seek to the start from the second), or a VBRI table
     * entry. The frame goes into the index with its time and the generic seek, which
     * AVSEEK_FLAG_ANY and an exact timestamp make go straight to it, takes the time from there.
     * Only that entry is trusted: mp3dec fills the index with its Xing TOC, a percent of the file
     * per entry, whose positions are not frames and whose times are not theirs. */
    int fmt_flags = decoder->fmt->flags;
    int64_t seek_min = INT64_MIN, seek_ts = target;
    int seek_flags = AVSEEK_FLAG_BACKWARD;
    int64_t anchor_pos = -1, anchor_dts = AV_NOPTS_VALUE;
    decoder->anchored = 0;
    if (decoder->mp3_header_ok) {
        if (!mp3_vbri_anchor(decoder, target, &anchor_pos, &anchor_dts)) {
            anchor_pos = decoder->first_pkt_pos;
            anchor_dts = decoder->first_pkt_dts;
        }
        /* An anchor far before the target (a long file's start, or a coarse table) would cost a
         * long decode to it; the estimate is cheaper. */
        if (target > decoder->start_time && !mp3_anchor_in_reach(decoder, target - anchor_dts)) {
            anchor_pos = -1;
        }
        /* Further than that, a constant-bitrate stream's frame is found where it has to be, which
         * is exact and reads nothing before it (`mp3_cbr_frame`). When it is not there (a stream
         * with no tag frame that is not constant-bitrate after all, or bytes that cannot be read),
         * the seek goes by estimate with the same short pre-roll, and lands among frames nothing
         * has measured. That pre-roll is judged by the frames it feeds the codec like any other
         * (`mp3_measure_preroll`) and placed further back when it falls short. */
        if (anchor_pos < 0) {
            int found = mp3_cbr_frame(decoder, target, &anchor_pos, &anchor_dts);
            if (found != STREAM_DECODE_OK) return found;
        }
    }
    if (anchor_pos >= 0 && anchor_dts != AV_NOPTS_VALUE) {
        av_add_index_entry(decoder->fmt->streams[decoder->audio_idx], anchor_pos, anchor_dts, 0, 0,
                           AVINDEX_KEYFRAME);
        decoder->fmt->flags &= ~AVFMT_FLAG_FAST_SEEK;
        seek_min = seek_ts = anchor_dts;
        seek_flags = AVSEEK_FLAG_ANY;
        decoder->anchored = 1;
    } else if (decoder->fmt->iformat->name && strcmp(decoder->fmt->iformat->name, "ogg") == 0) {
        /* oggdec gives every packet the position of the page it starts in, so the generic index
         * holds one entry per packet and several share a position, each with its own time. A
         * seek by the index (the Ogg fallback when there is no length to bisect) can pick one
         * from the middle of a page: it goes to the page and labels the page's FIRST packet with
         * that later time, and every packet after it follows. On most pages the Vorbis and Opus
         * parsers relabel from the page's granule and hide it; on the last page (EOS set) they do
         * not, and a seek to the end landed 25600 samples early while labelled as the target
         * (issue #6). Seeking to the earliest entry at that position labels the page truly.
         *
         * An Ogg seek also starts one page further back. The parsers trim the encoder padding
         * off the last page by the time the page before it ended; a seek straight onto the last
         * page has no such time, and decoded the padding (704 samples here) as audio.
         *
         * Only where the index reaches the target. Past its end the nearest entry is merely as far
         * as the decode has got, and seeking there instead (so decoding from it to the target)
         * walked 12 MB of a long file on one seek; the anchor gap bounds it as it does an MP3's. */
        AVStream *st = decoder->fmt->streams[decoder->audio_idx];
        int pages = 2;
        int at = av_index_search_timestamp(st, target, AVSEEK_FLAG_BACKWARD);
        const AVIndexEntry *entry = at >= 0 ? avformat_index_get_entry(st, at) : NULL;
        if (entry && av_rescale_q(target - entry->timestamp, decoder->time_base,
                                  (AVRational){ 1, decoder->sample_rate }) > kMaxAnchorGapSamples) {
            entry = NULL;
        }
        while (entry && at > 0) {
            const AVIndexEntry *before = avformat_index_get_entry(st, at - 1);
            if (!before) break;
            if (before->pos != entry->pos && --pages == 0) break;
            entry = before;
            at--;
        }
        if (entry && entry->timestamp < seek_ts) seek_ts = entry->timestamp;
    }

    /* Backward-leaning: land at or before the request so nothing between the request and the
     * landing is skipped unheard. Where it actually lands is what the caller's position becomes.
     *
     * The budget is the whole point of this call's shape. An MP3 with no Xing TOC — which is most
     * long spoken-word MP3s — has no way to place a timestamp, so libavformat's generic seek DECODES
     * FORWARD FROM THE START until the timestamps reach the target: measured at 12 MB for one seek
     * to 25 minutes, on a fixture whose whole open cost 32 KiB. It is refused here rather than
     * paid for, and the byte estimate below takes over. Everything with a real index — every mp4,
     * an mp3 with a TOC — lands well inside the budget and never reaches the fallback. */
    decoder->seek_bytes = 0;
    decoder->seek_budget = decoder->seek_budget_override > 0 ? decoder->seek_budget_override
                                                             : kSeekBudgetBytes;
    decoder->seek_budget_blown = 0;
    decoder->seek_budget_armed = 1;
    decoder->source_eof = 0;
    int rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, seek_min, seek_ts, seek_ts,
                                seek_flags);
    int walked = decoder->seek_budget_blown;
    decoder->seek_budget_armed = 0;
    decoder->fmt->flags = fmt_flags;

    /* The refusal that abandoned the walk is latched in the AVIO context; the fallback below has
     * to read, so clear it here rather than after the seek that would already have failed. */
    if (walked) avio_clear_latched_error(decoder);

    if (rc < 0 || walked) {
        if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        /* An interrupted seek is retried by the caller, and has to land where the uninterrupted
         * one would: the byte estimate would land somewhere else (issue #5). */
        if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        if (!can_estimate_bytes(decoder)) {
            /* Nothing to estimate FROM: a source with no length and no container duration, which
             * over HTTP is a chunked response. The walk is then the only seek there is, so it is
             * paid for rather than refused — an expensive seek beats a seek that fails.
             *
             * A seek past the last frame comes back as end of file (mp3_seek places it and finds
             * no frame to sync to). The stream is over there, which is the answer the byte
             * estimate gives a source that has a length. Only when the READER said so, though: a
             * broken read comes back as end of file too, and a truncated chunked body is not the
             * end of the stream. */
            if (!walked && rc == AVERROR_EOF && decoder->source_eof) {
                after_seek_reset(decoder);
                decoder->ended = 1;
                if (decoder->media_duration > 0 && seconds > decoder->media_duration) {
                    *landed_seconds = decoder->media_duration;
                }
                return STREAM_DECODE_EOF;
            }
            if (!walked) return STREAM_DECODE_ERR_SEEK;
            decoder->anchored = 0;
            rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, target, target,
                                    AVSEEK_FLAG_BACKWARD);
            if (rc < 0) {
                if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                return STREAM_DECODE_ERR_SEEK;
            }
            return kSeekPlaced;
        }
        decoder->anchored = 0;

        /* The byte estimate. Exact for CBR, which is what a container with neither an index nor a
         * TOC almost always is; a VBR file that reaches here lands within its own bitrate swing,
         * and the caller's clock is anchored to what is REPORTED, not to what was asked for. */
        double ratio = seconds / decoder->media_duration;
        if (ratio < 0) ratio = 0;
        if (ratio > 1) ratio = 1;
        int64_t byte = (int64_t)(ratio * (double)decoder->media_bytes);
        rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, byte, byte,
                                AVSEEK_FLAG_BYTE | AVSEEK_FLAG_BACKWARD);
        if (rc < 0) {
            if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
            return STREAM_DECODE_ERR_SEEK;
        }
        after_seek_reset(decoder);
        int swr_rc = init_swr(decoder);
        if (swr_rc != STREAM_DECODE_OK) return swr_rc;

        /* Decode to the first frame so the caller gets audio, not an empty buffer. A byte seek
         * leaves the demuxer with no timestamp to report — there is nothing in the stream that
         * says what second this frame is — so the estimate IS the landed time. */
        int status = pump(decoder);
        *landed_seconds = ratio * decoder->media_duration;
        return status;
    }
    return kSeekPlaced;
}

int stream_decoder_read(StreamDecoder *decoder, float *out, int max_frames, int *frames) {
    if (!decoder || !out || !frames || max_frames <= 0) return STREAM_DECODE_ERR_ARGS;
    *frames = 0;
    int channels = decoder->channels;
    int written = 0;
    int status = STREAM_DECODE_OK;

    while (written < max_frames) {
        int available = decoder->pending_frames - decoder->pending_offset;
        if (available <= 0) {
            status = pump(decoder);
            if (status != STREAM_DECODE_OK) break;
            available = decoder->pending_frames - decoder->pending_offset;
            if (available <= 0) { status = STREAM_DECODE_EOF; break; }
        }
        int take = available < (max_frames - written) ? available : (max_frames - written);
        memcpy(out + (size_t)written * channels,
               decoder->pending + (size_t)decoder->pending_offset * channels,
               (size_t)take * channels * sizeof(float));
        decoder->pending_offset += take;
        written += take;
    }

    *frames = written;
    decoder->position_frames += written;
    if (status == STREAM_DECODE_ERR_INTERRUPTED) decoder->resumable = 1;
    /* Frames in hand beat the reason the loop stopped: the caller plays these and asks again, and
     * the next call reports the same end for the same reason. */
    return written > 0 ? STREAM_DECODE_OK : status;
}

int64_t stream_decoder_position_bytes(const StreamDecoder *decoder) {
    return decoder ? decoder->bytes_read : 0;
}

void stream_decoder_set_seek_budget_bytes(StreamDecoder *decoder, int64_t bytes) {
    if (!decoder) return;
    decoder->seek_budget_override = bytes;
}

void stream_decoder_drop_timestamps_for_testing(StreamDecoder *decoder) {
    if (decoder) decoder->drop_timestamps = 1;
}

void stream_decoder_cancel(StreamDecoder *decoder) {
    if (decoder) decoder->cancelled = 1;
}

void stream_decoder_interrupt(StreamDecoder *decoder) {
    if (decoder) decoder->interrupted = 1;
}

void stream_decoder_clear_interrupt(StreamDecoder *decoder) {
    if (decoder) decoder->interrupted = 0;
}

void stream_decoder_close(StreamDecoder *decoder) {
    if (!decoder) return;
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->pkt);
    av_packet_free(&decoder->held);
    swr_free(&decoder->swr);
    avcodec_free_context(&decoder->dec);
    close_format(decoder);
    free(decoder->pending);
    free(decoder);
}
