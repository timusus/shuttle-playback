/*
 * seek.c — `stream_decoder_seek`: the resume, the pre-roll, the placement ladder with its byte budget
 * and fallbacks, and the sample-accurate landing, in one place for every format. What a format
 * answers differently is asked of its `SeekFormat` (seek.h); the ladder itself is not.
 */
#include <math.h>
#include <string.h>

#include "decoder.h"

const SeekFormat *sd_seek_format_for(const StreamDecoder *d) {
    const char *name = d->fmt->iformat ? d->fmt->iformat->name : NULL;
    if (name && strstr(name, "mp3")) return &sd_seek_mp3;
    if (name && strcmp(name, "flac") == 0) return &sd_seek_flac;
    if (name && strcmp(name, "ogg") == 0) return &sd_seek_ogg;
    enum AVCodecID codec = d->fmt->streams[d->audio_idx]->codecpar->codec_id;
    if (codec == AV_CODEC_ID_AAC || codec == AV_CODEC_ID_AAC_LATM) return &sd_seek_aac;
    return &sd_seek_generic;
}

/* The status of a failed seek: a cancel, then an interruption, else the seek itself failed. */
static int seek_failure(const StreamDecoder *d) {
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
    return STREAM_DECODE_ERR_SEEK;
}

/* Finish a seek: flush the codec and the resampler and clear the pull loop's state. */
static void after_seek_reset(StreamDecoder *d) {
    avcodec_flush_buffers(d->dec);
    sd_pending_reset(d);
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
    if (d->seek_fmt->reset) d->seek_fmt->reset(d);
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
     * neither (ogg) seeks by bisection, which lands on a page, not a packet, and says whether
     * that finds the packet (`can_resume`). */
    if (d->seek_fmt->can_resume && !d->seek_fmt->can_resume(d)) return STREAM_DECODE_ERR_SEEK;
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
    return seek_failure(d);
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
    if (*walked) sd_avio_clear_latched_error(d);
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
    return sd_init_swr(d);
}

static int seek_to(StreamDecoder *decoder, double seconds, double *landed_seconds);
static int place_demuxer(StreamDecoder *decoder, double seconds, int64_t target, double *landed_seconds,
                         SeekPlan *plan, int *anchored);
static int land_exactly(StreamDecoder *d, int64_t target, int anchored);

/* `place_demuxer`'s "the demuxer is placed, land by the timestamps" result; no STREAM_DECODE_ code. */
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

/* How far before its target a seek puts the demuxer, in samples (the format's answer). */
static int64_t seek_preroll_samples(const StreamDecoder *d) {
    if (d->seek_fmt->preroll_samples) return d->seek_fmt->preroll_samples(d);
    return sd_generic_preroll_samples(d);
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
    sd_avio_clear_latched_error(decoder);
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
        sd_avio_clear_latched_error(decoder);
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
     * A pre-roll is placed again too when the format says the frames it fed the codec fell short
     * (`preroll_short`: an MP3 whose frames do not hold the bit reservoir the frames from the
     * target need, `mp3_measure_preroll`), which the frame count `seek_preroll_samples` takes from
     * one frame's bitrate cannot promise. Each placement goes four times further back; three
     * re-placements reach 64 times the first pre-roll, 192 frames at the least, which covers frames
     * carrying as little as 2 bytes of main data each (the least a Layer III frame without a CRC
     * carries is 3, at 8 kbps and 24 kHz in stereo). */
    int64_t back = preroll;
    for (int attempt = 0;; attempt++, back *= 4) {
        int64_t from = target - back;
        /* Never a decode from the start just to be exact: on a long file that is the whole
         * file (12 MB measured). After two re-placements the landing stands, reported as it is. */
        int last = attempt >= 2;
        int from_start = from <= decoder->start_time;
        /* From the first packet, which a decoder trim (issue #63) puts before time zero. */
        if (from_start) from = decoder->start_time - sd_aac_first_packet_trim(decoder);
        SeekPlan plan;
        int anchored = 0;
        int placed = place_demuxer(decoder, seconds, from, landed_seconds, &plan, &anchored);
        if (placed != kSeekPlaced) return placed;

        decoder->seek_from = from;
        /* A frame further before the target than a seek may decode lands where it is, at the time
         * its header gives, rather than at the target with the audio elsewhere (FLAC, issue #42). */
        int64_t land_at = plan.land_at != AV_NOPTS_VALUE ? plan.land_at : target;
        int status = land_exactly(decoder, land_at, anchored);
        if (status == STREAM_DECODE_OK && !from_start && !last && decoder->seek_first_pts != AV_NOPTS_VALUE
            && decoder->seek_first_pts > target) {
            continue;
        }
        if (status == STREAM_DECODE_OK && !from_start && attempt < 3 && decoder->seek_fmt->preroll_short
            && decoder->seek_fmt->preroll_short(decoder)) {
            continue;
        }
        /* Past the fourth placement the landing stands even if the pre-roll is still short: the
         * frames from the target on then decode from a reservoir the pre-roll never fed, so this
         * seek is not sample-exact. The engine has no diagnostic channel for it (libav's log is
         * silenced and a seek's result has no field for it), and 64 times the first pre-roll
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

/* Set the decoder going from where the demuxer was just put (`anchored`: at the plan's anchor): a
 * clean codec, the format's own landing, and every frame before `target` dropped. Returns
 * `sd_pump`'s status. */
static int land_exactly(StreamDecoder *d, int64_t target, int anchored) {
    after_seek_reset(d);
    if (d->seek_fmt->reopens_codec && d->seek_fmt->reopens_codec(d)) {
        int codec_rc = sd_reopen_codec(d);
        if (codec_rc != STREAM_DECODE_OK) return codec_rc;
    }
    int swr_rc = sd_init_swr(d);   /* drop whatever the resampler still held from before */
    if (swr_rc != STREAM_DECODE_OK) return swr_rc;
    d->landing_exact = 1;
    if (d->seek_fmt->landed) {
        int rc = d->seek_fmt->landed(d, anchored);
        if (rc != STREAM_DECODE_OK) return rc;
    }
    d->discard_until = target;
    return sd_pump(d);
}

/*
 * Put the demuxer at or before `target` (stream time base), within the seek byte budget.
 *
 * Returns `kSeekPlaced` when the packets that follow carry timestamps to land by, with `*plan` as
 * the format placed it and `*anchored` set when the demuxer is at its anchor; and otherwise the
 * seek's final status with `*landed_seconds` set: a byte estimate (no timestamps to land by), the
 * end of the stream, or an error. `seconds` is the caller's request, which the estimate uses.
 *
 * The ladder, in order: the format's placement (an anchor of known time, or a timestamp to seek
 * to) under the byte budget; when that fails or walks, the format's estimate anchor (FLAC); with no
 * length to estimate from, the paid walk; else the byte estimate, stepping back when it falls past
 * the last frame, then the walk.
 */
static int place_demuxer(StreamDecoder *decoder, double seconds, int64_t target, double *landed_seconds,
                         SeekPlan *plan, int *anchored) {
    const SeekFormat *format = decoder->seek_fmt;
    int fmt_flags = decoder->fmt->flags;
    int64_t seek_min = INT64_MIN;
    int seek_flags = AVSEEK_FLAG_BACKWARD;
    *plan = (SeekPlan){ .anchor_pos = -1, .anchor_dts = AV_NOPTS_VALUE, .seek_ts = target,
                        .land_at = AV_NOPTS_VALUE };
    *anchored = 0;
    if (format->place) {
        int found = format->place(decoder, target, plan);
        if (found != STREAM_DECODE_OK) return found;
    }
    /* A frame whose place and time are both known goes into the index with its time, and the
     * generic seek, which AVSEEK_FLAG_ANY and an exact timestamp make go straight to it, takes the
     * time from there. */
    if (plan->anchor_pos >= 0 && plan->anchor_dts != AV_NOPTS_VALUE) {
        av_add_index_entry(decoder->fmt->streams[decoder->audio_idx], plan->anchor_pos, plan->anchor_dts,
                           0, 0, AVINDEX_KEYFRAME);
        decoder->fmt->flags &= ~AVFMT_FLAG_FAST_SEEK;
        seek_min = plan->seek_ts = plan->anchor_dts;
        seek_flags = AVSEEK_FLAG_ANY;
        *anchored = 1;
    }
    int64_t seek_ts = plan->seek_ts;

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
        if (format->has_estimate_anchor && format->has_estimate_anchor(decoder)) {
            /* A format that never takes the byte estimate (native FLAC: it would report the target
             * over audio from wherever the byte falls, issue #54). The anchored seek failed (a read
             * error) or there was no anchor to place, so one bounded probe at the byte estimate
             * finds a frame whose time is known (`flac_estimate_anchor`) and the seek anchors on
             * it. Only when the probe finds no frame does the demuxer's own bisection, which reads
             * frame headers for their times, place it at whatever cost, as an expensive seek beats
             * one that reports the wrong place. */
            sd_avio_clear_latched_error(decoder);
            decoder->source_eof = 0;
            *anchored = 0;
            *plan = (SeekPlan){ .anchor_pos = -1, .anchor_dts = AV_NOPTS_VALUE, .seek_ts = target,
                                .land_at = AV_NOPTS_VALUE };
            double est_ratio = seconds / decoder->media_duration;
            if (est_ratio < 0) est_ratio = 0;
            if (est_ratio > 1) est_ratio = 1;
            int est = format->estimate_anchor(decoder, est_ratio, target, plan);
            if (est != STREAM_DECODE_OK) return est;
            if (plan->anchor_pos >= 0) {
                int64_t est_dts = plan->anchor_dts;
                av_add_index_entry(decoder->fmt->streams[decoder->audio_idx], plan->anchor_pos, est_dts,
                                   0, 0, AVINDEX_KEYFRAME);
                decoder->fmt->flags &= ~AVFMT_FLAG_FAST_SEEK;
                *anchored = 1;
                int est_walked = 0;
                rc = budgeted_seek(decoder, est_dts, est_dts, est_dts, AVSEEK_FLAG_ANY, &est_walked);
                decoder->fmt->flags = fmt_flags;
                if (rc >= 0 && !est_walked) return kSeekPlaced;
                if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
                sd_avio_clear_latched_error(decoder);
                decoder->source_eof = 0;
                *anchored = 0;
                plan->land_at = AV_NOPTS_VALUE;
            }
            rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, target, target,
                                    AVSEEK_FLAG_BACKWARD);
            if (rc < 0) return seek_failure(decoder);
            return kSeekPlaced;
        }
        if (!sd_can_estimate_bytes(decoder)) {
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
            *anchored = 0;
            rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, target, target,
                                    AVSEEK_FLAG_BACKWARD);
            if (rc < 0) {
                if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
                return STREAM_DECODE_ERR_SEEK;
            }
            return kSeekPlaced;
        }
        *anchored = 0;

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
        int status = sd_pump(decoder);
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
            sd_avio_clear_latched_error(decoder);
            rc = budgeted_seek(decoder, INT64_MIN, target, target, AVSEEK_FLAG_BACKWARD, &walked);
            if (rc >= 0 && !walked) return kSeekPlaced;
            if (decoder->cancelled) return STREAM_DECODE_ERR_CANCELLED;
            if (decoder->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
            int64_t step = decoder->seek_budget / 8 > 0 ? decoder->seek_budget / 8 : 1;
            for (int steps = 0; steps < kEndStepBacks && byte > 0 && past_last_frame(decoder, status, seconds);
                 steps++, step *= 2) {
                sd_avio_clear_latched_error(decoder);
                byte = byte > step ? byte - step : 0;
                ratio = (double)byte / (double)decoder->media_bytes;
                placed = seek_to_byte(decoder, byte);
                if (placed != STREAM_DECODE_OK) return placed;
                status = sd_pump(decoder);
            }
            if (past_last_frame(decoder, status, seconds)) {
                sd_avio_clear_latched_error(decoder);
                decoder->source_eof = 0;
                rc = avformat_seek_file(decoder->fmt, decoder->audio_idx, INT64_MIN, target, target,
                                        AVSEEK_FLAG_BACKWARD);
                if (rc < 0) return seek_failure(decoder);
                return kSeekPlaced;
            }
        }
        *landed_seconds = ratio * decoder->media_duration;
        return status;
    }
    return kSeekPlaced;
}
