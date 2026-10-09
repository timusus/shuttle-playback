/*
 * avio.c — the AVIOContext callbacks over the caller's reader, and the sizes libavformat is shown.
 */
#include <string.h>

#include "decoder.h"

int sd_avio_read_packet(void *opaque, uint8_t *buf, int buf_size) {
    StreamDecoder *d = (StreamDecoder *)opaque;
    if (d->cancelled || d->interrupted) return AVERROR_EXIT;
    if (d->phantom_len && d->io_pos >= d->phantom_at) {
        int64_t off = d->io_pos - d->phantom_at;
        if (off >= d->phantom_len) return AVERROR_EOF;
        int n = d->phantom_len - (int)off < buf_size ? d->phantom_len - (int)off : buf_size;
        memcpy(buf, d->phantom + off, (size_t)n);
        d->io_pos += n;
        return n;
    }
    /* A seek that has already spent its budget is a demuxer walking the file packet by packet to
     * build an index it has no table for. Refusing the read aborts the walk; the caller
     * falls back to the byte estimate, which costs one transaction instead of megabytes. */
    if (d->seek_budget_armed && d->seek_bytes >= d->seek_budget) {
        d->seek_budget_blown = 1;
        return AVERROR(EIO);
    }
    int n;
    if (d->lead_pos < d->lead_len) {
        n = d->lead_len - d->lead_pos;
        if (n > buf_size) n = buf_size;
        memcpy(buf, d->lead + d->lead_pos, (size_t)n);
        d->lead_pos += n;
    } else {
        n = d->cb.read(d->opaque, buf, buf_size);
    }
    if (n > 0) {
        d->bytes_read += n;
        if (d->seek_budget_armed) d->seek_bytes += n;
        /* Only a contiguous run from offset 0 is kept. */
        if (d->io_pos <= d->prologue_len && d->io_pos < (int64_t)sizeof(d->prologue)) {
            int keep = (int)sizeof(d->prologue) - (int)d->io_pos;
            if (keep > n) keep = n;
            memcpy(d->prologue + d->io_pos, buf, (size_t)keep);
            if (d->io_pos + keep > d->prologue_len) d->prologue_len = (int)(d->io_pos + keep);
        }
        if (d->io_pos <= d->contiguous_read && d->io_pos + n > d->contiguous_read) d->contiguous_read = d->io_pos + n;
        d->io_pos += n;
        return n;
    }
    /* Never 0: libavformat reads a 0 as "nothing yet, ask again" and spins on it forever. */
    switch (n) {
        case STREAM_READ_EOF:       d->source_eof = 1; return AVERROR_EOF;
        /* Latch it. During `stream_decoder_open` there is no handle for the caller's `cancel` to
         * reach, so the reader's own refusal is the only evidence that this was a cancel and not a
         * broken file — and the two must not be reported the same way. */
        case STREAM_READ_CANCELLED: d->cancelled = 1; return AVERROR_EXIT;
        /* Latched for the same reason a cancel is: the reader is the only one that knows its read
         * came back early, and the pull loop above must be able to tell an interruption from a
         * broken file. */
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return AVERROR_EXIT;
        default:                    return AVERROR(EIO);
    }
}

/*
 * Where the audio ends (AVIO offset) when the Xing/Info frame at the head of the prologue declares
 * a stream much shorter than the file, 0 when it does not. mp3dec reads that as a
 * concatenated file, drops the tag's frame count and with it the gapless end trim and the duration
 * (mp3_parse_info_tag: "invalid concatenated file detected - using bitrate for duration", which
 * is when the file exceeds the declared bytes by more than 1/16). media3 trusts the tag
 * (XingSeeker.create only logs a size mismatch), so libavformat is shown a file that ends where
 * the tag says the audio does, and the trailing bytes stay unread junk after the last frame.
 */
static int64_t mp3_declared_end(const StreamDecoder *d, int64_t size) {
    int spf, br, sr, side;
    int64_t limit = d->prologue_len - 4 < 2048 ? d->prologue_len - 4 : 2048;
    for (int64_t p = 0; p <= limit; p++) {
        if (!sd_mp3_parse_header(d->prologue + p, &spf, &br, &sr, &side)) continue;
        int64_t x = p + 4 + side;
        if (x + 16 > d->prologue_len || (memcmp(d->prologue + x, "Info", 4) && memcmp(d->prologue + x, "Xing", 4))) {
            return 0;   /* the first frame is the one a tag would be in */
        }
        uint32_t flags = ((uint32_t)d->prologue[x + 4] << 24) | ((uint32_t)d->prologue[x + 5] << 16)
                       | ((uint32_t)d->prologue[x + 6] << 8) | d->prologue[x + 7];
        int64_t bytes = (int64_t)(((uint32_t)d->prologue[x + 12] << 24) | ((uint32_t)d->prologue[x + 13] << 16)
                                | ((uint32_t)d->prologue[x + 14] << 8) | d->prologue[x + 15]);
        if ((flags & 3) != 3 || bytes <= 0) return 0;
        /* A count that cannot even hold the tag frame, or that runs past the file, is corrupt. */
        int64_t frame_len = (int64_t)spf / 8 * br / sr;
        if (bytes < p + frame_len || (size > 0 && bytes > size)) return 0;
        int64_t excess = size - p - bytes;
        return excess > bytes >> 4 ? p + bytes : 0;
    }
    return 0;
}

/* The size libavformat is told (AVIO offsets): the source's less the ID3v2 tag stepped over, ended
 * where an Info/Xing frame says the audio does (see `mp3_declared_end`), and with a one-frame file's
 * `phantom_len` appended. Negative when the source has no length. */
int64_t sd_avio_size_seen(const StreamDecoder *d) {
    int64_t size = d->cb.size(d->opaque);
    if (size < 0) return size;
    size -= d->base_offset;
    int64_t end = mp3_declared_end(d, size);
    return (end > 0 ? end : size) + d->phantom_len;
}

int64_t sd_avio_seek_packet(void *opaque, int64_t offset, int whence) {
    StreamDecoder *d = (StreamDecoder *)opaque;
    if (d->cancelled || d->interrupted) return AVERROR_EXIT;

    if (whence == AVSEEK_SIZE) {
        int64_t size = sd_avio_size_seen(d);
        /* ENOSYS is the documented "I do not know", and it is the ONLY honest answer for a source
         * with no length: a made-up size sends the mov demuxer seeking past the end. */
        return size >= 0 ? size : AVERROR(ENOSYS);
    }

    int64_t target;
    switch (whence) {
        case SEEK_SET: target = offset; break;
        case SEEK_CUR: target = -1; break;   /* resolved below */
        case SEEK_END: {
            int64_t size = sd_avio_size_seen(d);
            if (size < 0) return AVERROR(ENOSYS);
            target = size + offset;
            break;
        }
        default: return AVERROR(EINVAL);
    }
    if (whence == SEEK_CUR) {
        /* libavformat resolves SEEK_CUR itself for buffered IO, but a custom context can still be
         * handed one; the reader knows its own position, so ask it. */
        return AVERROR(ENOSYS);
    }
    if (target < 0) return AVERROR(EINVAL);
    if (d->phantom_len && target >= d->phantom_at) {   /* the source has nothing there to seek to */
        d->io_pos = target;
        return target;
    }

    d->lead_len = d->lead_pos = 0;   /* the reader is repositioned: the unread lead is stale */
    int rc = d->cb.seek(d->opaque, target + d->base_offset);
    if (rc == 0) { d->source_eof = 0; d->io_pos = target; return target; }
    d->failed_seeks++;
    switch (rc) {
        case STREAM_READ_CANCELLED:   d->cancelled = 1; return AVERROR_EXIT;
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return AVERROR_EXIT;
        case STREAM_READ_UNSEEKABLE:  d->unseekable = 1; return AVERROR(ESPIPE);
        default:                      return AVERROR(EIO);
    }
}

/*
 * Clear the error `AVIOContext` latches.
 *
 * Every refusal this file makes — a cancel, an interruption, a seek that blew its byte budget —
 * reaches libavformat as a failed read, and `AVIOContext` keeps it: `error` holds the code and
 * `eof_reached` stays 1. `avio_seek` resets `eof_reached` and nothing resets `error`, so the reads
 * that follow come straight back with the OLD failure without asking the byte source for anything:
 * an interrupted decoder reported a cancel on its next seek, and a seek that fell back to the byte
 * estimate reported `STREAM_DECODE_ERR_IO` after landing correctly. A seek is precisely the point
 * at which those refusals stop being true, so it is where they are cleared.
 */
void sd_avio_clear_latched_error(StreamDecoder *d) {
    if (!d->avio) return;
    d->avio->error = 0;
    d->avio->eof_reached = 0;
}
