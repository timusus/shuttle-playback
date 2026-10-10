/*
 * seek_mp3.c — how an MP3 seeks (see seek.h).
 *
 * An MP3 frame carries no timestamp, so a seek is only as exact as the place it starts counting
 * from. In order: a frame whose time is known (the first frame, or a VBRI table entry, as media3's
 * VbriSeeker reads it) when it is in reach, else the frame a constant-bitrate stream has to have at
 * that byte (media3's ConstantBitrateSeeker), else mp3dec's Xing TOC or bitrate estimate (media3's
 * XingSeeker), re-timed after it lands when the frame's offset says what it is. A Layer III seek's
 * pre-roll is sized from the bit reservoir and measured as it goes into the codec.
 */
#include <math.h>
#include <string.h>

#include "decoder.h"

enum { MP3_TAG_NONE = 0, MP3_TAG_INFO, MP3_TAG_VBR };

/* ── MP3 frame counting ──────────────────────────────────────────────────── */

int sd_mp3_parse_header(const uint8_t *p, int *spf, int *bitrate, int *sample_rate,
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

/*
 * Keep a VBRI frame's table of contents, which mp3dec reads the frame count from and otherwise
 * ignores (libavformat/mp3dec.c mp3_parse_vbri_tag). Unlike a Xing TOC, which gives a share of the
 * file per percent of the duration, entry k is the exact byte length of `frames per entry` frames
 * counted from the end of the VBRI frame, so the frame it ends on, and its time, are exact. A
 * table whose entries add up to more bytes, or more frames, than the header says is not used.
 */
static void mp3_read_vbri_toc(StreamDecoder *d, const uint8_t *vbri, const uint8_t *end) {
    uint32_t bytes = sd_read_be(vbri + 10, 4), frames = sd_read_be(vbri + 14, 4);
    int entries = (int)sd_read_be(vbri + 18, 2), scale = (int)sd_read_be(vbri + 20, 2);
    int size = (int)sd_read_be(vbri + 22, 2), per_entry = (int)sd_read_be(vbri + 24, 2);
    if (size < 1 || size > 4 || scale < 1 || per_entry < 1 || entries < 1) return;
    if (vbri + 26 + (int64_t)entries * size > end) return;
    if ((int64_t)entries * per_entry > (int64_t)frames + per_entry) return;
    int64_t sum = 0;
    for (int k = 0; k < entries; k++) sum += (int64_t)sd_read_be(vbri + 26 + k * size, size) * scale;
    if (sum > bytes) return;
    d->mp3.vbri_toc = (int)(vbri + 26 - d->prologue);
    d->mp3.vbri_entries = entries;
    d->mp3.vbri_entry_size = size;
    d->mp3.vbri_scale = scale;
    d->mp3.vbri_frames_per_entry = per_entry;
}

/*
 * The last VBRI table entry at or before `ts`, as the byte position and exact timestamp of the
 * frame it starts; before the first entry, the first frame. Returns 0 when there is no table.
 */
static int mp3_vbri_anchor(const StreamDecoder *d, int64_t ts, int64_t *pos, int64_t *dts) {
    if (!d->mp3.vbri_entries || !d->mp3.header_ok) return 0;
    int64_t samples = av_rescale_q(ts - d->first_pkt_dts, d->time_base, (AVRational){ 1, d->sample_rate });
    int64_t k = samples / ((int64_t)d->mp3.vbri_frames_per_entry * d->mp3.spf);
    if (k > d->mp3.vbri_entries) k = d->mp3.vbri_entries;
    if (k < 0) k = 0;
    int64_t at = d->first_pkt_pos;
    for (int64_t i = 0; i < k; i++) {
        at += (int64_t)sd_read_be(d->prologue + d->mp3.vbri_toc + i * d->mp3.vbri_entry_size, d->mp3.vbri_entry_size)
              * d->mp3.vbri_scale;
    }
    *pos = at;
    *dts = d->first_pkt_dts + av_rescale_q(k * d->mp3.vbri_frames_per_entry * d->mp3.spf,
                                           (AVRational){ 1, d->sample_rate }, d->time_base);
    return 1;
}

/* What the frame before the first audio frame declares: LAME's "Info" is a CBR stream, "Xing" and
 * "VBRI" a VBR one. Read from the prologue, which holds those bytes already. An Info frame's
 * frame count and the AVIO offset its byte count ends at go in `*frames` and `*end`, when it has both. */
static int mp3_find_tag(StreamDecoder *d, int64_t *frames, int64_t *end) {
    int64_t limit = d->first_pkt_pos < d->prologue_len ? d->first_pkt_pos : d->prologue_len;
    for (int64_t p = 0; p + 4 <= limit; p++) {
        int spf, br, sr, side;
        if (!sd_mp3_parse_header(d->prologue + p, &spf, &br, &sr, &side)) continue;
        const uint8_t *xing = d->prologue + p + 4 + side;
        const uint8_t *vbri = d->prologue + p + 36;
        if (xing + 4 <= d->prologue + limit) {
            if (!memcmp(xing, "Info", 4)) {
                if (xing + 16 <= d->prologue + limit && (sd_read_be(xing + 4, 4) & 3) == 3) {
                    *frames = sd_read_be(xing + 8, 4);
                    *end = p + sd_read_be(xing + 12, 4);
                }
                return MP3_TAG_INFO;
            }
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
static double mp3_measure_frame_bytes(const StreamDecoder *d, int64_t info_frames, int64_t info_end);

/* The first audio packet is held: note what frame counting needs. */
static void mp3_first_packet(StreamDecoder *d) {
    d->mp3.first_pkt_size = d->held->size;
    d->mp3.frame_bytes = 0;
    int spf, br, sr, side;
    if (d->has_first_pkt && d->held->size >= 4
        && sd_mp3_parse_header(d->held->data, &spf, &br, &sr, &side)) {
        d->mp3.header_ok = 1;
        d->mp3.header = ((uint32_t)d->held->data[0] << 24) | ((uint32_t)d->held->data[1] << 16)
                      | ((uint32_t)d->held->data[2] << 8) | d->held->data[3];
        d->mp3.spf = spf;
        int64_t info_frames = 0, info_end = 0;
        d->mp3.tag = mp3_find_tag(d, &info_frames, &info_end);
        d->mp3.untagged_cbr = d->mp3.tag == MP3_TAG_NONE && mp3_prologue_is_cbr(d);
        d->mp3.frame_bytes = mp3_measure_frame_bytes(d, info_frames, info_end);
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
 * (or, with an Info frame count, a rounded share of it), not the time of the frame it found.
 * In a constant-bitrate stream the frame's index follows from its byte offset: frames
 * after the first are `frame_bytes` long on average (measured, not spf * bitrate / (8 * rate): an
 * encoder that never pads writes them shorter) and each is within one byte of that, so the offset
 * from the end of the first frame, divided and rounded, counts them exactly
 * (the first frame is measured, not assumed, because it is the one an encoder cuts short). A
 * stream is constant-bitrate when its Info frame says so, or when it has no tag frame, the frames
 * in the prologue (at least three) are all the first one's twins (`untagged_cbr`) and the
 * landed frame is too.
 * A VBR stream has no such relation and keeps the demuxer's estimate.
 */
static int64_t mp3_exact_dts(const StreamDecoder *d, const AVPacket *pkt) {
    if (!d->mp3.header_ok || d->mp3.tag == MP3_TAG_VBR) return AV_NOPTS_VALUE;
    if (d->mp3.tag == MP3_TAG_NONE && (!d->mp3.untagged_cbr || d->cb.size(d->opaque) < 0)) return AV_NOPTS_VALUE;
    if (pkt->pos < 0 || pkt->dts == AV_NOPTS_VALUE || pkt->size < 4) return AV_NOPTS_VALUE;
    uint32_t h = ((uint32_t)pkt->data[0] << 24) | ((uint32_t)pkt->data[1] << 16)
               | ((uint32_t)pkt->data[2] << 8) | pkt->data[3];
    /* An Info frame vouches for the bitrate of the frames after the first, which may itself be a
     * short one at another bitrate; with no tag, only the first frame's twin is trusted. */
    uint32_t mask = d->mp3.tag == MP3_TAG_INFO ? (kMP3SameStreamMask & ~0xF000u) : kMP3SameStreamMask;
    int spf, br, sr, side;
    if ((h & mask) != (d->mp3.header & mask) || !sd_mp3_parse_header(pkt->data, &spf, &br, &sr, &side)) {
        return AV_NOPTS_VALUE;
    }
    int64_t index = 0;
    if (pkt->pos != d->first_pkt_pos) {
        int64_t second = d->first_pkt_pos + d->mp3.first_pkt_size;
        if (pkt->pos < second) return AV_NOPTS_VALUE;
        double frame_bytes = d->mp3.frame_bytes > 0 ? d->mp3.frame_bytes : (double)spf * br / (8.0 * sr);
        index = 1 + llround((double)(pkt->pos - second) / frame_bytes);
    }
    return d->first_pkt_dts + av_rescale_q(index * d->mp3.spf,
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
    if (!d->mp3.header_ok || d->mp3.tag == MP3_TAG_VBR) return AV_NOPTS_VALUE;
    if (pkt->pos < 0 || pkt->size < 4) return AV_NOPTS_VALUE;
    const uint8_t first[4] = { d->mp3.header >> 24, d->mp3.header >> 16, d->mp3.header >> 8,
                               d->mp3.header };
    int spf, br, sr, side, first_spf, first_br, first_sr;
    if (!sd_mp3_parse_header(pkt->data, &spf, &br, &sr, &side)
        || !sd_mp3_parse_header(first, &first_spf, &first_br, &first_sr, &side)
        || sr == first_sr || br != first_br) {
        return AV_NOPTS_VALUE;
    }
    int64_t second = d->first_pkt_pos + d->mp3.first_pkt_size;
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
    if (!sd_mp3_parse_header(p, &f->spf, &f->bitrate, &f->sample_rate, &f->side_info_bytes)) return 0;
    f->lsf = ((h >> 19) & 3) != 3;
    f->bytes = (int)((int64_t)f->spf / 8 * f->bitrate / f->sample_rate) + (int)((h >> 9) & 1);
    return 1;
}

/*
 * Whether a stream with no tag frame can be taken for constant-bitrate: the frames from the first
 * on that the prologue holds (at least three) are all the first frame's twin. Nothing else in such a
 * file says so. A VBR file that opens at one bitrate and moves on shows it within a few frames; one
 * that does not is beyond what a seek can know, and gets no more than an estimate.
 */
static int mp3_prologue_is_cbr(const StreamDecoder *d) {
    int frames = 0;
    for (int64_t pos = d->first_pkt_pos; pos >= 0 && pos + 4 <= d->prologue_len; frames++) {
        MP3Frame f;
        uint32_t h = sd_read_be(d->prologue + pos, 4);
        if ((h & kMP3SameStreamMask) != (d->mp3.header & kMP3SameStreamMask) || !mp3_frame_of(h, &f)) return 0;
        pos += f.bytes;
    }
    return frames >= 3;
}

/*
 * Judge a seek's pre-roll by the frames it actually fed the codec, one frame at a time as each goes
 * in: `preroll_short` is set when the frames from the target on will not decode as an unbroken
 * run decodes them, and `seek_to` (seek.c) then places the seek further back.
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
    int side = pkt->size >= 4 && mp3_frame_of(sd_read_be(pkt->data, 4), &f)
             ? 4 + ((pkt->data[1] & 1) ? 0 : 2) : -1;   /* the side info follows the CRC, if any */
    if (side < 0 || pkt->size < side + f.side_info_bytes || d->discard_until == AV_NOPTS_VALUE) {
        d->mp3.watch = 0;
        return;
    }
    if (d->mp3.watch_frames == 0 && pkt->pos >= 0 && pkt->pos == d->first_pkt_pos) {
        d->mp3.watch = 0;
        return;
    }
    int begin = f.lsf ? pkt->data[side] : (pkt->data[side] << 1) | (pkt->data[side + 1] >> 7);
    int64_t duration = av_rescale_q(f.spf, (AVRational){ 1, f.sample_rate }, d->time_base);
    int64_t dts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts
                : d->mp3.watch_frames > 0 ? d->mp3.watch_next : d->seek_from;
    if (dts != AV_NOPTS_VALUE && dts + 3 * duration > d->discard_until) {
        d->mp3.preroll_short = d->mp3.watch_frames == 0 || begin > d->mp3.watch_bytes;
        d->mp3.watch = 0;
        return;
    }
    d->mp3.watch_frames++;
    d->mp3.watch_bytes += pkt->size - side - f.side_info_bytes;
    d->mp3.watch_next = dts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : dts + duration;
}

/* The header of the frames after the first in a constant-bitrate Layer III stream, 0 when that is
 * not known. With an Info frame the first audio frame may be a short one at another bitrate, so the
 * second frame is read from the prologue; with no tag frame only the first frame's twins are trusted
 * (as in `mp3_exact_dts`, which this agrees with on every frame it accepts). */
static uint32_t mp3_cbr_header(const StreamDecoder *d) {
    MP3Frame f;
    if (!d->mp3.header_ok || d->mp3.tag == MP3_TAG_VBR || !mp3_frame_of(d->mp3.header, &f)) return 0;
    if (d->mp3.tag == MP3_TAG_NONE) return !d->mp3.untagged_cbr || d->cb.size(d->opaque) < 0 ? 0 : d->mp3.header;
    int64_t second = d->first_pkt_pos + d->mp3.first_pkt_size;
    if (second < 0 || second + 4 > d->prologue_len) return 0;
    uint32_t h = sd_read_be(d->prologue + second, 4);
    uint32_t mask = kMP3SameStreamMask & ~0xF000u;
    return (h & mask) == (d->mp3.header & mask) && mp3_frame_of(h, &f) ? h : 0;
}

/*
 * The bytes per frame after the first in a constant-bitrate Layer III stream, 0 when it is not one.
 * Some encoders never set the padding bit, so the nominal spf * bitrate / (8 * rate) is up to a
 * byte a frame too long, and a seek counted by it lands later the further it goes. An Info frame
 * whose byte count ends where the audio does gives the true average with its frame count (which
 * excludes the Info frame). Otherwise the prologue's frames say: enough of them that padding would
 * have shown, none padded, and the frames are the nominal size rounded down.
 */
static double mp3_measure_frame_bytes(const StreamDecoder *d, int64_t info_frames, int64_t info_end) {
    MP3Frame f;
    uint32_t h = mp3_cbr_header(d);
    if (!h || !mp3_frame_of(h, &f)) return 0;
    int64_t second = d->first_pkt_pos + d->mp3.first_pkt_size;
    if (info_frames > 1 && info_end > second && info_end == sd_avio_size_seen(d)) {
        return (double)(info_end - second) / (double)(info_frames - 1);
    }
    double nominal = (double)f.spf * f.bitrate / (8.0 * f.sample_rate);
    int frames = 0;
    for (int64_t pos = second; pos + 4 <= d->prologue_len; frames++) {
        MP3Frame g;
        uint32_t here = sd_read_be(d->prologue + pos, 4);
        if ((here & kMP3SameStreamMask) != (h & kMP3SameStreamMask) || !mp3_frame_of(here, &g)) break;
        if (here & 0x200) return nominal;
        pos += g.bytes;
    }
    return frames * (nominal - floor(nominal)) >= 1 ? floor(nominal) : nominal;
}

/*
 * The frame `ts` (stream time base) falls in, in a constant-bitrate Layer III stream, found by
 * reading the few bytes where it has to be: `*pos` and `*dts` are its byte position and exact time,
 * or `*pos` is -1 when this cannot say (the caller seeks by estimate instead). Returns
 * STREAM_DECODE_OK, or the status of a cancel or an interruption.
 *
 * Frame k starts within a byte or two of `second + (k - 1) * frame_bytes`, which is the relation
 * `mp3_exact_dts` counts frames by. mp3_seek finds a frame near a byte estimate too,
 * but first rewinds 4096 bytes before it (mp3_sync's SEEK_WINDOW) and reads them: on a stream still
 * downloading, a far seek restarts the download there and waits for all of them, a quarter of a
 * second at twice a 64 kbps bitrate, before the first byte it needs. This reads from the frame. A
 * header there, the next frame's header after it, and its size agreeing with `frame_bytes` is the frame. media3's
 * ConstantBitrateSeeker places a CBR seek by the same arithmetic.
 */
static int mp3_cbr_frame(StreamDecoder *d, int64_t ts, int64_t *pos, int64_t *dts) {
    *pos = -1;
    MP3Frame f;
    uint32_t h = mp3_cbr_header(d);
    if (!h || !mp3_frame_of(h, &f) || d->first_pkt_dts == AV_NOPTS_VALUE || d->first_pkt_pos < 0) {
        return STREAM_DECODE_OK;
    }
    int64_t samples = av_rescale_q(ts - d->first_pkt_dts, d->time_base, (AVRational){ 1, d->sample_rate });
    int64_t index = samples / d->mp3.spf;
    if (index < 1) return STREAM_DECODE_OK;

    enum { kSlack = 4 };
    uint8_t buf[2 * kSlack + 1441 + 1 + 4];   /* the largest Layer III frame, and the next header */
    int need = 2 * kSlack + f.bytes + 1 + 4;
    if (need > (int)sizeof(buf)) return STREAM_DECODE_OK;
    int64_t second = d->first_pkt_pos + d->mp3.first_pkt_size;
    double frame_bytes = d->mp3.frame_bytes;
    int64_t lo = second + llround((double)(index - 1) * frame_bytes) - kSlack;
    if (lo < second) lo = second;

    int got = avio_seek(d->fmt->pb, lo, SEEK_SET) < 0 ? -1 : avio_read(d->fmt->pb, buf, need);
    if (got < need) return sd_read_failure_status(d);
    for (int off = 0; off <= 2 * kSlack; off++) {
        uint32_t here = sd_read_be(buf + off, 4);
        MP3Frame g;
        if ((here & kMP3SameStreamMask) != (h & kMP3SameStreamMask) || !mp3_frame_of(here, &g)) continue;
        if (off + g.bytes + 4 > got) continue;
        if ((sd_read_be(buf + off + g.bytes, 4) & kMP3SameStreamMask) != (h & kMP3SameStreamMask)) continue;
        /* A frame a byte or more off the measured size says the measure is wrong, and so is the place. */
        if (fabs(g.bytes - frame_bytes) >= 1) continue;
        *pos = lo + off;
        *dts = d->first_pkt_dts + av_rescale_q(index * d->mp3.spf, (AVRational){ 1, d->sample_rate },
                                               d->time_base);
        return STREAM_DECODE_OK;
    }
    return STREAM_DECODE_OK;
}

/* ── the seek strategy ───────────────────────────────────────────────────── */

/*
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
 * they fall short (`mp3_measure_preroll`, `seek_to` in seek.c). Anything else gets the generic pre-roll.
 */
static int64_t mp3_preroll_samples(const StreamDecoder *d) {
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
    return sd_generic_preroll_samples(d);
}

/*
 * Whether to decode forward from an exact MP3 anchor `gap` (stream time base) before the target
 * rather than seek by estimate.
 *
 * A constant-bitrate stream lands exactly by its estimate (see `mp3_exact_dts`), so its anchors only
 * serve the first second or so. A VBR stream has no exact landing but this one: a Xing
 * TOC places a time to 1/256 of the file and a bitrate guess worse, and mp3dec labels the frame it
 * finds there with the time asked for. Nothing in an MP3 frame says what time it is, so the only
 * true time is one counted frame by frame from a frame whose time is known. That count is taken
 * whenever it reads no more than a seek is allowed to (`kSeekBudgetBytes`), a few seconds at a
 * speech bitrate; further than that, the estimate is all there is.
 */
static int mp3_anchor_in_reach(const StreamDecoder *d, int64_t gap) {
    int64_t samples = av_rescale_q(gap, d->time_base, (AVRational){ 1, d->sample_rate });
    if (samples <= kMaxAnchorGapSamples) return 1;
    if (d->mp3.tag != MP3_TAG_VBR) return 0;
    int64_t bit_rate = d->fmt->bit_rate > 0 ? d->fmt->bit_rate
                                            : d->fmt->streams[d->audio_idx]->codecpar->bit_rate;
    if (bit_rate <= 0) return 0;
    return (double)samples / d->sample_rate * (double)bit_rate / 8.0 <= (double)kSeekBudgetBytes;
}

/*
 * An MP3 frame whose place and time are both known exactly is sought to directly rather than by the
 * TOC or bitrate estimate FAST_SEEK picks: the first frame (which `mp3_sync` skips when an encoder
 * cut it short, playing a seek to the start from the second), or a VBRI table entry. Only that
 * entry is trusted: mp3dec fills the index with its Xing TOC, a percent of the file per entry, whose
 * positions are not frames and whose times are not theirs.
 */
static int mp3_place(StreamDecoder *d, int64_t target, SeekPlan *plan) {
    if (!d->mp3.header_ok) return STREAM_DECODE_OK;
    if (!mp3_vbri_anchor(d, target, &plan->anchor_pos, &plan->anchor_dts)) {
        plan->anchor_pos = d->first_pkt_pos;
        plan->anchor_dts = d->first_pkt_dts;
    }
    /* An anchor far before the target (a long file's start, or a coarse table) would cost a long
     * decode to it; the estimate is cheaper. */
    if (target > d->start_time && !mp3_anchor_in_reach(d, target - plan->anchor_dts)) {
        plan->anchor_pos = -1;
    }
    /* Further than that, a constant-bitrate stream's frame is found where it has to be, which is
     * exact and reads nothing before it (`mp3_cbr_frame`). When it is not there (a stream with no
     * tag frame that is not constant-bitrate after all, or bytes that cannot be read), the seek goes
     * by estimate with the same short pre-roll, and lands among frames nothing has measured. That
     * pre-roll is judged by the frames it feeds the codec like any other (`mp3_measure_preroll`)
     * and placed further back when it falls short. */
    if (plan->anchor_pos < 0) return mp3_cbr_frame(d, target, &plan->anchor_pos, &plan->anchor_dts);
    return STREAM_DECODE_OK;
}

/*
 * After a seek by estimate: read the frame it landed on and, when its offset says what time it truly
 * is (`mp3_exact_dts`, `mp3_byte_rate_dts`), seek again to that frame with that time. Then watch the
 * pre-roll go into the codec.
 */
static int mp3_landed(StreamDecoder *d, int anchored) {
    if (d->mp3.header_ok && !anchored) {
        int rc = sd_read_audio_packet(d);
        /* Otherwise `sd_pump` reads again and meets the same end, error or interruption. */
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
    d->mp3.watch = d->mp3.header_ok && d->dec->codec_id == AV_CODEC_ID_MP3;
    return STREAM_DECODE_OK;
}

static void mp3_reset(StreamDecoder *d) {
    d->mp3.watch = 0;
    d->mp3.watch_frames = 0;
    d->mp3.watch_bytes = 0;
    d->mp3.watch_next = AV_NOPTS_VALUE;
    d->mp3.preroll_short = 0;
}

static void mp3_packet_fed(StreamDecoder *d, const AVPacket *pkt) {
    if (d->mp3.watch) mp3_measure_preroll(d, pkt);
}

static int mp3_preroll_short(const StreamDecoder *d) {
    return d->mp3.preroll_short;
}

const SeekFormat sd_seek_mp3 = {
    .name = "mp3",
    .place = mp3_place,
    .preroll_samples = mp3_preroll_samples,
    .first_packet = mp3_first_packet,
    .reset = mp3_reset,
    .landed = mp3_landed,
    .packet_fed = mp3_packet_fed,
    .preroll_short = mp3_preroll_short,
};
