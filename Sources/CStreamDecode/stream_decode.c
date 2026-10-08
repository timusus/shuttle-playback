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

#include "decoder.h"

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
    int n;
    if (d->lead_pos < d->lead_len) {
        n = d->lead_len - d->lead_pos;
        if (n > buf_size) n = buf_size;
        memcpy(buf, d->lead + d->lead_pos, (size_t)n);
        d->lead_pos += n;
    } else {
        n = d->cb.read(d->opaque, buf, buf_size);
    }
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
        if (!sd_mp3_parse_header(d->prologue + p, &spf, &br, &sr, &side)) continue;
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

    d->lead_len = d->lead_pos = 0;   /* the reader is repositioned: the unread lead is stale */
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
    int have = 0;   /* header bytes read at `offset` */
    uint8_t header[10];
    for (;;) {
        int got = 0;
        have = 0;
        while (got < (int)sizeof(header)) {
            int n = d->cb.read(d->opaque, header + got, (int)sizeof(header) - got);
            if (n > 0) have += n;
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
        int rc = d->cb.seek(d->opaque, offset);
        if (rc == STREAM_READ_UNSEEKABLE) {
            /* A reader that refuses even a forward seek: the 10 header bytes are consumed, so
             * read and discard the rest of the tag (media3's DefaultExtractorInput.skip does the
             * same when it cannot seek). */
            int64_t left = span - (int64_t)sizeof(header);
            uint8_t sink[1024];
            while (left > 0) {
                int n = d->cb.read(d->opaque, sink, left < (int64_t)sizeof(sink) ? (int)left : (int)sizeof(sink));
                if (n == STREAM_READ_CANCELLED) d->cancelled = 1;
                if (n == STREAM_READ_INTERRUPTED) d->interrupted = 1;
                if (n <= 0) return 0;
                left -= n;
            }
            rc = 0;
        }
        if (rc == STREAM_READ_CANCELLED) d->cancelled = 1;
        if (rc == STREAM_READ_INTERRUPTED) d->interrupted = 1;
        if (rc != 0) return 0;
    }
    /* Either there was no tag or the last read was past the last one: go back to where the media
     * (or the file) starts. */
    int rc = d->cb.seek(d->opaque, offset);
    if (rc != 0) {
        /* A forward-only source cannot go back over the bytes just read; hand them to libavformat
         * from here instead of losing them (media3's DefaultExtractorInput peeks the same way).
         * A cancel or interruption is the seek's own result, not a refusal: latch it and stop. */
        if (rc == STREAM_READ_CANCELLED) d->cancelled = 1;
        if (rc == STREAM_READ_INTERRUPTED) d->interrupted = 1;
        if (d->cancelled || d->interrupted || have == 0) return 0;
        memcpy(d->lead, header, (size_t)have);
        d->lead_len = have;
        d->lead_pos = 0;
    }
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

int sd_init_swr(StreamDecoder *d) {
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

void sd_pending_reset(StreamDecoder *d) {
    d->pending_frames = 0;
    d->pending_offset = 0;
}

static void hold_first_packet(StreamDecoder *d);

static int is_mpeg_audio(enum AVCodecID codec_id) {
    return codec_id == AV_CODEC_ID_MP3 || codec_id == AV_CODEC_ID_MP2 || codec_id == AV_CODEC_ID_MP1;
}

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
int sd_pump(StreamDecoder *d) {
    sd_pending_reset(d);
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
            sd_aac_frame_decoded(d);
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
            sd_pending_reset(d);
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
            int codec_rc = sd_reopen_codec(d);
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
        sd_aac_packet_read(d, d->pkt);
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
        if (d->seek_fmt->packet_fed) d->seek_fmt->packet_fed(d, d->pkt);
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
    d->seek_fmt = &sd_seek_generic;

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

    local_status = sd_open_codec(d, codec, 0, &d->dec);
    if (local_status != STREAM_DECODE_OK) goto fail;

    d->sample_rate = d->dec->sample_rate > 0 ? d->dec->sample_rate : par->sample_rate;
    d->channels = d->dec->ch_layout.nb_channels > 0 ? d->dec->ch_layout.nb_channels
                                                    : par->ch_layout.nb_channels;
    if (d->sample_rate <= 0 || d->channels <= 0) { local_status = STREAM_DECODE_ERR_DECODER; goto fail; }
    d->out_rate = d->sample_rate;
    d->out_channels = d->channels;
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
    /* An AAC stream's priming and decoder trim move time zero (seek_aac.c). */
    local_status = sd_aac_open(d, par);
    if (local_status != STREAM_DECODE_OK) goto fail;

    local_status = sd_init_swr(d);
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
    if (d->aac.prime_skip > 0 && info->duration_sec > 0) {
        info->duration_sec -= (double)d->aac.prime_skip / (double)d->sample_rate;   /* the priming is not audio */
        if (info->duration_sec < 0) info->duration_sec = 0;
    }
    if (d->decoder_trim > 0 && info->duration_sec > 0) {
        info->duration_sec -= (double)d->decoder_trim * av_q2d(d->time_base);   /* the decoder's own trim is not audio either (issue #66) */
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
            d->seek_fmt = sd_seek_format_for(d);
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
    d->seek_fmt = sd_seek_format_for(d);
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
    if (!sd_mp3_parse_header(p, &spf, &bitrate, &rate, &side)) return 0;
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
        || !sd_mp3_parse_header(d->prologue, &spf, &bitrate, &rate, &side)) {
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

    /* No packet at all is the decode's to report, not the open's; an interrupted or cancelled read
     * is the open's. */
    if (sd_read_audio_packet(d) < 0) return sd_read_failure_status(d);
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
    int rc = reopen_seek(d, d->base_offset);
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
    return sd_hold_first_audio_packet(d);
}

/* ── reading packets ─────────────────────────────────────────────────────── */

/* Keep `d->held`, the first audio packet, for the decoder, and let the stream's seek strategy note
 * what it needs from it (an MP3 counts every frame from it). */
static void hold_first_packet(StreamDecoder *d) {
    d->has_held = 1;
    d->first_pkt_pos = d->held->pos;
    d->first_pkt_dts = d->held->dts;
    d->has_first_pkt = d->held->pos >= 0 && d->held->dts != AV_NOPTS_VALUE;
    if (d->seek_fmt->first_packet) d->seek_fmt->first_packet(d);
}

/* Read the audio stream's next packet into `held`, dropping any other stream's on the way. Returns
 * `av_read_frame`'s result. */
int sd_read_audio_packet(StreamDecoder *d) {
    int rc;
    while ((rc = av_read_frame(d->fmt, d->held)) >= 0 && d->held->stream_index != d->audio_idx) {
        av_packet_unref(d->held);
    }
    return rc;
}

/* After a read that failed or came up short: a cancel or an interruption is returned as itself, and
 * anything else is cleared from the AVIO context (`avio_clear_latched_error`) so the next read asks
 * the source again, and the caller carries on (STREAM_DECODE_OK). */
int sd_read_failure_status(StreamDecoder *d) {
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
    sd_avio_clear_latched_error(d);
    return STREAM_DECODE_OK;
}

/* Hold the stream's first audio packet (`hold_first_packet`), reading it unless it already is. No
 * packet at all is the decode's to report, not the open's: STREAM_DECODE_OK with nothing held. A
 * cancelled or interrupted read is the open's. */
int sd_hold_first_audio_packet(StreamDecoder *d) {
    if (d->has_held) return STREAM_DECODE_OK;
    if (sd_read_audio_packet(d) < 0) return sd_read_failure_status(d);
    hold_first_packet(d);
    return STREAM_DECODE_OK;
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
void sd_avio_clear_latched_error(StreamDecoder *d) {
    if (!d->avio) return;
    d->avio->error = 0;
    d->avio->eof_reached = 0;
}

/*
 * A codec for the audio stream, opened as every one here is: one thread, since FFmpeg's audio
 * decoders have no frame threading to gain from and the pull loop is single-threaded by contract;
 * and the stream's time base as the packets', without which the codec cannot move a frame's
 * timestamp past the encoder delay it trims (decode.c discard_samples), and the first frame after
 * the start is labelled as though the trimmed samples were still in it. `flags2` is added to the
 * context's. Returns STREAM_DECODE_OK with `*out` set, or STREAM_DECODE_ERR_ALLOC or _DECODER.
 */
int sd_open_codec(const StreamDecoder *d, const AVCodec *codec, int flags2, AVCodecContext **out) {
    const AVStream *stream = d->fmt->streams[d->audio_idx];
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    if (!dec) return STREAM_DECODE_ERR_ALLOC;
    if (avcodec_parameters_to_context(dec, stream->codecpar) < 0) {
        avcodec_free_context(&dec);
        return STREAM_DECODE_ERR_DECODER;
    }
    dec->thread_count = 1;
    dec->pkt_timebase = stream->time_base;
    dec->flags2 |= flags2;
    if (avcodec_open2(dec, codec, NULL) < 0) {
        avcodec_free_context(&dec);
        return STREAM_DECODE_ERR_DECODER;
    }
    *out = dec;
    return STREAM_DECODE_OK;
}

/* Replace the codec with a freshly opened one, for a seek strategy whose codec outlives a flush. */
int sd_reopen_codec(StreamDecoder *d) {
    AVCodecContext *dec = NULL;
    int rc = sd_open_codec(d, d->dec->codec, 0, &dec);
    if (rc != STREAM_DECODE_OK) return rc;
    avcodec_free_context(&d->dec);
    d->dec = dec;
    return STREAM_DECODE_OK;
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
            status = sd_pump(decoder);
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
    sd_pending_reset(decoder);
    int rc = sd_init_swr(decoder);
    if (rc != STREAM_DECODE_OK) {
        /* A format swresample cannot build leaves the decoder as it was. */
        decoder->out_rate = old_rate;
        decoder->out_channels = old_channels;
        int restored = sd_init_swr(decoder);
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
