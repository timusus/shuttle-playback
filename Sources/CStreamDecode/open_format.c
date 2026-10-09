/*
 * open_format.c — opening libavformat over the reader and finding the audio stream, and undoing it.
 */
#include <string.h>

#include "decoder.h"

/* Undo `sd_open_format`: the format context and the AVIO context it reads through. */
void sd_close_format(StreamDecoder *d) {
    if (d->fmt) avformat_close_input(&d->fmt);
    /* avformat_close_input frees the format context but not the AVIO one, and libavformat may have
     * replaced the buffer we handed it, so free the CURRENT pointer. */
    if (d->avio) {
        av_freep(&d->avio->buffer);
        avio_context_free(&d->avio);
    }
    d->audio_idx = -1;
}

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
int sd_open_format(StreamDecoder *d, const StreamDecodeOptions *options) {
    const int avio_buf_size = 32 * 1024;
    uint8_t *avio_buf = (uint8_t *)av_malloc(avio_buf_size);
    if (!avio_buf) return STREAM_DECODE_ERR_ALLOC;

    /* Read AND seek: with a NULL seek callback `pb->seekable` is 0 and the mov demuxer walks the
     * whole `mdat` to find a trailing `moov` (see the header). */
    d->avio = avio_alloc_context(avio_buf, avio_buf_size, 0, d, sd_avio_read_packet, NULL,
                                 sd_avio_seek_packet);
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
    /* With no total length, stop the MP4 header at the moov and mdat. mov reads root
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
    /* Skipped when the header already describes a lossless stream: the probe's
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
     * somewhere else. Such an open fails, and opening again costs only the probe. */
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;

    d->audio_idx = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (d->audio_idx < 0) return STREAM_DECODE_ERR_NO_AUDIO;
    d->seek_fmt = sd_seek_format_for(d);
    return STREAM_DECODE_OK;
}
