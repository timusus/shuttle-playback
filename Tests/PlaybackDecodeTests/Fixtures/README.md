# StreamDecodeTests fixtures

Three encodings of the same 20 s signal (`tone.mp3`, `tone_moov_first.m4a`, `tone_moov_last.m4a`),
161 KB each, **committed**, plus the mid-stream-change fixtures below: the three `stitch_*` MP3s, the
chained Ogg pair (`chained_vorbis_44k_48k.ogg`, 44.1 to 48 kHz; `chained_opus_mono_stereo.opus`,
mono then stereo; 3 s per stream) and the two FLACs (`flac_51_48k.flac`, 5.1 downmix levels;
`flac_192k_24bit.flac`, 192 kHz/24-bit). The conformance suite skips all of them. A decoder that needs a large
real-world file handed to it before it can be tested is a decoder nobody runs the tests for.

The signal is a sum of two sines — 440 Hz left, 660 Hz right — under a 0.05 Hz amplitude sweep, so
no two seconds of it look alike. That is what makes the parity tests' cross-correlation alignment
unambiguous: a plain tone would correlate equally well at every period, and a seek that landed a
second early would still "match".

Regenerate with (`/opt/homebrew/bin/ffmpeg`, any recent build):

```sh
ffmpeg -y -f lavfi -i "aevalsrc=0.7*sin(2*PI*440*t)*(0.55+0.45*sin(2*PI*0.05*t))|0.7*sin(2*PI*660*t)*(0.55+0.45*sin(2*PI*0.05*t)):s=44100:d=20" \
    -c:a pcm_s16le tone.wav

# MP3, 64 kbps CBR, with an ID3v2 tag and a Xing header (the TOC the MP3 seek path reads).
ffmpeg -y -i tone.wav -c:a libmp3lame -b:a 64k -write_xing 1 \
    -metadata title="Spine stream fixture" -metadata artist="Shuttle Podcasts" \
    -id3v2_version 3 tone.mp3

# MP4 with `moov` BEFORE `mdat`: the streaming-friendly layout.
ffmpeg -y -i tone.wav -c:a aac -b:a 64k -movflags +faststart tone_moov_first.m4a

# MP4 with `moov` AFTER `mdat` (ffmpeg's default). This is the trailing-moov bandwidth trap: without a
# working AVIO seek callback FFmpeg read-discards the whole `mdat` to reach it.
ffmpeg -y -i tone.wav -c:a aac -b:a 64k tone_moov_last.m4a

rm tone.wav
```

`StreamDecodeTests.testMoovLastAtomOrder` asserts the two M4A layouts really are what their names
say, by walking the top-level atoms — a re-encode with a different ffmpeg default would otherwise
turn the bandwidth test into a test of nothing.

## stitch_44k_48k_64k.mp3

4 s of 440 Hz left / 660 Hz right at 44.1 kHz, then 4 s of the same at 48 kHz, each a 64 kbps CBR
libmp3lame encode (`-write_xing 0 -id3v2_version 0 -write_id3v1 0`), concatenated at the byte level:
a sample-rate change mid-stream. Used by `testSampleRateChangeMidStreamIsResampledToTheOpenRate` and
`testSeekIntoTheResampledHalfLandsWhereItSays`; the conformance suite skips it.

## stitch_48k_44k_64k.mp3

The same the other way round: 4 s at 48 kHz (168 frames), then 4 s at 44.1 kHz (155 frames), for the
same two tests.

```sh
for r in 48000 44100; do
  ffmpeg -y -f lavfi -i "aevalsrc=0.7*sin(2*PI*440*t)|0.7*sin(2*PI*660*t):s=$r:d=4" \
      -c:a libmp3lame -b:a 64k -write_xing 0 -id3v2_version 0 -write_id3v1 0 h$r.mp3
done
cat h48000.mp3 h44100.mp3 > stitch_48k_44k_64k.mp3   # h44100.mp3 first gives stitch_44k_48k_64k.mp3
```

## stitch_stereo_mono_64k.mp3

4 s of stereo (440 Hz left, 660 Hz right, amplitude 0.5), then 4 s of mono (440 Hz, amplitude 0.5),
both 44.1 kHz 64 kbps CBR, concatenated at the byte level: a channel-count change mid-stream. Used by
`testStereoToMonoSwitchMidStreamComesOutAtFullLevelOnBothChannels` (OutputFormatTests).

```sh
ffmpeg -y -f lavfi -i "aevalsrc=0.5*sin(2*PI*440*t)|0.5*sin(2*PI*660*t):s=44100:d=4" st.wav
ffmpeg -y -f lavfi -i "aevalsrc=0.5*sin(2*PI*440*t):s=44100:d=4" mo.wav
for n in st mo; do
  ffmpeg -y -i $n.wav -c:a libmp3lame -b:a 64k -write_xing 0 -id3v2_version 0 -write_id3v1 0 $n.mp3
done
cat st.mp3 mo.mp3 > stitch_stereo_mono_64k.mp3
```
