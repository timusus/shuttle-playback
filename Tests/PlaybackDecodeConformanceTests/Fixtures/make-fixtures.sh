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

# Seeded noise, for MP3s that lean on the bit reservoir (a tone hardly does), each long enough that
# a seek lands by frame placement rather than by decoding from the first frame.
noise() { # seconds colour amplitude seedL seedR filter -> 44.1 kHz stereo wav
    $FF -f lavfi -i "anoisesrc=d=$1:c=$2:r=44100:a=$3:seed=$4" -f lavfi -i "anoisesrc=d=$1:c=$2:r=44100:a=$3:seed=$5" \
        -filter_complex "[0][1]amerge=inputs=2,$6" -c:a pcm_s16le "$7"
}
# 32 kbps at 44.1 kHz with no tag: a frame's main data reaches up to seven frames back.
noise 10 pink 0.3 31 32 anull "$TMP/dense.wav"
lame --quiet -t --cbr -b 32 --resample 44.1 "$TMP/dense.wav" cbr_32k_dense_reservoir.mp3
# 64 kbps at 44.1 kHz with LAME's Info tag.
noise 8 pink 0.3 51 52 anull "$TMP/info.wav"
lame --quiet --cbr -b 64 --resample 44.1 "$TMP/info.wav" cbr_info_64k.mp3
# 8 kbps MPEG-2.5 at 8 kHz, mono.
$FF -f lavfi -i "anoisesrc=d=24:c=pink:r=8000:a=0.3:seed=41" -af "volume='0.4+0.6*abs(sin(2*PI*0.7*t))':eval=frame" \
    -ac 1 -c:a pcm_s16le "$TMP/m25.wav"
lame --quiet --cbr -b 8 -m m "$TMP/m25.wav" mpeg25_8k_mono.mp3
# MP3SeekTests only (its seeks land by estimate, which the goldens do not take): VBR with no Xing
# header, 0.4 s of loud noise at 112 kbps and then 14 s of quiet noise at 32 to 48 kbps, which
# LAME encodes as MPEG-2 at 22.05 kHz.
noise 0.4 white 0.9 11 12 anull "$TMP/loud.wav"
noise 14 brown 0.02 5 6 "lowpass=f=1500" "$TMP/quiet.wav"
$FF -i "$TMP/loud.wav" -i "$TMP/quiet.wav" -filter_complex "[0][1]concat=n=2:v=0:a=1" -c:a pcm_s16le "$TMP/drop.wav"
lame --quiet -t -V 9 "$TMP/drop.wav" ../SeekFixtures/vbr_no_xing_bitrate_drop.mp3
# Also MP3SeekTests only: 8 kbps CBR MPEG-2 at 22.05 kHz, mono, no tag. Its frames are 26 bytes,
# one in about eight padded to 27, and the file is cut to start on a padded one, the frame a seek
# sizes its pre-roll from. Every main_data_begin is set to 255 (the most MPEG-2 allows), so the
# frames after a seek need as much of the reservoir as a stream can ask for; the PCM is not
# meaningful, the seek's reads are what the test measures.
$FF -f lavfi -i "anoisesrc=d=20:c=pink:r=22050:a=0.3:seed=61" -ac 1 -c:a pcm_s16le "$TMP/m22.wav"
lame --quiet -t --cbr -b 8 -m m --resample 22.05 "$TMP/m22.wav" "$TMP/m22.mp3"
python3 -I - "$TMP/m22.mp3" ../SeekFixtures/cbr_22k_8k_padded.mp3 <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
frames, i = [], 0
while i < len(b) - 6:
    if b[i] == 0xFF and (b[i+1] & 0xF0) == 0xF0 and (b[i+1] & 6) == 2:
        pad = (b[i+2] >> 1) & 1
        frames.append((i, pad))
        i += 26 + pad
    else:
        i += 1
out = bytearray(b[next(o for o, p in frames if p):])
j = 0
while j < len(out) - 6:
    if out[j] == 0xFF and (out[j+1] & 0xF0) == 0xF0 and (out[j+1] & 6) == 2:
        out[j + 4 + (0 if out[j+1] & 1 else 2)] = 255
        j += 26 + ((out[j+2] >> 1) & 1)
    else:
        j += 1
open(sys.argv[2], 'wb').write(out)
PY
# Also MP3SeekTests only: 128 kbps CBR at 44.1 kHz whose frames are all 417 bytes, the padding bit
# never set, as some podcast hosts encode, behind a 522-byte ID3v2 tag and an Info frame whose
# frame and byte counts are right. LAME always pads, so this re-headers a 112 kbps encode with no
# bit reservoir as 128 kbps and fills each frame out with ancillary zeros; LAME's delay and
# padding are cleared so the duration is the frame count.
noise 12 pink 0.3 71 72 anull "$TMP/unpadded.wav"
lame --quiet --nores --cbr -b 112 "$TMP/unpadded.wav" "$TMP/unpadded.mp3"
python3 -I - "$TMP/unpadded.mp3" ../SeekFixtures/cbr_128k_unpadded_info.mp3 <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
frames, i = [], 0
while i + 4 <= len(b):
    assert b[i] == 0xFF and b[i+1] & 0xE0 == 0xE0
    size = 144 * 112000 // 44100 + ((b[i+2] >> 1) & 1)
    f = bytearray(b[i:i+size])
    f[2] = (f[2] & 0x0D) | 0x90
    frames.append(f + bytes(417 - size))
    i += size
info = frames[0]
x = info.index(b'Info')
info[x+12:x+16] = struct.pack('>I', 417 * len(frames))
lame = info.index(b'LAME')
info[lame+20] = 128
info[lame+21:lame+24] = bytes(3)
crc = 0
for c in info[:lame+34]:
    crc ^= c
    for _ in range(8):
        crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
info[lame+34:lame+36] = struct.pack('>H', crc)
id3 = b'ID3\x04\x00\x00' + bytes([0, 0, 4, 0]) + bytes(512)
open(sys.argv[2], 'wb').write(id3 + b''.join(frames))
PY

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
# The same streams in ADTS, implicitly signalled: the header says AAC-LC at the core rate, and only
# the SBR (and PS) data inside the frames says otherwise.
for v in 1 2; do $FF -i he_aac_v$v.m4a -c copy -f adts adts_he_aac_v$v.aac; done

# ADTS with a leading ID3v2 tag, whole and truncated mid-frame.
$FF -i "$TMP/s44.wav" -c:a aac -b:a 48k -f adts -write_id3v2 1 -metadata title="conformance" adts_id3.aac
python3 -I -c "
b = open('adts_id3.aac', 'rb').read()
open('adts_id3_truncated.aac', 'wb').write(b[:int(len(b) * 0.55) + 3])
"

# Raw LATM in LOAS framing (no container): the loas demuxer, probed by its sync word.
$FF -i "$TMP/s44.wav" -c:a aac -b:a 48k -f latm latm_loas.aac

# --- Ogg ---------------------------------------------------------------------------------------
$FF -i "$TMP/s48.wav" -c:a libopus -b:a 32k -map_metadata -1 opus_stereo.opus
$FF -i "$TMP/s44.wav" -c:a vorbis -strict -2 -b:a 48k -map_metadata -1 vorbis_stereo.ogg

# --- Music formats (the superset build) --------------------------------------------------------
# Lossless and PCM containers (the PCM ones 2 s long): deterministic under +bitexact. The Matroska
# pair is not (random segment UID), so re-running changes their sha256.
$FF -i "$TMP/s44.wav" -c:a flac -map_metadata -1 flac_stereo.flac
$FF -i "$TMP/s44.wav" -c:a alac -map_metadata -1 alac_stereo.m4a
$FF -i "$TMP/s44.wav" -t 2 -c:a pcm_s16le -map_metadata -1 wav_s16.wav
$FF -i "$TMP/s44.wav" -t 2 -c:a pcm_s24le -map_metadata -1 wav_s24.wav
$FF -i "$TMP/s44.wav" -t 2 -c:a pcm_s16be -map_metadata -1 aiff_s16.aiff
$FF -i "$TMP/s48.wav" -c:a libopus -b:a 32k -map_metadata -1 opus_stereo.mka
$FF -i "$TMP/s44.wav" -c:a vorbis -strict -2 -b:a 48k -map_metadata -1 vorbis_stereo.webm

ls -l *.mp3 *.m4a *.aac *.opus *.ogg *.flac *.wav *.aiff *.mka *.webm | awk '{print $5, $9}'

# --- Fixtures of Tests/PlaybackDecodeTests/Fixtures (#43, #47) ----------------------------------
# These four are written to ../../PlaybackDecodeTests/Fixtures, 1 to 3 s of plain sines (no sweep),
# and are not covered by the conformance goldens. The Ogg pair is not byte-reproducible (random
# stream serials).
OUT=../../PlaybackDecodeTests/Fixtures
tone() { # rate channels seconds out: 440 Hz left (and mono), 660 Hz right
    if [ "$2" = 1 ]; then E="0.7*sin(2*PI*440*t)"; else E="0.7*sin(2*PI*440*t)|0.7*sin(2*PI*660*t)"; fi
    $FF -f lavfi -i "aevalsrc=${E}:s=$1:d=$3" -c:a pcm_s16le "$4"
}
# Chained Ogg: two complete streams concatenated byte for byte, 3 s each. Vorbis changes the rate
# (44.1 -> 48 kHz), Opus the channel count (mono -> stereo; Opus is always 48 kHz).
tone 44100 2 3 "$TMP/c_v44.wav"; tone 48000 2 3 "$TMP/c_v48.wav"
tone 48000 1 3 "$TMP/c_om.wav";  tone 48000 2 3 "$TMP/c_os.wav"
$FF -i "$TMP/c_v44.wav" -c:a vorbis -strict -2 -b:a 48k -map_metadata -1 "$TMP/c_v44.ogg"
$FF -i "$TMP/c_v48.wav" -c:a vorbis -strict -2 -b:a 48k -map_metadata -1 "$TMP/c_v48.ogg"
$FF -i "$TMP/c_om.wav" -c:a libopus -b:a 32k -map_metadata -1 "$TMP/c_om.opus"
$FF -i "$TMP/c_os.wav" -c:a libopus -b:a 32k -map_metadata -1 "$TMP/c_os.opus"
cat "$TMP/c_v44.ogg" "$TMP/c_v48.ogg" > "$OUT/chained_vorbis_44k_48k.ogg"
cat "$TMP/c_om.opus" "$TMP/c_os.opus" > "$OUT/chained_opus_mono_stereo.opus"

# 5.1 FLAC, 16-bit 48 kHz, 1 s: one tone per channel in FLAC's order (FL 220, FR 330, FC 440,
# LFE 550, BL 660, BR 770 Hz, each 0.15). The downmix test reads the levels back per tone.
$FF -f lavfi -i "aevalsrc=0.15*sin(2*PI*220*t)|0.15*sin(2*PI*330*t)|0.15*sin(2*PI*440*t)|0.15*sin(2*PI*550*t)|0.15*sin(2*PI*660*t)|0.15*sin(2*PI*770*t):s=48000:d=1:c=5.1" \
    -c:a flac -sample_fmt s16 -map_metadata -1 "$OUT/flac_51_48k.flac"
# 192 kHz / 24-bit stereo FLAC, 0.5 s (a sine does not compress, so longer would pass 300 KB).
$FF -f lavfi -i "aevalsrc=0.7*sin(2*PI*440*t)|0.7*sin(2*PI*660*t):s=192000:d=0.5" \
    -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 -map_metadata -1 "$OUT/flac_192k_24bit.flac"
