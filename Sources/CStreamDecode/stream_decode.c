/*
 * stream_decode.c — see stream_decode.h.
 *
 * The open follows the usual libavformat order: open, best-effort find_stream_info,
 * find_best_stream, decoder, swresample. Around it is what a player needs and a whole-buffer decode
 * does not: a seekable AVIO over a blocking reader, a pull-at-a-time decode loop with its own state,
 * seek, and cancel. This file is the public API; the pieces are in the sibling files (decoder.h).
 */
#include "stream_decode.h"

#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>

#include "decoder.h"

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
    d->base_offset = sd_probe_id3_offset(d);
    if (d->cancelled) { local_status = STREAM_DECODE_ERR_CANCELLED; goto fail; }
    if (d->interrupted) { local_status = STREAM_DECODE_ERR_INTERRUPTED; goto fail; }

    local_status = sd_open_format(d, options);
    if (local_status == STREAM_DECODE_ERR_NO_AUDIO || local_status == STREAM_DECODE_ERR_OPEN) {
        local_status = sd_reopen_past_mp3_junk(d, options, local_status);
        if (local_status == STREAM_DECODE_ERR_NO_AUDIO || local_status == STREAM_DECODE_ERR_OPEN) {
            local_status = sd_reopen_single_frame_mp3(d, options, local_status);
        }
    }
    if (local_status != STREAM_DECODE_OK) goto fail;
    local_status = sd_skip_unscanned_junk(d, options);
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
     * last frame whole, so the decode runs up to a frame past the duration the edit list declares.
     * AVAssetReader stops at that duration; so do we. */
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
     * scripts/ffmpeg-patches/0001 fixes. A length-less MP3 with no Xing tag reports 0,
     * and the caller falls back to whatever duration it has from elsewhere. */
    if (d->fmt->duration != AV_NOPTS_VALUE) {
        info->duration_sec = (double)d->fmt->duration / (double)AV_TIME_BASE;
    } else if (stream->duration != AV_NOPTS_VALUE) {
        info->duration_sec = (double)stream->duration * av_q2d(stream->time_base);
    }
    if (d->phantom_len) info->duration_sec = (double)d->phantom_samples / (double)d->sample_rate;
    info->duration_sec = sd_aac_audio_duration(d, info->duration_sec);
    /* Kept for the byte-estimate seek: what the media occupies in bytes and how long it lasts. */
    {
        int64_t seen = sd_avio_size_seen(d) - d->phantom_len;
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
    sd_close_format(decoder);
    free(decoder->pending);
    free(decoder);
}
