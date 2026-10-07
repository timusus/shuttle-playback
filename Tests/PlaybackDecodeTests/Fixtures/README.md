# StreamDecodeTests fixtures

Three encodings of the same 20 s signal, 161 KB each, **committed** (unlike
`SpineNativeTests/Fixtures`, which is a 90 MB corpus episode and is gitignored). A decoder that
needs a podcast handed to it before it can be tested is a decoder nobody runs the tests for.

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

# MP4 with `moov` AFTER `mdat` (ffmpeg's default). This is the plan's §3 bandwidth trap: without a
# working AVIO seek callback FFmpeg read-discards the whole `mdat` to reach it.
ffmpeg -y -i tone.wav -c:a aac -b:a 64k tone_moov_last.m4a

rm tone.wav
```

`StreamDecodeTests.testMoovLastAtomOrder` asserts the two M4A layouts really are what their names
say, by walking the top-level atoms — a re-encode with a different ffmpeg default would otherwise
turn the bandwidth test into a test of nothing.
