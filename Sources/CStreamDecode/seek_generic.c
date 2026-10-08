/*
 * seek_generic.c — the seek every other stream gets (see seek.h): the demuxer's own placement by its
 * index or timestamps, and a pre-roll by codec. mov (AAC aside), WAV, AIFF and Matroska seek so.
 */
#include "decoder.h"

/* How far before its target a seek puts the demuxer, in samples, so the codec has converged by the
 * target: an MP3's bit reservoir spans a few frames (more at a low VBR quality), and Opus's CELT
 * state takes about 30000 samples after a reset to decode bit-identically to an unbroken run. */
int64_t sd_generic_preroll_samples(const StreamDecoder *d) {
    if (d->dec->codec_id == AV_CODEC_ID_OPUS) return 32768;
    /* Every FLAC frame decodes on its own: nothing before the target's frame is needed. */
    if (d->dec->codec_id == AV_CODEC_ID_FLAC) return 0;
    return 16384;
}

const SeekFormat sd_seek_generic = {
    .name = "generic",
};
