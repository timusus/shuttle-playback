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
#include <libavutil/crc.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

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
    int         decode_errors;    /* consecutive `avcodec_receive_frame` errors, see `pump` */
    int64_t     end_pts;          /* MP4: where the edit list ends the audio (stream time base), else NOPTS */
    int         prime_skip;       /* MP4 AAC: encoder priming to drop when the file's own edit list does not (issue #25), else 0 */
    int64_t     prime_start;      /* the timestamp of the packet that carries it */
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
    int          mp3_untagged_cbr;    /* no tag frame, and the frames in `prologue` all share a bitrate */
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
    /* Native FLAC only: where the first frame starts (AVIO offset), once `flac_audio_start` has
     * found it; 0 until then. */
    int64_t      flac_audio_pos;
    /* Set by `demux_seek` when a FLAC seek's target was beyond reach of the nearest frame it found
     * before it: the decode runs on from that frame, at this time (stream time base), rather than
     * dropping up to the target. AV_NOPTS_VALUE otherwise. */
    int64_t      flac_short_at;

    /* The first bytes of the media as libavformat read them (offset 0 is `base_offset`), kept so
     * the Xing/Info/VBRI frame can be read without a second request. */
    uint8_t      prologue[4096];
    int          prologue_len;
    int64_t      io_pos;             /* libavformat's read position */
    int64_t      contiguous_read;    /* the end of the run of bytes read from offset 0, past any seeks */

    /* A one-frame MP3 shown to libavformat with a copy of its frame behind it (see
     * `reopen_single_frame_mp3`): `phantom_len` bytes at AVIO offset `phantom_at`. */
    uint8_t      phantom[1792];
    int          phantom_len;
    int64_t      phantom_at;
    int          phantom_samples;    /* the real frame's samples per channel */
};

enum { MP3_TAG_NONE = 0, MP3_TAG_INFO, MP3_TAG_VBR };

/* ── AVIO glue ───────────────────────────────────────────────────────────── */

static int avio_read_packet(void *opaque, uint8_t *buf, int buf_size) {
    StreamDecoder *d = (StreamDecoder *)opaque;
    if (d->cancelled || d->interrupted) return AVERROR_EXIT;
    if (d->phantom_len && d->io_pos >= d->phantom_at) {
        int64_t off = d->io_pos - d->phantom_at;
        if (off >= d->phantom_len) return AVERROR_EOF;
        int n = d->phantom_len - (int)off < buf_size ? d->phantom_len - (int)off : buf_size;
        memcpy(buf, d->phantom + off, (size_t)n);
        d->io_pos += n;
        return n;
    }
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
        if (d->io_pos <= d->contiguous_read && d->io_pos + n > d->contiguous_read) d->contiguous_read = d->io_pos + n;
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

static int mp3_parse_header(const uint8_t *p, int *spf, int *bitrate, int *sample_rate,
                            int *side_info_bytes);

/*
 * Where the audio ends (AVIO offset) when the Xing/Info frame at the head of the prologue declares
 * a stream much shorter than the file, 0 when it does not (issue #50). mp3dec reads that as a
 * concatenated file, drops the tag's frame count and with it the gapless end trim and the duration
 * (mp3_parse_info_tag: "invalid concatenated file detected - using bitrate for duration", which
 * is when the file exceeds the declared bytes by more than 1/16). media3 trusts the tag
 * (XingSeeker.create only logs a size mismatch), so libavformat is shown a file that ends where
 * the tag says the audio does, and the trailing bytes stay unread junk after the last frame.
 */
static int64_t mp3_declared_end(const StreamDecoder *d, int64_t size) {
    int spf, br, sr, side;
    int64_t limit = d->prologue_len - 4 < 2048 ? d->prologue_len - 4 : 2048;
    for (int64_t p = 0; p <= limit; p++) {
        if (!mp3_parse_header(d->prologue + p, &spf, &br, &sr, &side)) continue;
        int64_t x = p + 4 + side;
        if (x + 16 > d->prologue_len || (memcmp(d->prologue + x, "Info", 4) && memcmp(d->prologue + x, "Xing", 4))) {
            return 0;   /* the first frame is the one a tag would be in */
        }
        uint32_t flags = ((uint32_t)d->prologue[x + 4] << 24) | ((uint32_t)d->prologue[x + 5] << 16)
                       | ((uint32_t)d->prologue[x + 6] << 8) | d->prologue[x + 7];
        int64_t bytes = (int64_t)(((uint32_t)d->prologue[x + 12] << 24) | ((uint32_t)d->prologue[x + 13] << 16)
                                | ((uint32_t)d->prologue[x + 14] << 8) | d->prologue[x + 15]);
        if ((flags & 3) != 3 || bytes <= 0) return 0;
        /* A count that cannot even hold the tag frame, or that runs past the file, is corrupt. */
        int64_t frame_len = (int64_t)spf / 8 * br / sr;
        if (bytes < p + frame_len || (size > 0 && bytes > size)) return 0;
        int64_t excess = size - p - bytes;
        return excess > bytes >> 4 ? p + bytes : 0;
    }
    return 0;
}

/* The size libavformat is told (AVIO offsets): the source's less the ID3v2 tag stepped over, ended
 * where an Info/Xing frame says the audio does (see `mp3_declared_end`), and with a one-frame file's
 * `phantom_len` appended. Negative when the source has no length. */
static int64_t avio_size_seen(const StreamDecoder *d) {
    int64_t size = d->cb.size(d->opaque);
    if (size < 0) return size;
    size -= d->base_offset;
    int64_t end = mp3_declared_end(d, size);
    return (end > 0 ? end : size) + d->phantom_len;
}

static int64_t avio_seek_packet(void *opaque, int64_t offset, int whence) {
    StreamDecoder *d = (StreamDecoder *)opaque;
    if (d->cancelled || d->interrupted) return AVERROR_EXIT;

    if (whence == AVSEEK_SIZE) {
        int64_t size = avio_size_seen(d);
        /* ENOSYS is the documented "I do not know", and it is the ONLY honest answer for a source
         * with no length: a made-up size sends the mov demuxer seeking past the end. */
        return size >= 0 ? size : AVERROR(ENOSYS);
    }

    int64_t target;
    switch (whence) {
        case SEEK_SET: target = offset; break;
        case SEEK_CUR: target = -1; break;   /* resolved below */
        case SEEK_END: {
            int64_t size = avio_size_seen(d);
            if (size < 0) return AVERROR(ENOSYS);
            target = size + offset;
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
    if (d->phantom_len && target >= d->phantom_at) {   /* the source has nothing there to seek to */
        d->io_pos = target;
        return target;
    }

    int rc = d->cb.seek(d->opaque, target + d->base_offset);
    if (rc == 0) { d->source_eof = 0; d->io_pos = target; return target; }
    switch (rc) {
        case STREAM_READ_CANCELLED:   d->cancelled = 1; return AVERROR_EXIT;
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return AVERROR_EXIT;
        case STREAM_READ_UNSEEKABLE:  d->unseekable = 1; return AVERROR(ESPIPE);
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

/* Float32 interleaved out at `out_rate` and `out_channels`. By default those are the source's, and
 * the resampler is here ONLY to interleave and to convert whatever sample format the codec produces
 * (mp3float is planar float, aac is planar float, and a fixed-point build would be planar s16) into
 * the one buffer format the player schedules. After `stream_decoder_set_output` it also resamples
 * and remixes to the player's fixed format. */
static int init_swr_from(StreamDecoder *d, int in_rate, int in_fmt, const AVChannelLayout *src) {
    swr_free(&d->swr);

    AVChannelLayout out_layout = { 0 };
    /* Zero-initialised: av_channel_layout_copy uninitialises its destination first, so a free() of
     * stack garbage is an intermittent SIGABRT. */
    AVChannelLayout in_layout = { 0 };
    if (src->nb_channels > 0) {
        av_channel_layout_copy(&in_layout, src);
    } else {
        av_channel_layout_default(&in_layout, d->channels > 0 ? d->channels : 1);
    }
    /* The output keeps the channel count it was set to (the stream's own, unless the caller fixed
     * one); an input with another count is remixed to it by the resampler. */
    if (d->out_channels > 0 && in_layout.nb_channels != d->out_channels) {
        av_channel_layout_default(&out_layout, d->out_channels);
    } else {
        av_channel_layout_copy(&out_layout, &in_layout);
    }
    int in_channels = in_layout.nb_channels;
    int out_channels = out_layout.nb_channels;

    int rc = swr_alloc_set_opts2(&d->swr,
                                 &out_layout, AV_SAMPLE_FMT_FLT, d->out_rate,
                                 &in_layout, in_fmt, in_rate,
                                 0, NULL);
    d->swr_in_rate = in_rate;
    d->swr_in_fmt = in_fmt;
    av_channel_layout_uninit(&d->swr_in_layout);
    av_channel_layout_copy(&d->swr_in_layout, &in_layout);
    av_channel_layout_uninit(&in_layout);
    av_channel_layout_uninit(&out_layout);
    if (rc < 0 || !d->swr) return STREAM_DECODE_ERR_RESAMPLE;
    /* Mono is FC, which swresample spreads to FL/FR at -3 dB (hard-coded for a mono source, so
     * `center_mix_level` does not reach it). Mono on a stereo output plays as loud on each side as
     * it was on its one channel, so the matrix is given explicitly. Every other remix (5.1 to
     * stereo, stereo to mono) is swresample's default matrix. The matrix array is 8 wide, so a
     * mono source spread over more than 8 channels keeps swresample's default. */
    if (in_channels == 1 && out_channels > 1 && out_channels <= 8) {
        double matrix[8];
        for (int i = 0; i < out_channels; i++) matrix[i] = 1.0;
        if (swr_set_matrix(d->swr, matrix, 1) < 0) return STREAM_DECODE_ERR_RESAMPLE;
    }
    if (swr_init(d->swr) < 0) return STREAM_DECODE_ERR_RESAMPLE;
    return STREAM_DECODE_OK;
}

static int init_swr(StreamDecoder *d) {
    return init_swr_from(d, d->dec->sample_rate, d->dec->sample_fmt, &d->dec->ch_layout);
}

static int pending_reserve(StreamDecoder *d, int frames) {
    int need = (d->pending_frames + frames) * d->out_channels;
    if (need <= d->pending_cap_floats) return 1;
    int cap = d->pending_cap_floats ? d->pending_cap_floats : 8192 * d->out_channels;
    while (cap < need) cap *= 2;
    float *nb = (float *)realloc(d->pending, (size_t)cap * sizeof(float));
    if (!nb) return 0;
    d->pending = nb;
    d->pending_cap_floats = cap;
    return 1;
}

/* Push `frame` (NULL flushes) through the resampler into `pending`. Returns 0 on allocation
 * failure, 1 otherwise; `pending_frames` says how much arrived. */
static int convert_through_swr(StreamDecoder *d, AVFrame *frame);

/* `frame` through the resampler, reconfiguring it first when the frame's input format differs.
 * `lead` receives how many pending frames precede this frame's own output: what the old resampler
 * flushed. Returns a status. */
static int push_through_swr(StreamDecoder *d, AVFrame *frame, int *lead) {
    *lead = 0;
    if (frame && (frame->sample_rate != d->swr_in_rate
                  || frame->format != d->swr_in_fmt
                  || av_channel_layout_compare(&frame->ch_layout, &d->swr_in_layout) != 0)
        && frame->sample_rate > 0 && frame->ch_layout.nb_channels > 0) {
        /* The stream changed rate, layout or sample format mid-way (stitched audio): hand out
         * what the old resampler still holds, then take the new input to the unchanged output. */
        if (!convert_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
        *lead = d->pending_frames;
        int rc = init_swr_from(d, frame->sample_rate, frame->format, &frame->ch_layout);
        if (rc != STREAM_DECODE_OK) return rc;
    }
    return convert_through_swr(d, frame) ? STREAM_DECODE_OK : STREAM_DECODE_ERR_ALLOC;
}

static int convert_through_swr(StreamDecoder *d, AVFrame *frame) {
    int in_samples = frame ? frame->nb_samples : 0;
    int out_samples = swr_get_out_samples(d->swr, in_samples);
    if (out_samples <= 0) return 1;
    if (!pending_reserve(d, out_samples)) return 0;

    uint8_t *out = (uint8_t *)(d->pending + (size_t)d->pending_frames * d->out_channels);
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

static void hold_first_packet(StreamDecoder *d);

static uint32_t box_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

/* The next child box of the box body [*pos, end): its type, and body [*body, *body_end). */
static int box_next(const uint8_t *buf, size_t end, size_t *pos, uint32_t *type,
                    size_t *body, size_t *body_end) {
    if (end - *pos < 8) return 0;
    uint64_t size = box_be32(buf + *pos);
    size_t head = 8;
    *type = box_be32(buf + *pos + 4);
    if (size == 1) {
        if (end - *pos < 16) return 0;
        size = ((uint64_t)box_be32(buf + *pos + 8) << 32) | box_be32(buf + *pos + 12);
        head = 16;
    } else if (size == 0) {
        size = end - *pos;
    }
    if (size < head || size > end - *pos) return 0;
    *body = *pos + head;
    *body_end = *pos + (size_t)size;
    *pos = *body_end;
    return 1;
}

#define BOX4(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

/*
 * Is this a fragmented MP4 (a `mvex` in the `moov`) whose audio `trak` has no edit list? Only then
 * is the missing priming skip the file's silence about it (issue #25): in a progressive file an
 * edit list with media_time 0 is the encoder saying "no priming", and FFmpeg's public API cannot
 * tell that from no edit list at all. The answer comes from walking the box tree: moov, then each
 * trak's mdia/hdlr for the first 'soun' and its edts/elst. The bytes are the ones the demuxer has
 * already read, the leading `prologue` kept for MP3 framing, so this costs no I/O; a moov that
 * does not fit in it, or sits after the first mdat or moof, answers no (a fragmented file's moov
 * leads its first moof).
 */
static int mp4_fragmented_audio_without_elst(const StreamDecoder *d) {
    const uint8_t *buf = d->prologue;
    size_t len = (size_t)d->prologue_len;
    size_t top = 0, moov, moov_end;
    uint32_t type;

    for (;;) {
        size_t start = top;
        if (!box_next(buf, len, &top, &type, &moov, &moov_end)) return 0;
        /* A moov sized 0 ("to the end of the file") would end at the prologue's end here, and an
         * elst past it would go unseen: no answer, no trim. */
        if (type == BOX4('m', 'o', 'o', 'v')) {
            if (box_be32(buf + start) == 0) return 0;
            break;
        }
        if (type == BOX4('m', 'd', 'a', 't') || type == BOX4('m', 'o', 'o', 'f')) return 0;
    }

    int fragmented = 0, audio_found = 0, audio_has_elst = 0;
    size_t pos = moov, body, body_end;
    uint32_t t;
    while (box_next(buf, moov_end, &pos, &t, &body, &body_end)) {
        if (t == BOX4('m', 'v', 'e', 'x')) fragmented = 1;
        if (t != BOX4('t', 'r', 'a', 'k') || audio_found) continue;
        int soun = 0, elst = 0;
        size_t tp = body, tb, te;
        uint32_t tt;
        while (box_next(buf, body_end, &tp, &tt, &tb, &te)) {
            if (tt == BOX4('e', 'd', 't', 's')) {
                size_t ep = tb, eb, ee;
                uint32_t et;
                while (box_next(buf, te, &ep, &et, &eb, &ee)) {
                    if (et == BOX4('e', 'l', 's', 't')) elst = 1;
                }
            } else if (tt == BOX4('m', 'd', 'i', 'a')) {
                size_t mp = tb, mb, me;
                uint32_t mt;
                while (box_next(buf, te, &mp, &mt, &mb, &me)) {
                    /* hdlr: version/flags, pre_defined, handler_type */
                    if (mt == BOX4('h', 'd', 'l', 'r') && me - mb >= 12 &&
                        box_be32(buf + mb + 8) == BOX4('s', 'o', 'u', 'n')) soun = 1;
                }
            }
        }
        if (soun) { audio_found = 1; audio_has_elst = elst; }
    }
    return fragmented && audio_found && !audio_has_elst;
}

/*
 * Encoder priming to drop from an MP4 AAC stream, for the packets whose edit list does not (issue
 * #25). The mov demuxer turns an edit list into skip-samples side data on the first packet; a
 * fragmented file has none, and FFmpeg then plays the encoder's priming as audio, a beat of
 * silence or a smeared start. The count is, in order: the file's iTunSMPB atom, the codec's
 * reported initial padding, else the 1024 samples that are the least any AAC-LC encoder's first
 * frame holds (the MDCT overlap of a frame with nothing before it). An SBR stream is left alone:
 * its priming is in core samples and no file says how many.
 */
static int mp4_aac_prime_skip(const StreamDecoder *d, const AVCodecParameters *par) {
    if (par->codec_id != AV_CODEC_ID_AAC || is_sbr(par->codec_id, par->profile)) return 0;
    if (!d->fmt->iformat || !d->fmt->iformat->name || !strstr(d->fmt->iformat->name, "mov")) return 0;
    if (!mp4_fragmented_audio_without_elst(d)) return 0;
    const AVDictionaryEntry *smpb = av_dict_get(d->fmt->metadata, "iTunSMPB", NULL, 0);
    if (smpb && smpb->value) {
        /* " 00000000 00000840 000001CA 0000000000...": padding, priming, end padding, length.
         * FFmpeg's mov demuxer takes 0 < priming < 16384 itself, and sets skip-samples from it,
         * so this only matters for out-of-range values, which are not believed. */
        unsigned f0, priming;
        if (sscanf(smpb->value, " %x %x", &f0, &priming) == 2 && priming > 0 && priming < 16384) {
            return (int)priming;
        }
    }
    if (par->initial_padding > 0) return par->initial_padding;
    return 1024;
}

static int is_mpeg_audio(enum AVCodecID codec_id) {
    return codec_id == AV_CODEC_ID_MP3 || codec_id == AV_CODEC_ID_MP2 || codec_id == AV_CODEC_ID_MP1;
}

static void mp3_measure_preroll(StreamDecoder *d, const AVPacket *pkt);
static int reopen_codec(StreamDecoder *d);

/* The demuxer has given the stream new parameters the open codec has not seen: the next link of a
 * chained Ogg Opus file (#49). FFmpeg 7.1's Ogg demuxer writes the new link's OpusHead (channel
 * count, mapping) to `codecpar` and nothing passes it to the codec, which would decode a stereo
 * link after a mono one as its mono downmix. A chained Vorbis link carries its headers in-band,
 * which the Vorbis decoder reads itself. Opus only: the LATM decoder rewrites its own extradata. */
static int codec_parameters_changed(const StreamDecoder *d) {
    if (d->dec->codec_id != AV_CODEC_ID_OPUS) return 0;
    const AVCodecParameters *par = d->fmt->streams[d->audio_idx]->codecpar;
    return par->extradata_size != d->dec->extradata_size
        || (par->extradata_size > 0 && memcmp(par->extradata, d->dec->extradata, par->extradata_size) != 0);
}

/* About 0.8 s of MP3 or 0.7 s of AAC: more than any real burst of damage, little enough that a
 * stream of nothing but garbage gives up promptly. */
#define MAX_CONSECUTIVE_DECODE_ERRORS 32

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
    /* Output frames still to drop before the seek target, when the frame it fell in came out of
     * the resampler shorter than the cut (a resampler holds the last few samples back). */
    int64_t skip = 0;

    for (;;) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        /* Harmless while a reopen drains the codec: nothing reads the source then. */
        if (d->interrupted && !d->reopening) return STREAM_DECODE_ERR_INTERRUPTED;

        int rc = avcodec_receive_frame(d->dec, d->frame);
        if (rc == 0) {
            d->decode_errors = 0;
            if (is_sbr(d->dec->codec_id, d->dec->profile)) d->sbr = 1;
            if (is_mpeg_audio(d->dec->codec_id) && d->dec->sample_rate > 0) {
                /* FFmpeg's MPEG audio decoder takes the frame's buffer, and with it the frame's
                 * rate, before it updates the codec's rate from the frame it is decoding, so the
                 * first frame after a rate change (stitched MP3s) is labelled with the old rate.
                 * The codec's rate, read after the decode, is the frame's own. */
                d->frame->sample_rate = d->dec->sample_rate;
            }
            /* The rate this frame came out at: for HE-AAC that is the SBR rate, twice the core
             * rate an implicitly signalled stream's header gives. */
            int rate = d->frame->sample_rate > 0 ? d->frame->sample_rate : d->sample_rate;
            /* Where this frame starts: its timestamp, or, for a frame with none, where the one
             * before it ended. */
            int64_t pts = d->frame->best_effort_timestamp;
            if (pts == AV_NOPTS_VALUE) pts = d->next_pts;
            int pts_guessed = 0;   /* `pts` is the seek's start, not something the stream said */
            if (pts == AV_NOPTS_VALUE && d->discard_until != AV_NOPTS_VALUE) {
                pts_guessed = 1;
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
            /* Clamp before the seek discard below, or skipped final frames are never clamped and a
             * seek past the end lands beyond the clipped end. */
            if (d->end_pts != AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE && !pts_guessed
                && d->next_pts > d->end_pts)
                d->next_pts = d->end_pts;   /* where the audio ends */
            int64_t cut = 0;
            int landing = 0;   /* this is the frame the seek target falls in */
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
                    landing = 1;
                }
            }
            if (d->end_pts != AV_NOPTS_VALUE && pts != AV_NOPTS_VALUE && !pts_guessed) {
                int64_t room = av_rescale_q(d->end_pts - pts, d->time_base,
                                            (AVRational){ 1, rate });
                if (room <= cut) {   /* wholly past the edit list's end */
                    av_frame_unref(d->frame);
                    continue;
                }
                if (room < d->frame->nb_samples) d->frame->nb_samples = (int)room;
            }
            d->last_frame_pts = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE
                : pts + av_rescale_q(cut, (AVRational){ 1, rate }, d->time_base);
            int lead = 0;
            int ok = push_through_swr(d, d->frame, &lead);
            av_frame_unref(d->frame);
            if (ok != STREAM_DECODE_OK) return ok;
            /* Same rate in and out, so the resampler holds nothing back: frame sample N is
             * pending frame N. At another rate (a mid-stream change, or a fixed output format) it
             * is the same instant at the output rate, behind whatever the old resampler flushed
             * when the rate changed, which is kept: it is the end of the audio before this frame,
             * unless the seek target is in this frame. */
            if (landing) {
                skip += lead + (rate == d->out_rate ? cut
                    : av_rescale_q(cut, (AVRational){ 1, rate }, (AVRational){ 1, d->out_rate }));
            }
            d->pending_offset = skip < d->pending_frames ? (int)skip : d->pending_frames;
            skip -= d->pending_offset;
            if (d->pending_frames > d->pending_offset) return STREAM_DECODE_OK;
            pending_reset(d);
            continue;   /* the resampler is still filling; ask for another frame */
        }
        if (rc == AVERROR_EOF && d->reopening) {
            /* The old link is drained: the held packet goes to a codec opened on the new one. The
             * resampler follows its frames' new layout (`push_through_swr`). The demuxer sets only
             * the new link's channel count, leaving the old link's mask (mono with 2 channels),
             * which the codec refuses: the count is kept, and the codec reads its layout from the
             * OpusHead. */
            AVChannelLayout *layout = &d->fmt->streams[d->audio_idx]->codecpar->ch_layout;
            if (!av_channel_layout_check(layout)) {
                int channels = layout->nb_channels;
                av_channel_layout_uninit(layout);
                layout->order = AV_CHANNEL_ORDER_UNSPEC;
                layout->nb_channels = channels;
            }
            int codec_rc = reopen_codec(d);
            if (codec_rc != STREAM_DECODE_OK) return codec_rc;
            d->flushing = 0;
            continue;
        }
        if (rc == AVERROR_EOF) {
            /* The decoder is drained; whatever libswresample still holds is the last of it. */
            if (!convert_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
            d->ended = 1;
            return d->pending_frames > 0 ? STREAM_DECODE_OK : STREAM_DECODE_EOF;
        }
        if (rc != AVERROR(EAGAIN)) {
            /* A frame the codec cannot decode is a glitch, not the end of the recording: skip it
             * like a rejected packet. Out of memory is not the stream's fault, and a run of
             * MAX_CONSECUTIVE_DECODE_ERRORS failures with no good frame between is garbage, not
             * damage, so that ends with an error rather than spinning to the end of the file. */
            if (rc == AVERROR(ENOMEM)) return STREAM_DECODE_ERR_ALLOC;
            if (++d->decode_errors > MAX_CONSECUTIVE_DECODE_ERRORS) return STREAM_DECODE_ERR_DECODER;
            continue;
        }

        if (d->flushing) {
            /* EAGAIN after a NULL packet cannot happen, but treat it as the end rather than
             * looping: an unbounded loop here is a hung player. */
            if (!convert_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
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
        if (d->prime_skip > 0 && d->pkt->pts == d->prime_start) {
            /* The first packet of an MP4 AAC stream whose edit list did not say to skip anything
             * (a fragmented file has none): the decoder's own skip-samples mechanism drops the
             * priming, as it does for an edit list. */
            uint8_t *sd = av_packet_new_side_data(d->pkt, AV_PKT_DATA_SKIP_SAMPLES, 10);
            if (sd) {
                memset(sd, 0, 10);   /* little-endian skip at the start, skip at the end, reasons */
                for (int i = 0; i < 4; i++) sd[i] = (uint8_t)((uint32_t)d->prime_skip >> (8 * i));
            }
        }
        if (!d->reopening && codec_parameters_changed(d)) {
            /* Drain the old codec first (Opus holds back resampled SILK samples), then reopen. */
            av_packet_move_ref(d->held, d->pkt);
            d->has_held = 1;
            d->reopening = 1;
            avcodec_send_packet(d->dec, NULL);
            d->flushing = 1;
            continue;
        }
        d->reopening = 0;
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
static int  reopen_past_mp3_junk(StreamDecoder *d, const StreamDecodeOptions *options, int failed);
static int  reopen_single_frame_mp3(StreamDecoder *d, const StreamDecodeOptions *options, int failed);

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
    d->end_pts = AV_NOPTS_VALUE;
    d->last_frame_pts = AV_NOPTS_VALUE;
    d->discard_until = AV_NOPTS_VALUE;
    d->next_pts = AV_NOPTS_VALUE;
    d->seek_first_pts = AV_NOPTS_VALUE;
    d->seek_from = AV_NOPTS_VALUE;
    d->flac_short_at = AV_NOPTS_VALUE;

    /* Before anything reads: hide the ID3v2 tag, which on a real published MP3 is megabytes of
     * cover art that libavformat would otherwise consume in full. */
    d->base_offset = probe_id3_offset(d);
    if (d->cancelled) { local_status = STREAM_DECODE_ERR_CANCELLED; goto fail; }
    if (d->interrupted) { local_status = STREAM_DECODE_ERR_INTERRUPTED; goto fail; }

    local_status = open_format(d, options);
    if (local_status == STREAM_DECODE_ERR_NO_AUDIO || local_status == STREAM_DECODE_ERR_OPEN) {
        local_status = reopen_past_mp3_junk(d, options, local_status);
        if (local_status == STREAM_DECODE_ERR_NO_AUDIO || local_status == STREAM_DECODE_ERR_OPEN) {
            local_status = reopen_single_frame_mp3(d, options, local_status);
        }
    }
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
    d->out_rate = d->sample_rate;
    d->out_channels = d->channels;
    d->sbr = is_sbr(par->codec_id, par->profile);
    d->time_base = stream->time_base;
    d->start_time = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
    /* The mov demuxer trims the edit list's start (skip-samples side data) but leaves the codec's
     * last frame whole, so the decode runs up to a frame past the duration the edit list declares
     * (issue #13). AVAssetReader stops at that duration; so do we. */
    if (d->fmt->iformat && d->fmt->iformat->name && strstr(d->fmt->iformat->name, "mov") &&
        stream->duration != AV_NOPTS_VALUE && stream->duration > 0) {
        d->end_pts = d->start_time + stream->duration;
    }
    if (d->phantom_len) {   /* the audio ends where the real frame does, not the copy behind it */
        d->end_pts = d->start_time + av_rescale_q(d->phantom_samples, (AVRational){ 1, par->sample_rate },
                                                  stream->time_base);
    }
    d->prime_skip = mp4_aac_prime_skip(d, par);
    if (d->prime_skip > 0) {
        /* Does the file's edit list already skip its priming? It shows as skip-samples side data
         * on the first packet, which is kept for the decoder. If not, the audio starts after the
         * priming, so that is where time zero is. */
        int rc;
        while ((rc = av_read_frame(d->fmt, d->held)) >= 0 && d->held->stream_index != d->audio_idx) {
            av_packet_unref(d->held);
        }
        if (rc < 0) {
            if (d->cancelled) { local_status = STREAM_DECODE_ERR_CANCELLED; goto fail; }
            if (d->interrupted) { local_status = STREAM_DECODE_ERR_INTERRUPTED; goto fail; }
            avio_clear_latched_error(d);
            d->prime_skip = 0;
        } else {
            hold_first_packet(d);
            if (av_packet_get_side_data(d->held, AV_PKT_DATA_SKIP_SAMPLES, NULL) ||
                d->held->pts != d->start_time) {
                d->prime_skip = 0;
            } else {
                d->prime_start = d->held->pts;
                d->start_time +=av_rescale_q(d->prime_skip, (AVRational){ 1, d->sample_rate },
                                              d->time_base);
            }
        }
    }

    local_status = init_swr(d);
    if (local_status != STREAM_DECODE_OK) goto fail;

    d->frame = av_frame_alloc();
    if (!d->frame) { local_status = STREAM_DECODE_ERR_ALLOC; goto fail; }

    info->sample_rate = d->sample_rate;
    info->channel_count = d->channels;
    info->skipped_probe = d->skipped_probe;
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
    if (d->phantom_len) info->duration_sec = (double)d->phantom_samples / (double)d->sample_rate;
    if (d->prime_skip > 0 && info->duration_sec > 0) {
        info->duration_sec -= (double)d->prime_skip / (double)d->sample_rate;   /* the priming is not audio */
        if (info->duration_sec < 0) info->duration_sec = 0;
    }
    /* Kept for the byte-estimate seek: what the media occupies in bytes and how long it lasts. */
    {
        int64_t seen = avio_size_seen(d) - d->phantom_len;
        d->media_bytes = seen > 0 ? seen : 0;
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
 * The audio stream's index when the container header alone has described it, so that
 * `avformat_find_stream_info` (which reads ahead, several range requests on a remote stream) would
 * only add latency; -1 when the probe is needed. True only for lossless codecs whose header carries
 * everything: FLAC (STREAMINFO), ALAC (the moov `alac` atom) and PCM in WAV or AIFF. Lossy codecs
 * (MP3, AAC, Opus, Vorbis) keep the probe: their parameters and duration come from the frames.
 */
static int header_described_audio_stream(const AVFormatContext *fmt, int length_known) {
    if (!fmt->iformat || !fmt->iformat->name) return -1;
    const char *container = fmt->iformat->name;
    int is_mp4 = strstr(container, "mp4") != NULL;
    int is_flac = strcmp(container, "flac") == 0;
    int is_wav = strcmp(container, "wav") == 0;
    int is_aiff = strcmp(container, "aiff") == 0;
    if (!is_mp4 && !is_flac && !is_wav && !is_aiff) return -1;

    int audio = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        if (audio >= 0) return -1;   /* more than one audio stream: let the probe choose */
        audio = (int)i;
    }
    if (audio < 0) return -1;
    const AVStream *stream = fmt->streams[audio];
    const AVCodecParameters *par = stream->codecpar;

    int codec_ok = 0;
    if (is_flac) {
        codec_ok = par->codec_id == AV_CODEC_ID_FLAC;
    } else if (is_mp4) {
        codec_ok = par->codec_id == AV_CODEC_ID_ALAC;
    } else {
        /* The PCM codecs the wav and aiff demuxers emit; anything else they can carry (ADPCM,
         * a-law, MPEG in a RIFF hack) keeps the probe. */
        switch (par->codec_id) {
        case AV_CODEC_ID_PCM_U8:
        case AV_CODEC_ID_PCM_S8:
        case AV_CODEC_ID_PCM_S16LE:
        case AV_CODEC_ID_PCM_S24LE:
        case AV_CODEC_ID_PCM_S32LE:
        case AV_CODEC_ID_PCM_F32LE:
        case AV_CODEC_ID_PCM_F64LE:
        case AV_CODEC_ID_PCM_S16BE:
        case AV_CODEC_ID_PCM_S24BE:
        case AV_CODEC_ID_PCM_S32BE:
            codec_ok = 1;
            break;
        default:
            break;
        }
    }
    if (!codec_ok) return -1;

    if (is_flac) {
        /* The flac demuxer leaves the parameters to its parser (they stay 0 until the probe), but
         * hands the decoder the STREAMINFO block as extradata, which is where the decoder reads its
         * rate, channels and bit depth from. */
        if (par->extradata_size < 34) return -1;
    } else {
        if (par->sample_rate <= 0 || par->ch_layout.nb_channels <= 0) return -1;
        if (par->format == AV_SAMPLE_FMT_NONE && par->bits_per_raw_sample <= 0
            && par->bits_per_coded_sample <= 0) {
            return -1;
        }
        /* The ALAC decoder reads its setup from the magic cookie the moov `alac` atom carries as
         * extradata (36 bytes); without it the open fails, so let the probe have the file. */
        if (is_mp4 && par->extradata_size < 36) return -1;
    }
    /* The duration must already be known without the probe, from the stream or the format. A WAV
     * from a source without a total length is the exception: its demuxer cannot size the data
     * chunk, so the duration is unknown with the probe too (it only reads on to the same nothing).
     * With a length, the probe recovers it from the file size and bit rate when the header's size
     * fields are 0 or 0xFFFFFFFF (streamed recorders), so an unknown duration keeps the probe. */
    int duration_known = (stream->duration != AV_NOPTS_VALUE && stream->duration > 0)
        || (fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0);
    if (!duration_known && !(is_wav && !length_known)) return -1;
    return audio;
}

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
    /* Skipped when the header already describes a lossless stream (issue #21): the probe's
     * read-ahead is pure play-start latency there. `force_probe` restores the probe. */
    d->skipped_probe = 0;
    if (!(options && options->force_probe)) {
        int header_audio = header_described_audio_stream(d->fmt, d->cb.size(d->opaque) >= 0);
        if (header_audio >= 0) {
            d->skipped_probe = 1;
            /* av_find_best_stream ignores a FLAC stream whose rate and channels are still 0, so
             * take the one audio stream the check above found. */
            d->audio_idx = header_audio;
            return STREAM_DECODE_OK;
        }
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

/* How far past `base_offset` `reopen_past_mp3_junk` looks for audio. Each byte is read once, so the
 * cap is what a hopeless file costs on top of the probe: 1 MiB is about 65 s of 128 kbps audio, far
 * more junk than any real file carries, and a bounded few seconds of cellular data. */
static const int64_t kMP3ResyncScanBytes = 1024 * 1024;
/* Consecutive frame headers that must chain (each at the previous one's end) to call it audio. */
static const int kMP3ResyncChain = 3;
/* The longest frame `mp3_parse_header` accepts: MPEG 2.5 layer II at 160 kbps and 8 kHz is
 * 1152 / 8 * 160000 / 8000 = 2880 bytes, plus one padding byte. (Layer I tops out at 964, layer III
 * at 1441.) */
enum { kMP3ResyncMaxFrame = 2881 };
/* What the scan carries over from one read to the next. A chain is abandoned for more bytes only
 * when a header position `at` has `at + 4 > len`, and `at` is at most (chain - 1) frames past the
 * candidate `i`, so `len - i` is under `(chain - 1) * frame + 4` = `kMP3ResyncLook`; otherwise `i` ends
 * at `len - 3`. The buffer holds the carry plus one read. */
enum { kMP3ResyncChunk = 32 * 1024, kMP3ResyncLook = 2 * kMP3ResyncMaxFrame + 4 };

static int mp3_parse_header(const uint8_t *p, int *spf, int *bitrate, int *sample_rate,
                            int *side_info_bytes);

/* The start of the body is the signature of another container or a text page, which no amount of
 * scanning will turn into MP3 (an ID3 tag has been skipped already, so these are the audio's own
 * first bytes). */
static int prologue_is_not_mp3(const StreamDecoder *d) {
    const uint8_t *p = d->prologue;
    int n = d->prologue_len;
    if (n >= 8 && !memcmp(p + 4, "ftyp", 4)) return 1;
    if (n >= 4 && (!memcmp(p, "OggS", 4) || !memcmp(p, "fLaC", 4) || !memcmp(p, "RIFF", 4) || !memcmp(p, "FORM", 4))) return 1;
    return n >= 1 && (p[0] == '<' || p[0] == '{');
}

/* The byte length of the MPEG audio frame whose header is at `p`, or 0 if it is not one. */
static int mp3_frame_length(const uint8_t *p, uint32_t *key) {
    int spf, bitrate, rate, side;
    if (!mp3_parse_header(p, &spf, &bitrate, &rate, &side)) return 0;
    int pad = (p[2] >> 1) & 1;
    int len = spf == 384 ? (12 * bitrate / rate + pad) * 4 : spf / 8 * bitrate / rate + pad;
    /* What must not change from one frame to the next: version, layer, sample rate. */
    *key = ((uint32_t)(p[1] & 0x1E) << 8) | (p[2] & 0x0C);
    return len;
}

/*
 * A probe that finds no audio behind more than its budget of junk (issue #24): look past the
 * budget for the first run of `kMP3ResyncChain` MPEG audio frames that follow each other, and open
 * there. A lone 0xFFE sync word in the junk does not chain, so it is not taken. Only runs after
 * a failed open, so a file that opens is read exactly as before.
 */
static int reopen_past_mp3_junk(StreamDecoder *d, const StreamDecodeOptions *options, int failed) {
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
    close_format(d);

    enum { kChunk = kMP3ResyncChunk, kLook = kMP3ResyncLook };
    /* The probe has already looked at the first `kMP3JunkScanBytes` (mp3dec scans them for two
     * chained frames), so start there, less the span a chain occupies in case one straddles it. */
    int64_t found = -1, pos = kMP3JunkScanBytes - kLook;   /* `pos`: offset of buf[0] from base_offset */
    /* The failed open read on through the junk to the audio, as far as libavformat's own buffer
     * ahead of it: the first frame is within the last 64 KiB of what it read, so there is no need
     * to read the junk again. What it read is the run of bytes it consumed from the start, which
     * stays true whatever the failed open then seeked to (`io_pos` is wherever that left it). */
    if (d->contiguous_read - 64 * 1024 > pos) pos = d->contiguous_read - 64 * 1024;
    /* Nothing left to look at, or a body that is another format's: leave the reader alone. */
    if (pos >= kMP3ResyncScanBytes || prologue_is_not_mp3(d)) return failed;
    uint8_t *buf = (uint8_t *)av_malloc(kChunk + kLook);
    if (!buf) return STREAM_DECODE_ERR_ALLOC;
    int len = 0, rc = reopen_seek(d, d->base_offset + pos);
    int scanned_to_end = 0;
    if (rc != STREAM_DECODE_OK) { av_free(buf); return rc == STREAM_DECODE_ERR_IO ? failed : rc; }
    while (found < 0 && pos < kMP3ResyncScanBytes && !scanned_to_end) {
        int n = d->cb.read(d->opaque, buf + len, kChunk);
        if (n > 0) { d->bytes_read += n; len += n; }
        else if (n == STREAM_READ_EOF) scanned_to_end = 1;
        else if (n == STREAM_READ_CANCELLED) { d->cancelled = 1; av_free(buf); return STREAM_DECODE_ERR_CANCELLED; }
        else if (n == STREAM_READ_INTERRUPTED) { d->interrupted = 1; av_free(buf); return STREAM_DECODE_ERR_INTERRUPTED; }
        else { av_free(buf); return failed; }
        int i = 0;
        for (; i + 4 <= len; i++) {
            if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;
            int at = i, ok = 1;
            uint32_t key0 = 0, key;
            for (int k = 0; k < kMP3ResyncChain && ok; k++) {
                if (at + 4 > len) {
                    if (scanned_to_end) ok = 0;
                    else goto need_more;   /* the chain runs past what is read */
                    break;
                }
                int fl = mp3_frame_length(buf + at, &key);
                if (!fl || fl > kMP3ResyncMaxFrame || (k && key != key0)) { ok = 0; break; }
                key0 = key;
                at += fl;
            }
            if (ok) { found = pos + i; break; }
        }
need_more:
        if (found >= 0) break;
        /* Keep from `i` on: what is before it cannot start a chain. */
        memmove(buf, buf + i, (size_t)(len - i));
        len -= i;
        pos += i;
    }
    av_free(buf);
    if (found < 0) return failed;

    d->base_offset += found;
    rc = reopen_seek(d, d->base_offset);
    if (rc != STREAM_DECODE_OK) return rc == STREAM_DECODE_ERR_IO ? failed : rc;
    d->io_pos = 0;
    d->prologue_len = 0;
    d->source_eof = 0;
    return open_format(d, options);
}

/*
 * A file that is one MPEG audio frame and nothing else (issue #51). mp3dec's header scan wants a
 * second frame header after the first and fails the open when it reads end of file there ("Failed
 * to find two consecutive MPEG audio frames"); media3's Mp3Extractor plays it. The open is retried
 * with a copy of the frame appended to what libavformat sees; `phantom_len` makes the AVIO glue
 * serve it, and the open path clips the audio to the real frame. Only after a failed open, so no
 * other file is read differently.
 */
static int reopen_single_frame_mp3(StreamDecoder *d, const StreamDecodeOptions *options, int failed) {
    int64_t size = d->cb.size(d->opaque);
    /* Without a length, the failed open having met end of file is what says the bytes are all there are. */
    int64_t avail = size >= 0 ? size - d->base_offset : d->source_eof ? d->prologue_len : -1;
    uint32_t key;
    int spf, bitrate, rate, side;
    if (d->cancelled || d->interrupted || avail < 4 || avail > (int64_t)sizeof(d->phantom)
        || avail != d->prologue_len || mp3_frame_length(d->prologue, &key) != avail
        || !mp3_parse_header(d->prologue, &spf, &bitrate, &rate, &side)) {
        return failed;
    }
    int rc = reopen_seek(d, d->base_offset);
    if (rc != STREAM_DECODE_OK) return rc == STREAM_DECODE_ERR_IO ? failed : rc;
    close_format(d);
    memcpy(d->phantom, d->prologue, (size_t)avail);
    d->phantom_len = (int)avail;
    d->phantom_at = avail;
    d->phantom_samples = spf;
    d->io_pos = 0;
    d->prologue_len = 0;
    d->source_eof = 0;
    rc = open_format(d, options);
    if (rc != STREAM_DECODE_OK) {
        d->phantom_len = 0;
        return rc == STREAM_DECODE_ERR_OPEN || rc == STREAM_DECODE_ERR_NO_AUDIO ? failed : rc;
    }
    return rc;
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

static int mp3_prologue_is_cbr(const StreamDecoder *d);

/* Keep `d->held`, the first audio packet, for the decoder, and note what frame counting needs. */
static void hold_first_packet(StreamDecoder *d) {
    d->has_held = 1;
    d->first_pkt_pos = d->held->pos;
    d->first_pkt_dts = d->held->dts;
    d->first_pkt_size = d->held->size;
    d->has_first_pkt = d->held->pos >= 0 && d->held->dts != AV_NOPTS_VALUE;
    int spf, br, sr, side;
    int is_mp3 = d->fmt->iformat && d->fmt->iformat->name && strstr(d->fmt->iformat->name, "mp3");
    if (is_mp3 && d->has_first_pkt && d->held->size >= 4
        && mp3_parse_header(d->held->data, &spf, &br, &sr, &side)) {
        d->mp3_header_ok = 1;
        d->mp3_header = ((uint32_t)d->held->data[0] << 24) | ((uint32_t)d->held->data[1] << 16)
                      | ((uint32_t)d->held->data[2] << 8) | d->held->data[3];
        d->mp3_spf = spf;
        d->mp3_tag = mp3_find_tag(d);
        d->mp3_untagged_cbr = d->mp3_tag == MP3_TAG_NONE && mp3_prologue_is_cbr(d);
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
 * stream is constant-bitrate when its Info frame says so, or when it has no tag frame, the frames
 * in the prologue (at least three) are all the first one's twins (`mp3_untagged_cbr`) and the
 * landed frame is too.
 * A VBR stream has no such relation and keeps the demuxer's estimate.
 */
static int64_t mp3_exact_dts(const StreamDecoder *d, const AVPacket *pkt) {
    if (!d->mp3_header_ok || d->mp3_tag == MP3_TAG_VBR) return AV_NOPTS_VALUE;
    if (d->mp3_tag == MP3_TAG_NONE && (!d->mp3_untagged_cbr || d->cb.size(d->opaque) < 0)) return AV_NOPTS_VALUE;
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

/*
 * The timestamp of `pkt` when it is at another sample rate than the first frame but the same
 * bitrate (an MP3 stitched from parts encoded at 44.1 and 48 kHz): there is no frame count to it,
 * since the frames before it are of two sizes, but both parts spend the same bytes per second, so
 * its offset from the end of the first frame gives its time to within a byte (1/8 ms at 64 kbps).
 * mp3dec labels it with the time asked for, up to a frame from the frame it found. AV_NOPTS_VALUE
 * otherwise, and in a VBR stream.
 */
static int64_t mp3_byte_rate_dts(const StreamDecoder *d, const AVPacket *pkt) {
    if (!d->mp3_header_ok || d->mp3_tag == MP3_TAG_VBR) return AV_NOPTS_VALUE;
    if (pkt->pos < 0 || pkt->size < 4) return AV_NOPTS_VALUE;
    const uint8_t first[4] = { d->mp3_header >> 24, d->mp3_header >> 16, d->mp3_header >> 8,
                               d->mp3_header };
    int spf, br, sr, side, first_spf, first_br, first_sr;
    if (!mp3_parse_header(pkt->data, &spf, &br, &sr, &side)
        || !mp3_parse_header(first, &first_spf, &first_br, &first_sr, &side)
        || sr == first_sr || br != first_br) {
        return AV_NOPTS_VALUE;
    }
    int64_t second = d->first_pkt_pos + d->first_pkt_size;
    if (pkt->pos < second) return AV_NOPTS_VALUE;
    return d->first_pkt_dts
        + av_rescale_q(first_spf, (AVRational){ 1, first_sr }, d->time_base)
        + av_rescale_q(pkt->pos - second, (AVRational){ 8, br }, d->time_base);
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
 * Whether a stream with no tag frame can be taken for constant-bitrate: the frames from the first
 * on that the prologue holds (at least three) are all the first frame's twin. Nothing else in such a
 * file says so. A VBR file that opens at one bitrate and moves on shows it within a few frames; one
 * that does not is beyond what a seek can know, and gets no more than an estimate (issue #16).
 */
static int mp3_prologue_is_cbr(const StreamDecoder *d) {
    int frames = 0;
    for (int64_t pos = d->first_pkt_pos; pos >= 0 && pos + 4 <= d->prologue_len; frames++) {
        MP3Frame f;
        uint32_t h = read_be(d->prologue + pos, 4);
        if ((h & kMP3SameStreamMask) != (d->mp3_header & kMP3SameStreamMask) || !mp3_frame_of(h, &f)) return 0;
        pos += f.bytes;
    }
    return frames >= 3;
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
    if (d->mp3_tag == MP3_TAG_NONE) return !d->mp3_untagged_cbr || d->cb.size(d->opaque) < 0 ? 0 : d->mp3_header;
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
    d->decode_errors = 0;
    d->flushing = 0;
    d->reopening = 0;
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

/* ── FLAC without a seek table (issue #38) ───────────────────────────────── */

/* What a FLAC stream's STREAMINFO says, which every frame header is read against. */
typedef struct {
    int     max_blocksize;
    int     max_frame_bytes;   /* 0: unknown */
    int     sample_rate;
    int     channels;
    int     bits;
    int64_t total_samples;     /* 0: unknown */
} FLACInfo;

/* Whether the stream is native FLAC with a STREAMINFO to read, which the flac demuxer keeps as the
 * codec's extradata. */
static int flac_info(const StreamDecoder *d, FLACInfo *si) {
    if (!d->fmt->iformat->name || strcmp(d->fmt->iformat->name, "flac") != 0) return 0;
    const AVCodecParameters *par = d->fmt->streams[d->audio_idx]->codecpar;
    if (par->codec_id != AV_CODEC_ID_FLAC || !par->extradata || par->extradata_size < 34) return 0;
    const uint8_t *p = par->extradata;
    si->max_blocksize = (int)read_be(p + 2, 2);
    si->max_frame_bytes = (int)read_be(p + 7, 3);
    si->sample_rate = (int)(read_be(p + 10, 3) >> 4);
    si->channels = ((p[12] >> 1) & 7) + 1;
    si->bits = (((p[12] & 1) << 4) | (p[13] >> 4)) + 1;
    si->total_samples = ((int64_t)(p[13] & 15) << 32) | read_be(p + 14, 4);
    return si->max_blocksize >= 16 && si->sample_rate > 0 && si->sample_rate == d->sample_rate;
}

/*
 * Read a FLAC frame header at `p` (`n` bytes there). Returns its length, with the frame's first
 * sample and block size, when it is a header of this stream: the sync code, every field this
 * stream's (or "as in STREAMINFO"), the coded number well formed and the CRC-8 right. 0 when it is
 * not one, -1 when `n` bytes are too few to tell.
 *
 * The frame number is what makes a FLAC seek exact where an MP3's cannot be: every frame says
 * which it is (a fixed-blocksize stream counts frames, a variable one samples), so a frame found
 * anywhere in the file has its time with it.
 */
static int flac_frame_header(const uint8_t *p, int n, const FLACInfo *si, int64_t *sample, int *blocksize) {
    static const int rates[12] = { 0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000 };
    static const int bits[8] = { 0, 8, 12, 0, 16, 20, 24, 32 };
    if (n < 2) return -1;
    if (p[0] != 0xFF || (p[1] & 0xFE) != 0xF8) return 0;
    if (n < 5) return -1;
    int variable = p[1] & 1;
    int bs_code = p[2] >> 4, sr_code = p[2] & 15, ch = p[3] >> 4, ss = (p[3] >> 1) & 7;
    if (bs_code == 0 || sr_code == 15 || ch > 10 || ss == 3 || (p[3] & 1)) return 0;
    if ((ch < 8 ? ch + 1 : 2) != si->channels) return 0;
    if (ss && bits[ss] != si->bits) return 0;
    if (sr_code >= 1 && sr_code <= 11 && rates[sr_code] != si->sample_rate) return 0;

    /* The frame (fixed) or sample (variable) number, coded like UTF-8 up to 36 bits. */
    int lead = p[4], extra;
    if (lead < 0x80) extra = 0;
    else if (lead >= 0xC0 && lead < 0xE0) extra = 1;
    else if (lead >= 0xE0 && lead < 0xF0) extra = 2;
    else if (lead >= 0xF0 && lead < 0xF8) extra = 3;
    else if (lead >= 0xF8 && lead < 0xFC) extra = 4;
    else if (lead >= 0xFC && lead < 0xFE) extra = 5;
    else if (lead == 0xFE && variable) extra = 6;
    else return 0;
    if (n < 5 + extra) return -1;
    int64_t number = lead & (extra ? 0x3F >> extra : 0x7F);
    for (int i = 1; i <= extra; i++) {
        if ((p[4 + i] & 0xC0) != 0x80) return 0;
        number = (number << 6) | (p[4 + i] & 0x3F);
    }
    int len = 5 + extra;

    int bs;
    if (bs_code == 6 || bs_code == 7) {
        int k = bs_code - 5;
        if (n < len + k) return -1;
        bs = (int)read_be(p + len, k) + 1;
        len += k;
    } else if (bs_code == 1) {
        bs = 192;
    } else if (bs_code <= 5) {
        bs = 576 << (bs_code - 2);
    } else {
        bs = 256 << (bs_code - 8);
    }
    if (sr_code >= 12) {
        int k = sr_code == 12 ? 1 : 2;
        if (n < len + k) return -1;
        int v = (int)read_be(p + len, k);
        if ((sr_code == 12 ? v * 1000 : sr_code == 13 ? v : v * 10) != si->sample_rate) return 0;
        len += k;
    }
    if (n < len + 1) return -1;
    if (av_crc(av_crc_get_table(AV_CRC_8_ATM), 0, p, (size_t)len) != p[len]) return 0;
    if (bs > si->max_blocksize) return 0;
    /* A fixed-blocksize stream's frames all have its block size but the last, which may be
     * shorter: the frame number counts blocks of STREAMINFO's maximum, not of this frame's size. */
    int64_t first = variable ? number : number * si->max_blocksize;
    if (si->total_samples > 0 && first >= si->total_samples) return 0;
    *sample = first;
    *blocksize = bs;
    return len + 1;
}

enum { FLAC_PROBE_FOUND, FLAC_PROBE_NONE, FLAC_PROBE_GAVE_UP };

/*
 * Find the first frame that starts at or after byte `at` (AVIO offset) and before `end`, where the
 * frames from `end_sample` on start; the frame at `lo_sample` starts before `at`. Only a header
 * numbered strictly between the two counts. One at or before `want` (which may become the seek's
 * anchor) is believed when a later one follows it (its first sample is that one's plus its block
 * size), or when its frame runs to `end` or is the stream's last; a header passing every check by
 * chance inside a frame's data then costs a frame more, not a wrong landing, and does not hide
 * the real header before it from the one after. One after `want` only bounds the search, so it
 * is taken on its CRC-8, without reading on through its frame: a lookalike there costs probes,
 * never the landing. Reads 4 KiB at a time straight from the reader (AVIO's direct mode, so a
 * probe does not cost a 32 KiB refill), adding them to `*spent`.
 *
 * `*result` is FLAC_PROBE_FOUND with `*pos` and `*sample`, FLAC_PROBE_NONE when no frame starts
 * in [at, end) (which one of the largest frames scanned with no header in it also shows), or
 * FLAC_PROBE_GAVE_UP (a read failed, or no header believed within two of the largest frames).
 * Returns STREAM_DECODE_OK, or a cancel or an interruption.
 */
static int flac_probe(StreamDecoder *d, const FLACInfo *si, int64_t at, int64_t end, int64_t lo_sample,
                      int64_t end_sample, int64_t want, int *result, int64_t *pos, int64_t *sample,
                      int64_t *spent) {
    *result = FLAC_PROBE_GAVE_UP;
    int cap = si->max_frame_bytes > 0 ? 2 * si->max_frame_bytes + 64 : 256 * 1024;
    if ((int64_t)cap > d->media_bytes - at) cap = (int)(d->media_bytes - at);
    if (cap <= 0) return STREAM_DECODE_OK;
    uint8_t *buf = av_malloc((size_t)cap);
    if (!buf) return STREAM_DECODE_OK;

    /* The headers met so far, any of which the next may follow: a lookalike between two real
     * headers must not hide the first from the second. */
    enum { kCands = 8 };
    int64_t cands[kCands], cand_samples[kCands];
    int cand_sizes[kCands], ncands = 0;
    int64_t cand = -1, cand_sample = 0;
    int have = 0, scanned = 0, ended = 0;
    d->avio->direct = 1;
    if (avio_seek(d->fmt->pb, at, SEEK_SET) < 0) ended = -1;
    while (ended == 0) {
        while (scanned < have) {
            if (at + scanned >= end) {
                ended = 1;
                break;
            }
            int64_t s;
            int bs;
            int r = flac_frame_header(buf + scanned, have - scanned, si, &s, &bs);
            if (r < 0) break;
            /* Every frame between the bracket's ends starts strictly between their samples. */
            if (r > 0 && s > lo_sample && (end_sample <= 0 || s < end_sample)) {
                for (int i = 0; i < ncands; i++) {
                    if (cand_samples[i] + cand_sizes[i] == s) {
                        cand = cands[i];
                        cand_sample = cand_samples[i];
                        *result = FLAC_PROBE_FOUND;
                        goto done;
                    }
                }
                if (ncands == kCands) {
                    memmove(cands, cands + 1, sizeof(cands[0]) * (kCands - 1));
                    memmove(cand_samples, cand_samples + 1, sizeof(cand_samples[0]) * (kCands - 1));
                    memmove(cand_sizes, cand_sizes + 1, sizeof(cand_sizes[0]) * (kCands - 1));
                    ncands--;
                }
                cands[ncands] = scanned;
                cand_samples[ncands] = s;
                cand_sizes[ncands++] = bs;
                if (s > want) {
                    cand = scanned;
                    cand_sample = s;
                    *result = FLAC_PROBE_FOUND;
                    goto done;
                }
            }
            scanned++;
        }
        if (ended) break;
        /* Every frame is at most `max_frame_bytes` long, so the first to start at or after `at`
         * does so within one of them: that far scanned with no header of the stream is past the
         * last frame (a tag, or junk). */
        if (ncands == 0 && si->max_frame_bytes > 0 && scanned >= si->max_frame_bytes) {
            *result = FLAC_PROBE_NONE;
            break;
        }
        if (have == cap) {
            if (at + have >= d->media_bytes) ended = 1;
            break;
        }
        int ask = cap - have < 4096 ? cap - have : 4096;
        int got = avio_read(d->fmt->pb, buf + have, ask);
        if (got > 0) {
            have += got;
            *spent += got;
        } else {
            ended = got == AVERROR_EOF && d->source_eof ? 1 : -1;
        }
    }
    /* The scan reached the next known frame, or the end of the stream: a header before it is
     * believed when its frame runs to there. */
    if (ended == 1) {
        int64_t next = at + have >= d->media_bytes || at + scanned < end ? si->total_samples : end_sample;
        for (int i = ncands - 1; i >= 0 && next > 0; i--) {
            if (cand_samples[i] + cand_sizes[i] == next) {
                cand = cands[i];
                cand_sample = cand_samples[i];
                *result = FLAC_PROBE_FOUND;
                break;
            }
        }
        if (ncands == 0) *result = FLAC_PROBE_NONE;
    }
done:
    if (*result == FLAC_PROBE_FOUND) {
        *pos = at + cand;
        *sample = cand_sample;
    }
    d->avio->direct = 0;
    av_free(buf);
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
    avio_clear_latched_error(d);
    return STREAM_DECODE_OK;
}

/* Up to `n` bytes at `pos` (AVIO offset): from the prologue when it holds them, else with one
 * small direct request. Returns how many arrived. */
static int flac_read_small(StreamDecoder *d, int64_t pos, uint8_t *buf, int n, int64_t *spent) {
    if (d->media_bytes - pos < n) n = (int)(d->media_bytes - pos);
    if (n <= 0) return 0;
    if (pos + n <= d->prologue_len) {
        memcpy(buf, d->prologue + pos, (size_t)n);
        return n;
    }
    d->avio->direct = 1;
    int got = avio_seek(d->fmt->pb, pos, SEEK_SET) < 0 ? -1 : avio_read(d->fmt->pb, buf, n);
    d->avio->direct = 0;
    avio_clear_latched_error(d);
    if (got <= 0) return 0;
    *spent += got;
    return got;
}

/* Whether a frame of this stream starting at `sample` starts at byte `pos` (AVIO offset). An index
 * entry is checked so before it is used: the generic index labels a FLAC packet with the parser's
 * position, which is not its frame's (the first frame's packet says 0, before the metadata). */
static int flac_frame_is_at(StreamDecoder *d, const FLACInfo *si, int64_t pos, int64_t sample, int64_t *spent) {
    uint8_t buf[32];
    int64_t s = -1;
    int bs, got = flac_read_small(d, pos, buf, (int)sizeof(buf), spent);
    return got > 0 && flac_frame_header(buf, got, si, &s, &bs) > 0 && s == sample;
}

/* Where a native FLAC stream's first frame starts (AVIO offset): after "fLaC" and every metadata
 * block, stepped over by their headers. Kept once found; 0 when it cannot be. */
static int64_t flac_audio_start(StreamDecoder *d, int64_t *spent) {
    if (d->flac_audio_pos > 0) return d->flac_audio_pos;
    if (d->prologue_len < 4 || memcmp(d->prologue, "fLaC", 4) != 0) return 0;
    int64_t at = 4;
    for (int blocks = 0; blocks < 1024; blocks++) {
        uint8_t h[4];
        if (flac_read_small(d, at, h, 4, spent) != 4) return 0;
        at += 4 + read_be(h + 1, 3);
        if (h[0] & 0x80) {
            d->flac_audio_pos = at;
            return at;
        }
    }
    return 0;
}

/* How far before its target a FLAC seek settles for a frame rather than probing again: one AVIO
 * refill, about as many bytes as another probe and its restart cost. */
static const int64_t kFLACNearBytes = 32 * 1024;

/*
 * Find the frame of a FLAC stream with no seek table that holds `target` (stream time base), or
 * one at most `kFLACNearBytes` before it, by interpolation between frames whose place and time are
 * both known (issues #38, #42).
 *
 * libavformat seeks such a stream by bisection over `flac_read_timestamp`, which reads the file's
 * tail for its last timestamp and buffers ten frames per probe through the parser, so it outruns
 * the seek budget on any file of more than a few seconds. Here the bracket starts from what the
 * index already knows (the first frame, frames decoded so far, a seek table) and the file's end,
 * and each probe reads the frame header at the interpolated byte, aimed one frame early, and
 * narrows the bracket to the true time it finds. As media3's `FlacBinarySearchSeeker` (over
 * `BinarySearchSeeker`) does, the search runs until the bracket is small, not for a number of
 * probes: a fixed ten (and 128 KiB) ended a search from the end of a file across a quiet stretch
 * beside a loud one unplaced (issue #42). Where the bitrate changes slowly, interpolation converges
 * in a probe or two; where it jumps, or a tag after the last frame counts in the length, the
 * search bisects (see below), so it takes at most twice bisection's probes, each reading at most
 * two of the largest frames: at most 24 on a 100 MB file.
 *
 * Sets `*pos` and `*dts` to the frame, which the decode then runs on from, dropping what is before
 * the target. Where that frame is further before the target than `kSeekBudgetBytes` (a probe gave
 * up: a read failed, or no header could be believed), `*short_of` is set: the seek lands on the
 * frame and says so. The byte estimate it used to take landed on whatever frame followed its byte
 * and reported the time asked for, though the frame said which it was: seconds off. `*pos` stays
 * -1 when the stream is not native FLAC, has no length, or its first frame is not where its
 * metadata ends. Returns STREAM_DECODE_OK, or a cancel or an interruption.
 */
static int flac_frame_before(StreamDecoder *d, int64_t target, int64_t *pos, int64_t *dts, int *short_of) {
    *pos = -1;
    *short_of = 0;
    FLACInfo si;
    if (!flac_info(d, &si) || !can_estimate_bytes(d)) return STREAM_DECODE_OK;
    AVStream *st = d->fmt->streams[d->audio_idx];
    AVRational per_sample = { 1, si.sample_rate };
    int64_t total = si.total_samples > 0 ? si.total_samples : llround(d->media_duration * si.sample_rate);
    int64_t want = av_rescale_q(target - d->start_time, d->time_base, per_sample);
    if (want < 0) want = 0;
    if (want > total) want = total;
    /* FFmpeg's FLAC parser drops its buffer when a large tag follows a lone frame header, so a
     * seek that lands on one of the last frames (the one frame in it, with 160 KiB or more of
     * tag after it) decodes nothing (issue #52). Two frames' worth earlier, the parser has the
     * headers that keep it. media3's FlacExtractor reads frames by header and CRC and has no
     * such lookahead; the cost here is two frames decoded and dropped. */
    if (total - want < 3 * (int64_t)si.max_blocksize) {
        want -= 2 * (int64_t)si.max_blocksize;
        if (want < 0) want = 0;
    }

    int64_t spent = 0;
    int64_t lo_pos = flac_audio_start(d, &spent), lo = 0;
    int64_t hi_pos = d->media_bytes, hi = total;
    if (lo_pos <= 0 || !flac_frame_is_at(d, &si, lo_pos, 0, &spent)) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        return STREAM_DECODE_OK;
    }
    int at = av_index_search_timestamp(st, target, AVSEEK_FLAG_BACKWARD);
    const AVIndexEntry *e = at >= 0 ? avformat_index_get_entry(st, at) : NULL;
    if (e) {
        int64_t s = av_rescale_q(e->timestamp - d->start_time, d->time_base, per_sample);
        int64_t p = e->pos;
        if (s <= want && s > lo && p > lo_pos && flac_frame_is_at(d, &si, p, s, &spent)) { lo = s; lo_pos = p; }
    }
    at = av_index_search_timestamp(st, target, 0);
    e = at >= 0 ? avformat_index_get_entry(st, at) : NULL;
    if (e) {
        int64_t s = av_rescale_q(e->timestamp - d->start_time, d->time_base, per_sample);
        int64_t p = e->pos;
        if (s > want && s < hi && p > lo_pos && p < hi_pos && flac_frame_is_at(d, &si, p, s, &spent)) { hi = s; hi_pos = p; }
    }
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;

    /* Interpolation alone crawls where the bitrate jumps (a quiet passage beside a loud one), each
     * probe moving the same end of the bracket a little: one that leaves more than half of it
     * makes the next one bisect. So does an upper end that is not a frame's: a probe that found no
     * frame after it (a tag after the last frame) bounds the bracket, but the bytes before it are
     * not audio, and interpolating against it aims at the tag again. */
    int bisect = 0, hi_framed = 1;
    while (hi > lo && hi_pos > lo_pos) {
        double bytes_per_sample = (double)(hi_pos - lo_pos) / (double)(hi - lo);
        double gap = (double)(want - lo) * bytes_per_sample;
        if (gap <= (double)kFLACNearBytes) break;
        int64_t probe_at = bisect
            ? lo_pos + (hi_pos - lo_pos) / 2
            : lo_pos + (int64_t)(gap - si.max_blocksize * bytes_per_sample);
        if (probe_at <= lo_pos) probe_at = lo_pos + 1;
        if (probe_at >= hi_pos) break;
        int result;
        int64_t found_pos = -1, found = 0, width = hi_pos - lo_pos;
        int rc = flac_probe(d, &si, probe_at, hi_pos, lo, hi, want, &result, &found_pos, &found, &spent);
        if (rc != STREAM_DECODE_OK) return rc;
        if (result == FLAC_PROBE_GAVE_UP) break;
        if (result == FLAC_PROBE_NONE) {
            hi_pos = probe_at;   /* the frame before `hi` starts before the probe */
            hi_framed = 0;
        } else if (found <= want) {
            lo = found;
            lo_pos = found_pos;
        } else {
            /* Nothing at or after the probe starts before `found`, so the probe's byte bounds it
             * as well as the frame's own does, and up to a frame tighter. */
            hi = found;
            hi_pos = probe_at;
            hi_framed = 1;
        }
        bisect = !hi_framed || hi_pos - lo_pos > width / 2;
    }
    double bytes_per_sample = hi > lo ? (double)(hi_pos - lo_pos) / (double)(hi - lo) : 0;
    *short_of = (double)(want - lo) * bytes_per_sample > (double)kSeekBudgetBytes;
    *pos = lo_pos;
    *dts = d->start_time + av_rescale_q(lo, per_sample, d->time_base);
    /* The generic seek reads forward from the index's last entry rather than going to it, and as
     * it passes, the parser's packets re-add the anchor's time at a stale byte: a far seek landed
     * ten seconds later than it said. An entry at the true end keeps the anchor off the end. */
    int64_t end_dts = d->start_time + av_rescale_q(total, per_sample, d->time_base);
    if (end_dts > *dts) av_add_index_entry(st, d->media_bytes, end_dts, 0, 0, AVINDEX_KEYFRAME);
    return STREAM_DECODE_OK;
}

/*
 * The fallback anchor for a native FLAC seek whose anchored attempt failed: one probe at the byte
 * estimate (the target's share of the stream), aimed a maximum block early so the frame it finds
 * starts at or before the target. It reads at most `2 * max_frame_bytes + 64` and the frame's
 * header gives its time, so the work is bounded where the demuxer's bisection is not (about 15 to
 * 25 far probes). media3's FlacBinarySearchSeeker bounds its work the same way. `*pos` is -1 when
 * the probe finds no frame at or before the target, and the caller bisects as a last resort.
 */
static int flac_estimate_anchor(StreamDecoder *d, double ratio, int64_t target, int64_t *pos, int64_t *dts,
                                int *short_of) {
    *pos = -1;
    *short_of = 0;
    FLACInfo si;
    if (!flac_info(d, &si) || !can_estimate_bytes(d)) return STREAM_DECODE_OK;
    AVStream *st = d->fmt->streams[d->audio_idx];
    AVRational per_sample = { 1, si.sample_rate };
    int64_t total = si.total_samples > 0 ? si.total_samples : llround(d->media_duration * si.sample_rate);
    int64_t want = av_rescale_q(target - d->start_time, d->time_base, per_sample);
    if (want < 0) want = 0;
    if (want > total) want = total;
    if (total - want < 3 * (int64_t)si.max_blocksize) {   /* issue #52, as in flac_frame_before */
        want -= 2 * (int64_t)si.max_blocksize;
        if (want < 0) want = 0;
    }
    int64_t spent = 0;
    int64_t lo_pos = flac_audio_start(d, &spent);
    if (lo_pos <= 0) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        return STREAM_DECODE_OK;
    }
    double bytes_per_sample = (double)d->media_bytes / (double)(total > 0 ? total : 1);
    int64_t at = (int64_t)(ratio * (double)d->media_bytes) - (int64_t)(si.max_blocksize * bytes_per_sample);
    if (at < lo_pos) at = lo_pos;
    if (at >= d->media_bytes) return STREAM_DECODE_OK;
    int result;
    int64_t found_pos = -1, found = 0;
    int rc = flac_probe(d, &si, at, d->media_bytes, -1, 0, want, &result, &found_pos, &found, &spent);
    if (rc != STREAM_DECODE_OK) return rc;
    if (result != FLAC_PROBE_FOUND || found > want) return STREAM_DECODE_OK;
    *short_of = (double)(want - found) * bytes_per_sample > (double)kSeekBudgetBytes;
    *pos = found_pos;
    *dts = d->start_time + av_rescale_q(found, per_sample, d->time_base);
    int64_t end_dts = d->start_time + av_rescale_q(total, per_sample, d->time_base);
    if (end_dts > *dts) av_add_index_entry(st, d->media_bytes, end_dts, 0, 0, AVINDEX_KEYFRAME);
    return STREAM_DECODE_OK;
}

/* `avformat_seek_file` with the seek byte budget armed; `*walked` says it was spent. */
static int budgeted_seek(StreamDecoder *d, int64_t min_ts, int64_t ts, int64_t max_ts, int flags, int *walked) {
    d->seek_bytes = 0;
    d->seek_budget = d->seek_budget_override > 0 ? d->seek_budget_override : kSeekBudgetBytes;
    d->seek_budget_blown = 0;
    d->seek_budget_armed = 1;
    d->source_eof = 0;
    int rc = avformat_seek_file(d->fmt, d->audio_idx, min_ts, ts, max_ts, flags);
    *walked = d->seek_budget_blown;
    d->seek_budget_armed = 0;
    /* The refusal that abandoned the walk is latched in the AVIO context; what follows has to
     * read, so clear it here rather than after the seek that would already have failed. */
    if (*walked) avio_clear_latched_error(d);
    return rc;
}

/* Put the demuxer at byte `byte` (AVIO offset) for the byte-estimate seek, ready to decode. */
static int seek_to_byte(StreamDecoder *d, int64_t byte) {
    int rc = avformat_seek_file(d->fmt, d->audio_idx, INT64_MIN, byte, byte,
                                AVSEEK_FLAG_BYTE | AVSEEK_FLAG_BACKWARD);
    if (rc < 0) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        return STREAM_DECODE_ERR_SEEK;
    }
    after_seek_reset(d);
    return init_swr(d);
}

static int seek_to(StreamDecoder *decoder, double seconds, double *landed_seconds);
static int demux_seek(StreamDecoder *decoder, double seconds, int64_t target, double *landed_seconds);
static int land_exactly(StreamDecoder *d, int64_t target);

/* `demux_seek`'s "the demuxer is placed, land by the timestamps" result; no STREAM_DECODE_ code. */
static const int kSeekPlaced = 1000;

/* How many times a byte estimate past the last frame steps back before the walk takes over. */
static const int kEndStepBacks = 8;

/* Whether a byte seek to `seconds` ran to the end of the stream with nothing decoded, though the
 * stream says it lasts longer: the end of the reader came first, as end of stream or, from a
 * demuxer reading a header there (ADTS), as an I/O error. */
static int past_last_frame(const StreamDecoder *d, int status, double seconds) {
    if (status != STREAM_DECODE_EOF && !(status == STREAM_DECODE_ERR_IO && d->source_eof)) return 0;
    return d->next_pts == AV_NOPTS_VALUE && !d->cancelled && !d->interrupted && seconds < d->media_duration;
}

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
    /* Every FLAC frame decodes on its own: nothing before the target's frame is needed. */
    if (d->dec->codec_id == AV_CODEC_ID_FLAC) return 0;
    uint32_t h = d->dec->codec_id == AV_CODEC_ID_MP3 ? mp3_cbr_header(d) : 0;
    MP3Frame f;
    if (h && mp3_frame_of(h, &f)) {
        /* Without the padding bit: the frames after a padded one are mostly unpadded, and counting
         * the extra byte they do not carry sizes the pre-roll a frame or more too short at the
         * lowest bitrates, where the reservoir spans dozens of frames. */
        int main_bytes = f.bytes - (int)((h >> 9) & 1) - 4 - f.side_info_bytes - (((h >> 16) & 1) ? 0 : 2);
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
    decoder->output_fixed = 1;
    decoder->unseekable = 0;
    int status = seek_to(decoder, seconds, landed_seconds);
    /* Only a seek that ended in a seek or I/O failure: the C code recovers from some refused
     * reader seeks (fallbacks), and cancel/interrupt keep their own verdicts. */
    if (decoder->unseekable && (status == STREAM_DECODE_ERR_SEEK || status == STREAM_DECODE_ERR_IO)) {
        status = STREAM_DECODE_ERR_UNSEEKABLE;
    }
    if (status == STREAM_DECODE_OK || status == STREAM_DECODE_EOF) {
        decoder->position_frames = llround(*landed_seconds * decoder->out_rate);
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
        && llround(seconds * decoder->out_rate) == decoder->position_frames) {
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
        /* A FLAC frame further before the target than a seek may decode lands where it is, at the
         * time its header gives, rather than at the target with the audio elsewhere (issue #42). */
        int64_t land_at = decoder->flac_short_at != AV_NOPTS_VALUE ? decoder->flac_short_at : target;
        int status = land_exactly(decoder, land_at);
        if (status == STREAM_DECODE_OK && !from_start && !last && decoder->seek_first_pts != AV_NOPTS_VALUE
            && decoder->seek_first_pts > target) {
            continue;
        }
        if (status == STREAM_DECODE_OK && !from_start && attempt < 3 && decoder->mp3_preroll_short) {
            continue;
        }
        /* Past the fourth placement the landing stands even if `mp3_preroll_short` is still set:
         * the frames from the target on then decode from a reservoir the pre-roll never fed, so
         * this seek is not sample-exact. The engine has no diagnostic channel for it (libav's log
         * is silenced and a seek's result has no field for it), and 64 times the first pre-roll
         * reaches every stream the reservoir can span, so it is left unreported. */
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
        if (dts == AV_NOPTS_VALUE && rc >= 0) dts = mp3_byte_rate_dts(d, d->held);
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
    /* A FLAC frame says which it is, so one found at a byte is a frame of known time too. */
    decoder->flac_short_at = AV_NOPTS_VALUE;
    if (!decoder->mp3_header_ok) {
        int short_of = 0;
        int found = flac_frame_before(decoder, target, &anchor_pos, &anchor_dts, &short_of);
        if (found != STREAM_DECODE_OK) return found;
        if (short_of) decoder->flac_short_at = anchor_dts;
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
    int walked = 0;
    int rc = budgeted_seek(decoder, seek_min, seek_ts, seek_ts, seek_flags, &walked);
    decoder->fmt->flags = fmt_flags;

    if (rc < 0 || walked) {
        if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        /* An interrupted seek is retried by the caller, and has to land where the uninterrupted
         * one would: the byte estimate would land somewhere else (issue #5). */
        if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
        FLACInfo flac_si;
        if (flac_info(decoder, &flac_si) && can_estimate_bytes(decoder)) {
            /* Native FLAC never takes the byte estimate: it would report the target over audio
             * from wherever the byte falls (issue #54). The anchored seek failed (a read error) or
             * there was no anchor to place, so one bounded probe at the byte estimate finds a
             * frame whose header gives its time (`flac_estimate_anchor`) and the seek anchors on
             * it. Only when the probe finds no frame does the demuxer's own bisection, which
             * reads frame headers for their times, place it at whatever cost, as an expensive
             * seek beats one that reports the wrong place. */
            avio_clear_latched_error(decoder);
            decoder->source_eof = 0;
            decoder->anchored = 0;
            decoder->flac_short_at = AV_NOPTS_VALUE;
            double flac_ratio = seconds / decoder->media_duration;
            if (flac_ratio < 0) flac_ratio = 0;
            if (flac_ratio > 1) flac_ratio = 1;
            int64_t est_pos = -1, est_dts = AV_NOPTS_VALUE;
            int est_short = 0;
            int est = flac_estimate_anchor(decoder, flac_ratio, target, &est_pos, &est_dts, &est_short);
            if (est != STREAM_DECODE_OK) return est;
            if (est_pos >= 0) {
                av_add_index_entry(decoder->fmt->streams[decoder->audio_idx], est_pos, est_dts, 0, 0,
                                   AVINDEX_KEYFRAME);
                decoder->fmt->flags &= ~AVFMT_FLAG_FAST_SEEK;
                decoder->anchored = 1;
                int est_walked = 0;
                rc = budgeted_seek(decoder, est_dts, est_dts, est_dts, AVSEEK_FLAG_ANY, &est_walked);
                decoder->fmt->flags = fmt_flags;
                if (rc >= 0 && !est_walked) {
                    if (est_short) decoder->flac_short_at = est_dts;
                    return kSeekPlaced;
                }
                if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
                avio_clear_latched_error(decoder);
                decoder->source_eof = 0;
                decoder->anchored = 0;
            }
            rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, target, target,
                                    AVSEEK_FLAG_BACKWARD);
            if (rc < 0) {
                if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
                return STREAM_DECODE_ERR_SEEK;
            }
            return kSeekPlaced;
        }
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
        int placed = seek_to_byte(decoder, byte);
        if (placed != STREAM_DECODE_OK) return placed;

        /* Decode to the first frame so the caller gets audio, not an empty buffer. A byte seek
         * leaves the demuxer with no timestamp to report — there is nothing in the stream that
         * says what second this frame is — so the estimate IS the landed time. */
        int status = pump(decoder);
        if (past_last_frame(decoder, status, seconds)) {
            /* The estimate fell past the last frame's start (an ADTS stream sought to just before
             * its declared end) and the stream ended with nothing decoded, though audio remains
             * before that end. That is not the stream's end (issue #28). The demuxer's own seek
             * gets there exactly when it can within the budget. When it would walk further, or
             * cannot seek there at all, the estimate steps back and decodes on, from an eighth
             * of the budget and twice as far each time (media3's seekers step back so too), so
             * it lands at most about twice the overshoot early. Each failed step reads from its
             * byte to the end, so `kEndStepBacks` of them read at most about 64 budgets; past
             * that, which only a file with megabytes after its last frame reaches, the walk does
             * it whatever it costs, as an expensive seek beats one that reports the end. */
            avio_clear_latched_error(decoder);
            rc = budgeted_seek(decoder, INT64_MIN, target, target, AVSEEK_FLAG_BACKWARD, &walked);
            if (rc >= 0 && !walked) return kSeekPlaced;
            if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
            if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
            int64_t step = decoder->seek_budget / 8 > 0 ? decoder->seek_budget / 8 : 1;
            for (int steps = 0; steps < kEndStepBacks && byte > 0 && past_last_frame(decoder, status, seconds);
                 steps++, step *= 2) {
                avio_clear_latched_error(decoder);
                byte = byte > step ? byte - step : 0;
                ratio = (double)byte / (double)decoder->media_bytes;
                placed = seek_to_byte(decoder, byte);
                if (placed != STREAM_DECODE_OK) return placed;
                status = pump(decoder);
            }
            if (past_last_frame(decoder, status, seconds)) {
                avio_clear_latched_error(decoder);
                decoder->source_eof = 0;
                rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, target, target,
                                        AVSEEK_FLAG_BACKWARD);
                if (rc < 0) {
                    if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                    if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
                    return STREAM_DECODE_ERR_SEEK;
                }
                return kSeekPlaced;
            }
        }
        *landed_seconds = ratio * decoder->media_duration;
        return status;
    }
    return kSeekPlaced;
}

int stream_decoder_read(StreamDecoder *decoder, float *out, int max_frames, int *frames) {
    if (!decoder || !out || !frames || max_frames <= 0) return STREAM_DECODE_ERR_ARGS;
    *frames = 0;
    decoder->output_fixed = 1;
    int channels = decoder->out_channels;
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

/*
 * Only before the first read or seek. Before then nothing has been decoded: `pending` is empty, the
 * resampler has had no input and `position_frames` is 0, so rebuilding the resampler at the new
 * format loses nothing and every count afterwards is in the new grid. After it, `pending` and
 * `position_frames` hold the old grid and the resampler holds the old format's tail, which a
 * rebuild would drop; nothing needs that, so it is refused rather than half-supported.
 */
int stream_decoder_set_output(StreamDecoder *decoder, int sample_rate, int channels) {
    if (!decoder || sample_rate <= 0 || channels <= 0) return STREAM_DECODE_ERR_ARGS;
    if (decoder->output_fixed) return STREAM_DECODE_ERR_ARGS;
    int old_rate = decoder->out_rate, old_channels = decoder->out_channels;
    decoder->out_rate = sample_rate;
    decoder->out_channels = channels;
    /* Sized for the old channel count and empty (nothing has been decoded), so start it again. */
    free(decoder->pending);
    decoder->pending = NULL;
    decoder->pending_cap_floats = 0;
    pending_reset(decoder);
    int rc = init_swr(decoder);
    if (rc != STREAM_DECODE_OK) {
        /* A format swresample cannot build leaves the decoder as it was. */
        decoder->out_rate = old_rate;
        decoder->out_channels = old_channels;
        int restored = init_swr(decoder);
        return restored == STREAM_DECODE_OK ? rc : restored;
    }
    return STREAM_DECODE_OK;
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
    av_channel_layout_uninit(&decoder->swr_in_layout);
    avcodec_free_context(&decoder->dec);
    close_format(decoder);
    free(decoder->pending);
    free(decoder);
}
