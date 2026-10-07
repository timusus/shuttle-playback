#!/bin/bash
# Regenerates the synthetic conformance fixtures next to this script. Needs ffmpeg, lame, afconvert
# (macOS) and python3. The files copied from androidx/media (see NOTICE) are not touched.
#
# Source signal: the same two-sine sweep as Tests/PlaybackDecodeTests/Fixtures (440 Hz left, 660 Hz
# right, under a 0.05 Hz amplitude sweep), 4 s long, so no two seconds look alike.
#
# Output is deterministic for a given ffmpeg/lame/afconvert; goldens carry each file's sha256, so a
# toolchain change shows up as a golden mismatch naming the file, not as a silent re-encode.
# Not byte-reproducible: he_aac_v*.m4a (afconvert timestamps) and opus_stereo.opus / vorbis_stereo.ogg
# (random Ogg stream serials). Re-running changes their sha256, so only regenerate them on purpose
# and follow with GOLDEN_UPDATE=1.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FF="ffmpeg -y -loglevel error -fflags +bitexact -flags:a +bitexact"

sig() { # rate -> wav
    $FF -f lavfi -i "aevalsrc=0.7*sin(2*PI*440*t)*(0.55+0.45*sin(2*PI*0.05*t))|0.7*sin(2*PI*660*t)*(0.55+0.45*sin(2*PI*0.05*t)):s=$1:d=4" -c:a pcm_s16le "$2"
}
sig 44100 "$TMP/s44.wav"
sig 48000 "$TMP/s48.wav"

# --- MP3 ---------------------------------------------------------------------------------------
# 48 kHz CBR has no padding bits and no Xing/Info frame: the decoder has no table and no frame count.
$FF -i "$TMP/s48.wav" -c:a libmp3lame -b:a 64k -write_xing 0 -id3v2_version 0 -write_id3v1 0 cbr_no_table.mp3
# 44.1 kHz CBR: the frame length is fractional, so the padding bit alternates.
$FF -i "$TMP/s44.wav" -c:a libmp3lame -b:a 64k -write_xing 0 -id3v2_version 0 cbr_padding_bit.mp3
# LAME's own VBR with a Xing header and TOC; and an "Info" header with encoder delay and padding.
lame --quiet -V5 -h "$TMP/s44.wav" vbr_xing.mp3
lame --quiet --cbr -b 96 -h "$TMP/s44.wav" lame_info_delay_padding.mp3

python3 -I - <<'PY'
import os, random

def rd(n): return open(n, 'rb').read()
def wr(n, b): open(n, 'wb').write(b)

vbr = rd('vbr_xing.mp3')
# Xing TOC flag cleared: the header says "no TOC" while the bytes are still there.
i = vbr.index(b'Xing')
flags = int.from_bytes(vbr[i+4:i+8], 'big') & ~0x4
wr('vbr_xing_no_toc.mp3', vbr[:i+4] + flags.to_bytes(4, 'big') + vbr[i+8:])
# The header promises more frames than the stream holds.
wr('vbr_xing_longer_than_stream.mp3', vbr[:int(len(vbr) * 0.6)])

# Deterministic printable garbage with no 0xFF sync byte.
rng = random.Random(404)
def garbage(n): return bytes(rng.randrange(0x20, 0x7f) for _ in range(n))

cbr = rd('cbr_padding_bit.mp3')
# A prefix longer than the 64 KiB probe budget (catalogue A1).
wr('garbage_prefix_80k.mp3', garbage(80_000) + cbr[:16_000])
wr('garbage_trailing_4k.mp3', cbr + garbage(4096))
wr('id3v1_footer.mp3', cbr + b'TAG' + b'Conformance'.ljust(30, b'\0') + b'Shuttle'.ljust(30, b'\0') + b'\0' * 65 + b'\xff')
# One byte flipped inside a frame's main data, halfway through.
mid = len(cbr) // 2
wr('flipped_frame.mp3', cbr[:mid] + bytes([cbr[mid] ^ 0x55]) + cbr[mid+1:])
PY

# 44.1 kHz then 48 kHz, concatenated at the byte level: a sample-rate change mid-stream (catalogue B11).
lame --quiet -b 32 --cbr "$TMP/s44.wav" "$TMP/a.mp3"
lame --quiet -b 32 --cbr "$TMP/s48.wav" "$TMP/b.mp3"
cat "$TMP/a.mp3" "$TMP/b.mp3" > stitch_44k_48k.mp3

# --- AAC / MP4 ---------------------------------------------------------------------------------
# ffmpeg's AAC-in-MP4 carries an edit list for the encoder priming.
$FF -i "$TMP/s44.wav" -c:a aac -b:a 48k -movflags +faststart aac_edit_list.m4a
$FF -i "$TMP/s44.wav" -c:a aac -b:a 48k aac_moov_last.m4a
python3 -I - <<'PY'
import struct
b = open('aac_moov_last.m4a', 'rb').read()
# mdat size field claims far more than the file holds (catalogue B-class "mdat too long").
i = b.index(b'mdat') - 4
patched = b[:i] + struct.pack('>I', struct.unpack('>I', b[i:i+4])[0] + 100_000) + b[i+4:]
open('mdat_too_long.m4a', 'wb').write(patched)
PY
rm aac_moov_last.m4a
# Fragmented: an empty moov, then 1 s fragments (moof + mdat), a global sidx and an mfra at the end.
$FF -i "$TMP/s44.wav" -c:a aac -b:a 48k -movflags empty_moov+default_base_moof+global_sidx \
    -frag_duration 1000000 aac_fragmented_sidx.m4a

# HE-AAC v1 and v2 via the macOS encoder (ffmpeg has no SBR/PS encoder).
afconvert -f m4af -d aach -b 32000 "$TMP/s44.wav" he_aac_v1.m4a
afconvert -f m4af -d aacp -b 24000 "$TMP/s44.wav" he_aac_v2.m4a

# ADTS with a leading ID3v2 tag, whole and truncated mid-frame.
$FF -i "$TMP/s44.wav" -c:a aac -b:a 48k -f adts -write_id3v2 1 -metadata title="conformance" adts_id3.aac
python3 -I -c "
b = open('adts_id3.aac', 'rb').read()
open('adts_id3_truncated.aac', 'wb').write(b[:int(len(b) * 0.55) + 3])
"

# --- Ogg ---------------------------------------------------------------------------------------
$FF -i "$TMP/s48.wav" -c:a libopus -b:a 32k -map_metadata -1 opus_stereo.opus
$FF -i "$TMP/s44.wav" -c:a vorbis -strict -2 -b:a 48k -map_metadata -1 vorbis_stereo.ogg

ls -l *.mp3 *.m4a *.aac *.opus *.ogg | awk '{print $5, $9}'
