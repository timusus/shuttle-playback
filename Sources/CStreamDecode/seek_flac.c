/*
 * seek_flac.c — how native FLAC seeks without a seek table (issue #38; see seek.h).
 *
 * Every FLAC frame header says which frame it is, so a frame found at any byte is a frame of known
 * time: the seek interpolates between known frames to the one that holds the target, as media3's
 * FlacBinarySearchSeeker does over BinarySearchSeeker, and anchors on it. A FLAC frame decodes on
 * its own, so it needs no pre-roll (seek_generic.c) and the codec survives a flush.
 */
#include <math.h>
#include <string.h>

#include <libavutil/crc.h>

#include "decoder.h"

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
    si->max_blocksize = (int)sd_read_be(p + 2, 2);
    si->max_frame_bytes = (int)sd_read_be(p + 7, 3);
    si->sample_rate = (int)(sd_read_be(p + 10, 3) >> 4);
    si->channels = ((p[12] >> 1) & 7) + 1;
    si->bits = (((p[12] & 1) << 4) | (p[13] >> 4)) + 1;
    si->total_samples = ((int64_t)(p[13] & 15) << 32) | sd_read_be(p + 14, 4);
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
        bs = (int)sd_read_be(p + len, k) + 1;
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
        int v = (int)sd_read_be(p + len, k);
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
    return sd_read_failure_status(d);
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
    sd_avio_clear_latched_error(d);
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
    if (d->flac.audio_pos > 0) return d->flac.audio_pos;
    if (d->prologue_len < 4 || memcmp(d->prologue, "fLaC", 4) != 0) return 0;
    int64_t at = 4;
    for (int blocks = 0; blocks < 1024; blocks++) {
        uint8_t h[4];
        if (flac_read_small(d, at, h, 4, spent) != 4) return 0;
        at += 4 + sd_read_be(h + 1, 3);
        if (h[0] & 0x80) {
            d->flac.audio_pos = at;
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
    if (!flac_info(d, &si) || !sd_can_estimate_bytes(d)) return STREAM_DECODE_OK;
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
    if (!flac_info(d, &si) || !sd_can_estimate_bytes(d)) return STREAM_DECODE_OK;
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

/* ── the seek strategy ───────────────────────────────────────────────────── */

/* A frame further before the target than a seek may decode lands where it is, at the time its
 * header gives, rather than at the target with the audio elsewhere (issue #42). */
static int flac_place(StreamDecoder *d, int64_t target, SeekPlan *plan) {
    int short_of = 0;
    int rc = flac_frame_before(d, target, &plan->anchor_pos, &plan->anchor_dts, &short_of);
    if (rc == STREAM_DECODE_OK && short_of) plan->land_at = plan->anchor_dts;
    return rc;
}

/* Native FLAC never takes the byte estimate: it would report the target over audio from wherever
 * the byte falls (issue #54). */
static int flac_has_estimate_anchor(const StreamDecoder *d) {
    FLACInfo si;
    return flac_info(d, &si) && sd_can_estimate_bytes(d);
}

static int flac_place_by_estimate(StreamDecoder *d, double ratio, int64_t target, SeekPlan *plan) {
    int short_of = 0;
    int rc = flac_estimate_anchor(d, ratio, target, &plan->anchor_pos, &plan->anchor_dts, &short_of);
    if (rc == STREAM_DECODE_OK && plan->anchor_pos >= 0 && short_of) plan->land_at = plan->anchor_dts;
    return rc;
}

const SeekFormat sd_seek_flac = {
    .name = "flac",
    .place = flac_place,
    .has_estimate_anchor = flac_has_estimate_anchor,
    .estimate_anchor = flac_place_by_estimate,
};
