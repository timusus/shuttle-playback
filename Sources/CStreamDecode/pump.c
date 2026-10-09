/*
 * pump.c — the decode pump: packets in, resampled PCM into `pending`, and the codec it drives.
 */
#include <string.h>

#include "decoder.h"

static int is_mpeg_audio(enum AVCodecID codec_id) {
    return codec_id == AV_CODEC_ID_MP3 || codec_id == AV_CODEC_ID_MP2 || codec_id == AV_CODEC_ID_MP1;
}

/* The demuxer has given the stream new parameters the open codec has not seen: the next link of a
 * chained Ogg Opus file. FFmpeg 7.1's Ogg demuxer writes the new link's OpusHead (channel
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

/* What the `sd_pump` helpers return for "nothing to report yet, go round again"; every real status
 * is >= 0. */
enum { PUMP_AGAIN = -1 };

/*
 * A frame the codec produced, through the seek discard, the edit-list clip and the resampler into
 * `pending`. `skip` is the output frames still to drop before the seek target, when the frame it
 * fell in came out of the resampler shorter than the cut (a resampler holds the last few samples
 * back). Returns STREAM_DECODE_OK when `pending` holds audio, PUMP_AGAIN to ask for another frame,
 * or an error status.
 */
static int pump_decoded_frame(StreamDecoder *d, int64_t *skip) {
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
                return PUMP_AGAIN;
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
            return PUMP_AGAIN;
        }
        if (room < d->frame->nb_samples) d->frame->nb_samples = (int)room;
    }
    d->last_frame_pts = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE
        : pts + av_rescale_q(cut, (AVRational){ 1, rate }, d->time_base);
    int lead = 0;
    int ok = sd_push_through_swr(d, d->frame, &lead);
    av_frame_unref(d->frame);
    if (ok != STREAM_DECODE_OK) return ok;
    /* Same rate in and out, so the resampler holds nothing back: frame sample N is
     * pending frame N. At another rate (a mid-stream change, or a fixed output format) it
     * is the same instant at the output rate, behind whatever the old resampler flushed
     * when the rate changed, which is kept: it is the end of the audio before this frame,
     * unless the seek target is in this frame. */
    if (landing) {
        *skip += lead + (rate == d->out_rate ? cut
            : av_rescale_q(cut, (AVRational){ 1, rate }, (AVRational){ 1, d->out_rate }));
    }
    d->pending_offset = *skip < d->pending_frames ? (int)*skip : d->pending_frames;
    *skip -= d->pending_offset;
    if (d->pending_frames > d->pending_offset) return STREAM_DECODE_OK;
    sd_pending_reset(d);
    return PUMP_AGAIN;   /* the resampler is still filling; ask for another frame */
}

/* The old link is drained: the held packet goes to a codec opened on the new one. The
 * resampler follows its frames' new layout (`sd_push_through_swr`). The demuxer sets only
 * the new link's channel count, leaving the old link's mask (mono with 2 channels),
 * which the codec refuses: the count is kept, and the codec reads its layout from the
 * OpusHead. */
static int pump_reopen_codec(StreamDecoder *d) {
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
    return PUMP_AGAIN;
}

/* The decoder is drained; whatever libswresample still holds is the last of it. */
static int pump_finish(StreamDecoder *d) {
    if (!sd_convert_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
    d->ended = 1;
    return d->pending_frames > 0 ? STREAM_DECODE_OK : STREAM_DECODE_EOF;
}

/* A frame the codec cannot decode is a glitch, not the end of the recording: skip it
 * like a rejected packet. Out of memory is not the stream's fault, and a run of
 * MAX_CONSECUTIVE_DECODE_ERRORS failures with no good frame between is garbage, not
 * damage, so that ends with an error rather than spinning to the end of the file. */
static int pump_decode_error(StreamDecoder *d, int rc) {
    if (rc == AVERROR(ENOMEM)) return STREAM_DECODE_ERR_ALLOC;
    if (++d->decode_errors > MAX_CONSECUTIVE_DECODE_ERRORS) return STREAM_DECODE_ERR_DECODER;
    return PUMP_AGAIN;
}

/* The codec wants input: the next audio packet (the held one first) to it, or the end of the
 * source to it as a NULL packet. Returns PUMP_AGAIN or an error status. */
static int pump_feed_packet(StreamDecoder *d) {
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
            return PUMP_AGAIN;
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
        return PUMP_AGAIN;
    }
    sd_aac_packet_read(d, d->pkt);
    if (!d->reopening && codec_parameters_changed(d)) {
        /* Drain the old codec first (Opus holds back resampled SILK samples), then reopen. */
        av_packet_move_ref(d->held, d->pkt);
        d->has_held = 1;
        d->reopening = 1;
        avcodec_send_packet(d->dec, NULL);
        d->flushing = 1;
        return PUMP_AGAIN;
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
    return PUMP_AGAIN;
}

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
    int64_t skip = 0;

    for (;;) {
        if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
        /* Harmless while a reopen drains the codec: nothing reads the source then. */
        if (d->interrupted && !d->reopening) return STREAM_DECODE_ERR_INTERRUPTED;

        int rc = avcodec_receive_frame(d->dec, d->frame);
        int status;
        if (rc == 0) status = pump_decoded_frame(d, &skip);
        else if (rc == AVERROR_EOF && d->reopening) status = pump_reopen_codec(d);
        else if (rc == AVERROR_EOF) status = pump_finish(d);
        else if (rc != AVERROR(EAGAIN)) status = pump_decode_error(d, rc);
        /* EAGAIN after a NULL packet cannot happen, but treat it as the end rather than
         * looping: an unbounded loop here is a hung player. */
        else if (d->flushing) status = pump_finish(d);
        else status = pump_feed_packet(d);
        if (status != PUMP_AGAIN) return status;
    }
}

/* Keep `d->held`, the first audio packet, for the decoder, and let the stream's seek strategy note
 * what it needs from it (an MP3 counts every frame from it). */
void sd_hold_first_packet(StreamDecoder *d) {
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

/* Hold the stream's first audio packet (`sd_hold_first_packet`), reading it unless it already is. No
 * packet at all is the decode's to report, not the open's: STREAM_DECODE_OK with nothing held. A
 * cancelled or interrupted read is the open's. */
int sd_hold_first_audio_packet(StreamDecoder *d) {
    if (d->has_held) return STREAM_DECODE_OK;
    if (sd_read_audio_packet(d) < 0) return sd_read_failure_status(d);
    sd_hold_first_packet(d);
    return STREAM_DECODE_OK;
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
