/*
 * seek_ogg.c — how an Ogg stream seeks (see seek.h).
 *
 * oggdec bisects over page granules when the stream has a length and goes by its index when it has
 * none. What is Ogg's own is where that index seek is aimed, and that a packet's position (its
 * page's) names no single packet, so an interrupted read without a length cannot resume.
 */
#include <string.h>

#include "decoder.h"

/*
 * oggdec gives every packet the position of the page it starts in, so the generic index holds one
 * entry per packet and several share a position, each with its own time. A seek by the index (the
 * Ogg fallback when there is no length to bisect) can pick one from the middle of a page: it goes to
 * the page and labels the page's FIRST packet with that later time, and every packet after it
 * follows. On most pages the Vorbis and Opus parsers relabel from the page's granule and hide it; on
 * the last page (EOS set) they do not, and a seek to the end landed 25600 samples early while
 * labelled as the target (issue #6). Seeking to the earliest entry at that position labels the page
 * truly.
 *
 * An Ogg seek also starts one page further back. The parsers trim the encoder padding off the last
 * page by the time the page before it ended; a seek straight onto the last page has no such time,
 * and decoded the padding (704 samples here) as audio.
 *
 * Only where the index reaches the target. Past its end the nearest entry is merely as far as the
 * decode has got, and seeking there instead (so decoding from it to the target) walked 12 MB of a
 * long file on one seek; the anchor gap bounds it as it does an MP3's.
 */
static int ogg_place(StreamDecoder *d, int64_t target, SeekPlan *plan) {
    AVStream *st = d->fmt->streams[d->audio_idx];
    int pages = 2;
    int at = av_index_search_timestamp(st, target, AVSEEK_FLAG_BACKWARD);
    const AVIndexEntry *entry = at >= 0 ? avformat_index_get_entry(st, at) : NULL;
    if (entry && av_rescale_q(target - entry->timestamp, d->time_base,
                              (AVRational){ 1, d->sample_rate }) > kMaxAnchorGapSamples) {
        entry = NULL;
    }
    while (entry && at > 0) {
        const AVIndexEntry *before = avformat_index_get_entry(st, at - 1);
        if (!before) break;
        if (before->pos != entry->pos && --pages == 0) break;
        entry = before;
        at--;
    }
    if (entry && entry->timestamp < plan->seek_ts) plan->seek_ts = entry->timestamp;
    return STREAM_DECODE_OK;
}

/* An Ogg packet's position is its page's, shared with every packet on the page, so (pos, dts) names
 * no single packet. With a length, the seek bisects and labels packets from the pages' granules,
 * and the packet is found. Without one it goes by the index, which labels the page's first packet
 * with `dts`: the "found" packet was the page's first and the resume repeated up to a page of
 * audio. The ordinary seek lands on the sample exactly instead. */
static int ogg_can_resume(const StreamDecoder *d) {
    return d->media_bytes > 0;
}

const SeekFormat sd_seek_ogg = {
    .name = "ogg",
    .place = ogg_place,
    .can_resume = ogg_can_resume,
};
