/*
 * seek_aac.c — how an AAC stream seeks, and where its time zero is (see seek.h).
 *
 * The demuxer places an AAC seek by its index (mov) or by bytes (ADTS); what is AAC's own is the
 * pre-roll an SBR stream needs, the codec that does not survive a flush, and time zero: after the
 * encoder priming a fragmented MP4 does not declare (issue #25) and after the frame the decoder
 * drops on its own (issue #63), as media3's Mp4Extractor puts it at the first sample left.
 */
#include <stdio.h>
#include <string.h>

#include "decoder.h"

/* HE-AAC v1 or v2: AAC with SBR. The AAC codec sets the profile per frame, from what it decoded. */
static int is_sbr(enum AVCodecID codec_id, int profile) {
    return codec_id == AV_CODEC_ID_AAC
        && (profile == AV_PROFILE_AAC_HE || profile == AV_PROFILE_AAC_HE_V2);
}

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

/*
 * Samples the AAC decoder drops from the start of the first packet on its own (issue #63). It
 * recognises a libfaac stream by the encoder string in the first frame's fill element and drops
 * that frame, 1024 samples, with no skip-samples side data to say so, so the first audio comes out
 * a frame after the first packet's timestamp. A throwaway decoder with AV_CODEC_FLAG2_SKIP_MANUAL
 * decodes the held packet and reports the drop instead of making it. Packet side data overrides
 * the decoder's count, and the demuxer's start_time already includes it, so such a packet is 0.
 * In time base units.
 */
static int64_t aac_decoder_trim(const StreamDecoder *d, const AVCodecParameters *par) {
    if (av_packet_get_side_data(d->held, AV_PKT_DATA_SKIP_SAMPLES, NULL)) return 0;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    AVCodecContext *dec = NULL;
    AVFrame *frame = av_frame_alloc();
    int64_t trim = 0;
    if (codec && frame && sd_open_codec(d, codec, AV_CODEC_FLAG2_SKIP_MANUAL, &dec) == STREAM_DECODE_OK) {
        if (avcodec_send_packet(dec, d->held) >= 0 && avcodec_receive_frame(dec, frame) >= 0) {
            const AVFrameSideData *sd = av_frame_get_side_data(frame, AV_FRAME_DATA_SKIP_SAMPLES);
            if (sd && sd->size >= 4) {
                uint32_t skip = (uint32_t)sd->data[0] | (uint32_t)sd->data[1] << 8
                              | (uint32_t)sd->data[2] << 16 | (uint32_t)sd->data[3] << 24;
                if (skip < 16384 && frame->sample_rate > 0) {   /* output samples, the SBR rate for HE-AAC */
                    trim = av_rescale_q(skip, (AVRational){ 1, frame->sample_rate }, d->time_base);
                }
            }
        }
    }
    av_frame_free(&frame);
    avcodec_free_context(&dec);
    return trim;
}

int sd_aac_open(StreamDecoder *d, const AVCodecParameters *par) {
    d->aac.sbr = is_sbr(par->codec_id, par->profile);
    d->aac.prime_skip = mp4_aac_prime_skip(d, par);
    if (d->aac.prime_skip > 0) {
        /* Does the file's edit list already skip its priming? It shows as skip-samples side data
         * on the first packet, which is kept for the decoder. If not, the audio starts after the
         * priming, so that is where time zero is. */
        int rc = sd_hold_first_audio_packet(d);
        if (rc != STREAM_DECODE_OK) return rc;
        if (!d->has_held || av_packet_get_side_data(d->held, AV_PKT_DATA_SKIP_SAMPLES, NULL) ||
            d->held->pts != d->start_time) {
            d->aac.prime_skip = 0;
        } else {
            d->aac.prime_start = d->held->pts;
            d->start_time += av_rescale_q(d->aac.prime_skip, (AVRational){ 1, d->sample_rate },
                                          d->time_base);
        }
    }
    if (d->aac.prime_skip == 0 && (par->codec_id == AV_CODEC_ID_AAC || par->codec_id == AV_CODEC_ID_AAC_LATM)) {
        /* Time zero is where the first audio comes out, after whatever the decoder drops on its
         * own (`aac_decoder_trim`), as media3's Mp4Extractor puts it at the first sample the edit
         * list and the gapless trim leave: a seek to 0 lands on the clean decode's first frame. A
         * decode from the start still begins at the first packet (`seek_to`). */
        int rc = sd_hold_first_audio_packet(d);
        if (rc != STREAM_DECODE_OK) return rc;
        if (d->has_held) {
            d->decoder_trim = aac_decoder_trim(d, par);
            d->start_time += d->decoder_trim;
        }
    }
    return STREAM_DECODE_OK;
}

void sd_aac_packet_read(StreamDecoder *d, AVPacket *pkt) {
    if (d->aac.prime_skip > 0 && pkt->pts == d->aac.prime_start) {
        /* The first packet of an MP4 AAC stream whose edit list did not say to skip anything
         * (a fragmented file has none): the decoder's own skip-samples mechanism drops the
         * priming, as it does for an edit list. */
        uint8_t *sd = av_packet_new_side_data(pkt, AV_PKT_DATA_SKIP_SAMPLES, 10);
        if (sd) {
            memset(sd, 0, 10);   /* little-endian skip at the start, skip at the end, reasons */
            for (int i = 0; i < 4; i++) sd[i] = (uint8_t)((uint32_t)d->aac.prime_skip >> (8 * i));
        }
    }
}

void sd_aac_frame_decoded(StreamDecoder *d) {
    if (is_sbr(d->dec->codec_id, d->dec->profile)) d->aac.sbr = 1;
}

/* ── the seek strategy ───────────────────────────────────────────────────── */

/* HE-AAC's SBR and PS headers come every so many frames, not in each, and a codec opened mid-stream
 * decodes without them until the next one arrives. An HE-AAC v2 stream from Apple's encoder decoded
 * bit-identically to an unbroken run only after more than 65536 samples at the output rate (98304
 * were enough); 131072, about 3 s, leaves a margin for an encoder that repeats them less often. */
static int64_t aac_preroll_samples(const StreamDecoder *d) {
    if (d->aac.sbr) return 131072;
    return sd_generic_preroll_samples(d);
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
 * (`aac_preroll_samples`). The other codecs' flush leaves nothing behind that matters.
 */
static int aac_reopens_codec(const StreamDecoder *d) {
    return d->dec->codec_id == AV_CODEC_ID_AAC;
}

const SeekFormat sd_seek_aac = {
    .name = "aac",
    .preroll_samples = aac_preroll_samples,
    .reopens_codec = aac_reopens_codec,
};
