/*
 * resample.c — the resampler and the pending PCM buffer it fills.
 */
#include <stdlib.h>

#include "decoder.h"

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
int sd_convert_through_swr(StreamDecoder *d, AVFrame *frame) {
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

/* `frame` through the resampler, reconfiguring it first when the frame's input format differs.
 * `lead` receives how many pending frames precede this frame's own output: what the old resampler
 * flushed. Returns a status. */
int sd_push_through_swr(StreamDecoder *d, AVFrame *frame, int *lead) {
    *lead = 0;
    if (frame && (frame->sample_rate != d->swr_in_rate
                  || frame->format != d->swr_in_fmt
                  || av_channel_layout_compare(&frame->ch_layout, &d->swr_in_layout) != 0)
        && frame->sample_rate > 0 && frame->ch_layout.nb_channels > 0) {
        /* The stream changed rate, layout or sample format mid-way (stitched audio): hand out
         * what the old resampler still holds, then take the new input to the unchanged output. */
        if (!sd_convert_through_swr(d, NULL)) return STREAM_DECODE_ERR_ALLOC;
        *lead = d->pending_frames;
        int rc = init_swr_from(d, frame->sample_rate, frame->format, &frame->ch_layout);
        if (rc != STREAM_DECODE_OK) return rc;
    }
    return sd_convert_through_swr(d, frame) ? STREAM_DECODE_OK : STREAM_DECODE_ERR_ALLOC;
}

void sd_pending_reset(StreamDecoder *d) {
    d->pending_frames = 0;
    d->pending_offset = 0;
}
