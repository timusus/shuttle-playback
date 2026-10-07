# FFmpeg

Reference for the static FFmpeg that ships in `Frameworks/FFmpeg.xcframework`, with the steps to
rebuild it. For why FFmpeg is used at all, see
[ADR-0001](decisions/0001-ffmpeg-for-demux-and-decode.md).

## What is committed

`Frameworks/FFmpeg.xcframework` is committed to git. It is about 11 MB in total. It holds three
slices:

| Slice | Platform |
|---|---|
| `ios-arm64` | iOS devices |
| `ios-arm64-simulator` | iOS simulator on Apple silicon |
| `macos-arm64` | macOS, used by `swift test` |

Each slice has one `libffmpeg.a` and the headers, with a `CFFmpeg` module map. The library is
libavformat, libavcodec, libswresample and libavutil, merged. The xcframework also holds
`COPYING.LGPLv2.1` and `VERSION.txt`. `VERSION.txt` records the FFmpeg tag, the exact
configure flags and the applied patches. Read it to see what a given build contains.

`.gitattributes` marks `*.a` as binary, so git never diffs or normalises it. For why the framework is
committed rather than downloaded, see [Architecture](architecture.md#why-the-ffmpeg-is-committed).

SwiftPM links it through the `CFFmpeg` binary target. `CStreamDecode` also links the system `z` and
`iconv`. libavformat's ID3v2 reader and MP4 `cmov` path call zlib, and metadata conversion calls
iconv.

## Formats

There is one build, the music superset, and both apps link it
([ADR-0006](decisions/0006-one-superset-ffmpeg.md)). It is the list of decoders, demuxers and parsers
below. Everything else is disabled (`--disable-everything`, and `--disable-autodetect` so no system
library is picked up by accident), along with encoders, muxers, filters, protocols, networking,
swscale and the command-line programs. Only libavformat, libavcodec, libswresample and libavutil are
built. zlib (the system one) is enabled for Matroska header compression.

| | Compiled in |
|---|---|
| Decoders | `mp3`, `mp3float`, `aac`, `aac_latm`, `opus`, `vorbis`, `flac`, `alac`, PCM `s16`, `s24`, `s32`, `f32`, `f64` (little and big endian) and `u8` |
| Demuxers | `mp3`, `aac`, `loas`, `mov`, `ogg`, `flac`, `wav`, `aiff`, `matroska` (also WebM) |
| Parsers | `mpegaudio`, `aac`, `aac_latm`, `opus`, `vorbis`, `flac` |

That covers MP3, AAC (ADTS and LATM), MP4 and M4A (AAC and ALAC), Ogg (Opus, Vorbis), FLAC, WAV and
AIFF PCM, and Opus or Vorbis in Matroska or WebM. Each has a fixture in the conformance corpus.

The decoder shim is codec-agnostic. A format that is not in the list fails in FFmpeg and reaches
the caller as `StreamDecoderError.failed`.

## Rebuild

```sh
scripts/build-ffmpeg.sh
```

This builds the music superset into `Frameworks/FFmpeg.xcframework`. A build takes several
minutes. Run it in the foreground.

The script needs Xcode with the iOS SDKs. If `xcode-select` points at the Command Line Tools, it looks
for `/Applications/Xcode.app`. It clones FFmpeg `n7.1` into `$TMPDIR/shuttle-playback-ffmpeg`
the first time.

| Variable | Default | Meaning |
|---|---|---|
| `FFMPEG_TAG` | `n7.1` | The FFmpeg tag to clone. |
| `FFMPEG_SRC` | cloned | A path to an existing FFmpeg checkout. |
| `OUT_DIR` | `Frameworks` | Where the xcframework is written. |
| `BUILD_ROOT` | in `$TMPDIR` | Scratch directory. |
| `DEPLOYMENT_TARGET` | `17.0` | iOS deployment target. |
| `MACOS_DEPLOYMENT_TARGET` | `14.0` | macOS deployment target. |

After a rebuild:

1. Check `git diff` on `VERSION.txt`. It must show the change you intended.
2. Run `swift test`, including the conformance suite. See [Testing](testing.md).
3. Commit the framework on its own, with a message that starts `build: rebuild ffmpeg`.

To change the formats, edit the lists at the top of `scripts/build-ffmpeg.sh`. Add a
fixture and a conformance case for any new format, because an untested format is not supported.

## Local patches

Patches in `scripts/ffmpeg-patches/` are applied by `build-ffmpeg.sh` to the cloned source, before the
build, and listed in `VERSION.txt`. A patch that already reverse-applies is treated as in place.

| Patch | What it fixes |
|---|---|
| `0001-mp3dec-keep-xing-frames-when-size-unknown.patch` | With a source of unknown length, FFmpeg's MP3 demuxer stored the negative "unknown" size in an unsigned variable and discarded the Xing frame count. The gapless end trim and the duration were lost. An unknown size now skips the cross-check, as a zero size already did. |

## Licence

The build is plain LGPL-2.1 or later. The scripts must never add `--enable-gpl`, `--enable-version3`,
`--enable-nonfree`, or an external library beyond the system zlib.

This repository's own code is GPL-3.0 (see the [README](../README.md#licence)). FFmpeg's licence text ships
inside the xcframework. For the relinking obligation that static linking brings, see
[Architecture](architecture.md#why-the-ffmpeg-is-committed).
