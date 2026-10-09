/*
 * open_mp3_recover.c — the reopens that rescue an MP3 libavformat's own header scan mishandles:
 * junk before the first frame, and a file that is a single frame.
 */
#include <string.h>

#include "decoder.h"

/* How far `mp3_read_header` looks for the first frame (`for (i = 0; i < 64 * 1024; i++)`). */
static const int64_t kMP3JunkScanBytes = 64 * 1024;
/* The largest MPEG audio frame (`MPA_MAX_CODED_FRAME_SIZE`); a first packet larger than this has
 * junk in it. */
static const int kMP3MaxFrameBytes = 1792;

/* Move the reader to `offset` for a reopen. A cancel or an interrupt is latched and reported as
 * itself; any other refusal is STREAM_DECODE_ERR_IO. */
static int reopen_seek(StreamDecoder *d, int64_t offset) {
    switch (d->cb.seek(d->opaque, offset)) {
        case 0:                       return STREAM_DECODE_OK;
        case STREAM_READ_CANCELLED:   d->cancelled = 1; return STREAM_DECODE_ERR_CANCELLED;
        case STREAM_READ_INTERRUPTED: d->interrupted = 1; return STREAM_DECODE_ERR_INTERRUPTED;
        default:                      return STREAM_DECODE_ERR_IO;
    }
}

/* How far past `base_offset` `sd_reopen_past_mp3_junk` looks for audio. Each byte is read once, so the
 * cap is what a hopeless file costs on top of the probe: 1 MiB is about 65 s of 128 kbps audio, far
 * more junk than any real file carries, and a bounded few seconds of cellular data. */
static const int64_t kMP3ResyncScanBytes = 1024 * 1024;
/* Consecutive frame headers that must chain (each at the previous one's end) to call it audio. */
static const int kMP3ResyncChain = 3;
/* The longest frame `mp3_parse_header` accepts: MPEG 2.5 layer II at 160 kbps and 8 kHz is
 * 1152 / 8 * 160000 / 8000 = 2880 bytes, plus one padding byte. (Layer I tops out at 964, layer III
 * at 1441.) */
enum { kMP3ResyncMaxFrame = 2881 };
/* What the scan carries over from one read to the next. A chain is abandoned for more bytes only
 * when a header position `at` has `at + 4 > len`, and `at` is at most (chain - 1) frames past the
 * candidate `i`, so `len - i` is under `(chain - 1) * frame + 4` = `kMP3ResyncLook`; otherwise `i` ends
 * at `len - 3`. The buffer holds the carry plus one read. */
enum { kMP3ResyncChunk = 32 * 1024, kMP3ResyncLook = 2 * kMP3ResyncMaxFrame + 4 };

/* The start of the body is the signature of another container or a text page, which no amount of
 * scanning will turn into MP3 (an ID3 tag has been skipped already, so these are the audio's own
 * first bytes). */
static int prologue_is_not_mp3(const StreamDecoder *d) {
    const uint8_t *p = d->prologue;
    int n = d->prologue_len;
    if (n >= 8 && !memcmp(p + 4, "ftyp", 4)) return 1;
    if (n >= 4 && (!memcmp(p, "OggS", 4) || !memcmp(p, "fLaC", 4) || !memcmp(p, "RIFF", 4) || !memcmp(p, "FORM", 4))) return 1;
    return n >= 1 && (p[0] == '<' || p[0] == '{');
}

/* The byte length of the MPEG audio frame whose header is at `p`, or 0 if it is not one. */
static int mp3_frame_length(const uint8_t *p, uint32_t *key) {
    int spf, bitrate, rate, side;
    if (!sd_mp3_parse_header(p, &spf, &bitrate, &rate, &side)) return 0;
    int pad = (p[2] >> 1) & 1;
    int len = spf == 384 ? (12 * bitrate / rate + pad) * 4 : spf / 8 * bitrate / rate + pad;
    /* What must not change from one frame to the next: version, layer, sample rate. */
    *key = ((uint32_t)(p[1] & 0x1E) << 8) | (p[2] & 0x0C);
    return len;
}

/*
 * A probe that finds no audio behind more than its budget of junk: look past the
 * budget for the first run of `kMP3ResyncChain` MPEG audio frames that follow each other, and open
 * there. A lone 0xFFE sync word in the junk does not chain, so it is not taken. Only runs after
 * a failed open, so a file that opens is read exactly as before.
 */
int sd_reopen_past_mp3_junk(StreamDecoder *d, const StreamDecodeOptions *options, int failed) {
    if (d->cancelled) return STREAM_DECODE_ERR_CANCELLED;
    if (d->interrupted) return STREAM_DECODE_ERR_INTERRUPTED;
    sd_close_format(d);

    enum { kChunk = kMP3ResyncChunk, kLook = kMP3ResyncLook };
    /* The probe has already looked at the first `kMP3JunkScanBytes` (mp3dec scans them for two
     * chained frames), so start there, less the span a chain occupies in case one straddles it. */
    int64_t found = -1, pos = kMP3JunkScanBytes - kLook;   /* `pos`: offset of buf[0] from base_offset */
    /* The failed open read on through the junk to the audio, as far as libavformat's own buffer
     * ahead of it: the first frame is within the last 64 KiB of what it read, so there is no need
     * to read the junk again. What it read is the run of bytes it consumed from the start, which
     * stays true whatever the failed open then seeked to (`io_pos` is wherever that left it). */
    if (d->contiguous_read - 64 * 1024 > pos) pos = d->contiguous_read - 64 * 1024;
    /* Nothing left to look at, or a body that is another format's: leave the reader alone. */
    if (pos >= kMP3ResyncScanBytes || prologue_is_not_mp3(d)) return failed;
    uint8_t *buf = (uint8_t *)av_malloc(kChunk + kLook);
    if (!buf) return STREAM_DECODE_ERR_ALLOC;
    int len = 0, rc = reopen_seek(d, d->base_offset + pos);
    int scanned_to_end = 0;
    if (rc != STREAM_DECODE_OK) { av_free(buf); return rc == STREAM_DECODE_ERR_IO ? failed : rc; }
    while (found < 0 && pos < kMP3ResyncScanBytes && !scanned_to_end) {
        int n = d->cb.read(d->opaque, buf + len, kChunk);
        if (n > 0) { d->bytes_read += n; len += n; }
        else if (n == STREAM_READ_EOF) scanned_to_end = 1;
        else if (n == STREAM_READ_CANCELLED) { d->cancelled = 1; av_free(buf); return STREAM_DECODE_ERR_CANCELLED; }
        else if (n == STREAM_READ_INTERRUPTED) { d->interrupted = 1; av_free(buf); return STREAM_DECODE_ERR_INTERRUPTED; }
        else { av_free(buf); return failed; }
        int i = 0;
        for (; i + 4 <= len; i++) {
            if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;
            int at = i, ok = 1;
            uint32_t key0 = 0, key;
            for (int k = 0; k < kMP3ResyncChain && ok; k++) {
                if (at + 4 > len) {
                    if (scanned_to_end) ok = 0;
                    else goto need_more;   /* the chain runs past what is read */
                    break;
                }
                int fl = mp3_frame_length(buf + at, &key);
                if (!fl || fl > kMP3ResyncMaxFrame || (k && key != key0)) { ok = 0; break; }
                key0 = key;
                at += fl;
            }
            if (ok) { found = pos + i; break; }
        }
need_more:
        if (found >= 0) break;
        /* Keep from `i` on: what is before it cannot start a chain. */
        memmove(buf, buf + i, (size_t)(len - i));
        len -= i;
        pos += i;
    }
    av_free(buf);
    if (found < 0) return failed;

    d->base_offset += found;
    rc = reopen_seek(d, d->base_offset);
    if (rc != STREAM_DECODE_OK) return rc == STREAM_DECODE_ERR_IO ? failed : rc;
    d->io_pos = 0;
    d->prologue_len = 0;
    d->source_eof = 0;
    return sd_open_format(d, options);
}

/*
 * A file that is one MPEG audio frame and nothing else. mp3dec's header scan wants a
 * second frame header after the first and fails the open when it reads end of file there ("Failed
 * to find two consecutive MPEG audio frames"); media3's Mp3Extractor plays it. The open is retried
 * with a copy of the frame appended to what libavformat sees; `phantom_len` makes the AVIO glue
 * serve it, and the open path clips the audio to the real frame. Only after a failed open, so no
 * other file is read differently.
 */
int sd_reopen_single_frame_mp3(StreamDecoder *d, const StreamDecodeOptions *options, int failed) {
    int64_t size = d->cb.size(d->opaque);
    /* Without a length, the failed open having met end of file is what says the bytes are all there are. */
    int64_t avail = size >= 0 ? size - d->base_offset : d->source_eof ? d->prologue_len : -1;
    uint32_t key;
    int spf, bitrate, rate, side;
    if (d->cancelled || d->interrupted || avail < 4 || avail > (int64_t)sizeof(d->phantom)
        || avail != d->prologue_len || mp3_frame_length(d->prologue, &key) != avail
        || !sd_mp3_parse_header(d->prologue, &spf, &bitrate, &rate, &side)) {
        return failed;
    }
    int rc = reopen_seek(d, d->base_offset);
    if (rc != STREAM_DECODE_OK) return rc == STREAM_DECODE_ERR_IO ? failed : rc;
    sd_close_format(d);
    memcpy(d->phantom, d->prologue, (size_t)avail);
    d->phantom_len = (int)avail;
    d->phantom_at = avail;
    d->phantom_samples = spf;
    d->io_pos = 0;
    d->prologue_len = 0;
    d->source_eof = 0;
    rc = sd_open_format(d, options);
    if (rc != STREAM_DECODE_OK) {
        d->phantom_len = 0;
        return rc == STREAM_DECODE_ERR_OPEN || rc == STREAM_DECODE_ERR_NO_AUDIO ? failed : rc;
    }
    return rc;
}

/*
 * Step over junk before the first MP3 frame that libavformat itself did not.
 *
 * mp3dec looks 64 KiB past its start for two consecutive frames and, finding none, takes byte 0 as
 * the start of the audio. Decoding still works, because the parser resyncs on the first real frame,
 * but every byte-based estimate is then wrong: the duration counts the junk as audio, and a seek
 * puts its bitrate guess inside the junk and plays from the start of the file. The first
 * packet says where the audio really starts; reopening there gives the demuxer the file it should
 * have seen, with its duration and its seeks. Otherwise the packet is kept for the decoder, so
 * nothing is read twice.
 */
int sd_skip_unscanned_junk(StreamDecoder *d, const StreamDecodeOptions *options) {
    d->pkt = av_packet_alloc();
    d->held = av_packet_alloc();
    if (!d->pkt || !d->held) return STREAM_DECODE_ERR_ALLOC;
    if (!d->fmt->iformat || strcmp(d->fmt->iformat->name, "mp3") != 0) return STREAM_DECODE_OK;

    /* No packet at all is the decode's to report, not the open's; an interrupted or cancelled read
     * is the open's. */
    if (sd_read_audio_packet(d) < 0) return sd_read_failure_status(d);
    int64_t end = d->held->pos + d->held->size;
    if (d->held->pos < 0 || d->held->size <= kMP3MaxFrameBytes || end <= kMP3JunkScanBytes) {
        sd_hold_first_packet(d);
        return STREAM_DECODE_OK;
    }
    /* The parser hands the junk over glued to the first frame, so the frame is somewhere in the
     * packet's last `kMP3MaxFrameBytes`. Reopening there leaves less junk than mp3dec's own scan
     * covers, and that scan finds the frame exactly. */
    int64_t junk = end - kMP3MaxFrameBytes;
    av_packet_unref(d->held);
    sd_close_format(d);
    d->base_offset += junk;
    int rc = reopen_seek(d, d->base_offset);
    if (rc == STREAM_DECODE_ERR_IO) {
        /* The reader cannot serve the frame's offset. Open where the demuxer first did and keep
         * the junk: that decodes, as it did before this reopen existed, and only the byte
         * estimates are off. */
        d->base_offset -= junk;
        rc = reopen_seek(d, d->base_offset);
        if (rc == STREAM_DECODE_ERR_IO) return STREAM_DECODE_ERR_OPEN;
    }
    if (rc != STREAM_DECODE_OK) return rc;
    d->io_pos = 0;
    d->prologue_len = 0;
    rc = sd_open_format(d, options);
    if (rc != STREAM_DECODE_OK) return rc;
    /* The first frame again, for the same reason as above: every seek counts frames from it. The
     * decoder would read it next anyway, so this costs nothing. */
    return sd_hold_first_audio_packet(d);
}
