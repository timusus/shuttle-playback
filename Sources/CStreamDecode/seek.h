/*
 * seek.h — the per-format seek strategies behind one interface (internal; see docs/decisions/0012).
 *
 * `seek.c` runs every seek: the resume, the pre-roll, the placement ladder with its byte budget and
 * its fallbacks, and the sample-accurate landing. What differs by format is asked of the decoder's
 * `SeekFormat`: where to put the demuxer, how far before the target, whether the codec survives a
 * flush, and what to do once the demuxer is placed. Each format module (seek_mp3.c, seek_flac.c,
 * seek_aac.c, seek_ogg.c, seek_generic.c) keeps its state in its own struct below.
 *
 * The split follows media3's: an extractor hands the player a `SeekMap` that turns a time into a
 * place in the stream (XingSeeker, VbriSeeker, ConstantBitrateSeeker for MP3, FlacBinarySearchSeeker
 * over BinarySearchSeeker for FLAC), and one loader alone decides how to seek and what to fall back to.
 */
#ifndef CSTREAMDECODE_SEEK_H
#define CSTREAMDECODE_SEEK_H

#include <stdint.h>

#include <libavcodec/avcodec.h>

#include "stream_decode.h"

/* Bytes one `avformat_seek_file` may read before it is judged to be walking the file. Two AVIO
 * refills: enough for a mov index landing or an mp3 TOC landing, and small enough that the walk it
 * exists to stop is cut off after a fraction of a second of audio rather than the 12 MB a single
 * seek to 25 minutes cost on the measured fixture. */
static const int64_t kSeekBudgetBytes = 64 * 1024;

/* The furthest before its target an exact MP3 anchor, or an Ogg index entry, is used from: about
 * 1.5 s at 44.1 kHz. */
static const int64_t kMaxAnchorGapSamples = 65536;

/* Where a format puts the demuxer for one seek (stream time base). */
typedef struct {
    /* A frame whose place (AVIO offset) and time are both known exactly, which the seek goes
     * straight to through an index entry; `anchor_pos` -1 when there is none. */
    int64_t anchor_pos;
    int64_t anchor_dts;
    /* With no anchor: where the demuxer is asked to go, at or before the target. */
    int64_t seek_ts;
    /* AV_NOPTS_VALUE, or where the seek lands instead of the target: a FLAC frame further before the
     * target than a seek may decode, which the decode runs on from. */
    int64_t land_at;
} SeekPlan;

/* One format's answers. Every hook but `name` may be NULL, which means the generic answer. */
typedef struct SeekFormat {
    const char *name;
    /* Fill in `plan` for `target`, which starts as "no anchor, seek to the target". Returns
     * STREAM_DECODE_OK, or the status of a cancel or an interruption. */
    int (*place)(StreamDecoder *d, int64_t target, SeekPlan *plan);
    /* Whether a placement that failed or walked is anchored again by `estimate_anchor` rather than
     * placed by the byte estimate, which reports the target over audio from wherever the byte falls. */
    int (*has_estimate_anchor)(const StreamDecoder *d);
    /* That anchor: a frame of known time at or before `target`, near `ratio` of the stream's bytes.
     * `plan->anchor_pos` stays -1 when there is none. Returns as `place` does. */
    int (*estimate_anchor)(StreamDecoder *d, double ratio, int64_t target, SeekPlan *plan);
    /* How far before its target the demuxer is put, in samples, so the codec has converged by then. */
    int64_t (*preroll_samples)(const StreamDecoder *d);
    /* Whether the codec is replaced, not flushed, before the landing decode. */
    int (*reopens_codec)(const StreamDecoder *d);
    /* Whether an interrupted read may resume by finding its last packet again (`seek.c`). */
    int (*can_resume)(const StreamDecoder *d);
    /* The open has read the first audio packet (`held`, with `first_pkt_pos` and `first_pkt_dts`). */
    void (*first_packet)(StreamDecoder *d);
    /* A seek is flushing the decode: forget what the last one measured. */
    void (*reset)(StreamDecoder *d);
    /* The demuxer is placed (`anchored`: at the plan's anchor) and the codec is clean, before the
     * landing decode starts. Returns STREAM_DECODE_OK or a status that ends the seek. */
    int (*landed)(StreamDecoder *d, int anchored);
    /* `pkt` is about to go into the codec. */
    void (*packet_fed)(StreamDecoder *d, const AVPacket *pkt);
    /* After the landing decode: whether the pre-roll it fed fell short, so the seek is placed again
     * further back. */
    int (*preroll_short)(const StreamDecoder *d);
} SeekFormat;

/* MP3 (seek_mp3.c): the first audio frame, which every other frame's index is counted from, what
 * the frame before it declares, and the measure of a Layer III seek's pre-roll. */
typedef struct {
    int64_t  first_pkt_size;
    int      header_ok;
    uint32_t header;             /* its first four bytes, for "same stream" comparisons */
    int      spf;                /* samples per frame */
    int      tag;                /* MP3_TAG_*: what the frame before the first audio says */
    int      untagged_cbr;       /* no tag frame, and the frames in `prologue` all share a bitrate */
    int      vbri_toc;           /* the VBRI table: its offset in `prologue`, and its shape */
    int      vbri_entries;       /* 0: no usable table */
    int      vbri_entry_size;
    int      vbri_scale;
    int      vbri_frames_per_entry;
    /* A Layer III seek's pre-roll, measured as it goes into the codec (see `mp3_measure_preroll`):
     * whether it is still being watched, the frames and main data bytes fed so far, the time of the
     * next frame, and whether it came up short of what the frames from the target need. */
    int      watch;
    int      watch_frames;
    int64_t  watch_bytes;
    int64_t  watch_next;
    int      preroll_short;
} MP3SeekState;

/* Native FLAC (seek_flac.c): where the first frame starts (AVIO offset), once `flac_audio_start`
 * has found it; 0 until then. */
typedef struct {
    int64_t audio_pos;
} FLACSeekState;

/* AAC (seek_aac.c). */
typedef struct {
    int     prime_skip;   /* MP4 AAC: encoder priming to drop when the file's own edit list does not, else 0 */
    int64_t prime_start;  /* the timestamp of the packet that carries it */
    /* The stream has been seen to carry SBR (HE-AAC v1 or v2), by its parameters or by a frame the
     * codec decoded: an ADTS header says plain AAC-LC either way. Never cleared. */
    int     sbr;
    /* What the decoder drops from the first packet on its own, in time base units, else 0. */
    int64_t decoder_trim;
} AACSeekState;

extern const SeekFormat sd_seek_mp3;
extern const SeekFormat sd_seek_flac;
extern const SeekFormat sd_seek_aac;
extern const SeekFormat sd_seek_ogg;
extern const SeekFormat sd_seek_generic;

/* The strategy for the stream `sd_open_format` just found (seek.c). */
const SeekFormat *sd_seek_format_for(const StreamDecoder *d);

/* The generic pre-roll, by codec (seek_generic.c). */
int64_t sd_generic_preroll_samples(const StreamDecoder *d);

#endif
