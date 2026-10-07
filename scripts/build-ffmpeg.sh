#!/usr/bin/env bash
#
# build-ffmpeg.sh — the FFmpeg static xcframework the decoder links, built for one app PROFILE.
#
# Formats are chosen per app, not per package product: the C shim (`Sources/CStreamDecode`) has no
# `#if` per codec, it asks FFmpeg to probe and find a decoder, so a codec that is not compiled in
# simply means "FFmpeg said no". The profile is the only switch.
#
#   podcast  mp3, AAC (ADTS and LATM), MP4/M4A (`mov`), plus Ogg with Opus and Vorbis.
#            Output: Frameworks/FFmpeg.xcframework, COMMITTED (CLAUDE.md says why).
#   music    podcast + FLAC, ALAC, WAV/AIFF PCM, Matroska. STUB: the list is written down so the
#            Shuttle2 migration starts from it, but nothing builds or tests it yet, so the script
#            refuses it unless FFMPEG_ALLOW_UNVERIFIED_PROFILE=1.
#
# Output layout: ONE static library per slice (ios-arm64, ios-arm64-simulator, macos-arm64) holding
# libavformat + libavcodec + libswresample + libavutil, plus their headers and a `CFFmpeg`
# modulemap. The macOS slice is never shipped in an app; it is what lets `swift test` run the
# decoder tests on the Mac without a simulator.
#
# LICENCE: plain LGPL v2.1+. No --enable-gpl, no --enable-version3, no --enable-nonfree, and no
# external libraries are linked, so the only third-party code in the framework is FFmpeg's own
# LGPL-2.1 tree. The licence text is copied into the xcframework. The library is linked
# statically into each app; do not add a GPL-only component to any profile.
#
# Usage:
#   scripts/build-ffmpeg.sh                         # podcast profile, clones n7.1 itself
#   FFMPEG_PROFILE=podcast FFMPEG_SRC=/path/to/ffmpeg-n7.1 scripts/build-ffmpeg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_DIR/Frameworks}"
PROFILE="${FFMPEG_PROFILE:-podcast}"

# `xcode-select -p` can point at CommandLineTools, which has no xcodebuild or iOS SDKs.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    current="$(xcode-select -p 2>/dev/null || true)"
    if [[ -z "$current" || ! -x "$current/usr/bin/xcodebuild" ]]; then
        for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
            if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then export DEVELOPER_DIR="$candidate"; break; fi
        done
        [[ -n "${DEVELOPER_DIR:-}" ]] || { echo "ERROR: no Xcode with xcodebuild found" >&2; exit 1; }
    fi
fi

BUILD_ROOT="${BUILD_ROOT:-${TMPDIR:-/tmp}/shuttle-playback-ffmpeg-$PROFILE}"
FFMPEG_TAG="${FFMPEG_TAG:-n7.1}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-17.0}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-14.0}"

# The four libraries the decode path needs, in link order.
LIBS=(libavformat libavcodec libswresample libavutil)

# ── profiles ─────────────────────────────────────────────────────────────────
# The podcast set is what Shuttle Podcasts has always shipped (mp3/aac/mov) plus Ogg, Opus and
# Vorbis (owner decision 2026-10-07: some feeds publish Ogg, and Android already decodes it).
PODCAST_DECODERS=mp3,mp3float,aac,aac_latm,opus,vorbis
PODCAST_DEMUXERS=mp3,aac,mov,ogg
PODCAST_PARSERS=mpegaudio,aac,aac_latm,opus,vorbis

case "$PROFILE" in
    podcast)
        DECODERS="$PODCAST_DECODERS"
        DEMUXERS="$PODCAST_DEMUXERS"
        PARSERS="$PODCAST_PARSERS"
        XCFRAMEWORK_NAME="FFmpeg.xcframework"
        ;;
    music)
        # A superset of podcast. Mirrors Shuttle2's own build (S2 ios/scripts/build-ffmpeg.sh) minus
        # nothing; confirm against it when Shuttle2 moves onto this package.
        if [[ "${FFMPEG_ALLOW_UNVERIFIED_PROFILE:-0}" != 1 ]]; then
            echo "ERROR: the music profile is a stub: no test covers FLAC/ALAC/WAV/AIFF/Matroska yet." >&2
            echo "       Set FFMPEG_ALLOW_UNVERIFIED_PROFILE=1 to build it anyway." >&2
            exit 2
        fi
        DECODERS="$PODCAST_DECODERS,flac,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_u8"
        DEMUXERS="$PODCAST_DEMUXERS,flac,wav,aiff,matroska"
        PARSERS="$PODCAST_PARSERS,flac"
        XCFRAMEWORK_NAME="FFmpeg-music.xcframework"
        ;;
    *)
        echo "ERROR: unknown FFMPEG_PROFILE '$PROFILE' (podcast|music)" >&2
        exit 2
        ;;
esac

# --disable-everything switches off every component; the --enable-* lines are the complete
# allow-list. No network protocols at all: bytes arrive through the caller's AVIO read callback.
CONFIGURE_FLAGS=(
    --disable-everything
    --disable-programs
    --disable-doc
    --disable-htmlpages
    --disable-manpages
    --disable-podpages
    --disable-txtpages
    --disable-avdevice
    --disable-swscale
    --disable-postproc
    --disable-avfilter
    --disable-network
    --disable-protocols
    --disable-devices
    --disable-filters
    --disable-bsfs
    --disable-encoders
    --disable-muxers
    --disable-debug
    --disable-symver
    --disable-audiotoolbox
    --enable-decoder="$DECODERS"
    --enable-demuxer="$DEMUXERS"
    --enable-parser="$PARSERS"
    --enable-swresample
    --enable-avformat
    --enable-avcodec
    --enable-avutil
    --enable-static
    --disable-shared
    --enable-pic
    --enable-small
    --enable-cross-compile
    --target-os=darwin
    --arch=arm64
)

log() { printf '\n=== %s\n' "$*"; }

# ── FFmpeg source ────────────────────────────────────────────────────────────
mkdir -p "$BUILD_ROOT"
FFMPEG="${FFMPEG_SRC:-$BUILD_ROOT/ffmpeg-src}"
if [ ! -f "$FFMPEG/configure" ]; then
    # A directory without `configure` is an interrupted clone; git refuses a non-empty target.
    if [ -d "$FFMPEG" ]; then
        log "Removing torn FFmpeg clone (no configure) at $FFMPEG"
        rm -rf "$FFMPEG"
    fi
    log "Cloning FFmpeg $FFMPEG_TAG into $FFMPEG"
    git clone --depth 1 --branch "$FFMPEG_TAG" https://git.ffmpeg.org/ffmpeg.git "$FFMPEG"
fi
[ -f "$FFMPEG/configure" ] || { echo "ERROR: no FFmpeg source at $FFMPEG"; exit 1; }

# ── one platform ─────────────────────────────────────────────────────────────
# $1 slice name (device|simulator|macos), $2 SDK, $3 clang -target triple
build_slice() {
    local NAME="$1" SDK="$2" TRIPLE="$3"
    local PREFIX="$BUILD_ROOT/prefix-$NAME"
    local BUILD_DIR="$BUILD_ROOT/build-$NAME"
    local SYSROOT
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"

    log "Building FFmpeg ($PROFILE) for $NAME ($TRIPLE)"
    rm -rf "$BUILD_DIR" "$PREFIX"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    "$FFMPEG/configure" \
        --prefix="$PREFIX" \
        --cc="xcrun --sdk $SDK clang" \
        --cxx="xcrun --sdk $SDK clang++" \
        --ar="$(xcrun --sdk "$SDK" -f ar)" \
        --ranlib="$(xcrun --sdk "$SDK" -f ranlib)" \
        --sysroot="$SYSROOT" \
        --extra-cflags="-target $TRIPLE -isysroot $SYSROOT -O2 -fno-common" \
        --extra-ldflags="-target $TRIPLE -isysroot $SYSROOT" \
        "${CONFIGURE_FLAGS[@]}"

    make -j"$(sysctl -n hw.ncpu)"
    make install
}

# One static library per slice: an xcframework `-library` slice takes exactly one archive.
merge_slice() {
    local NAME="$1"
    local PREFIX="$BUILD_ROOT/prefix-$NAME"
    local MERGED="$BUILD_ROOT/merged-$NAME"
    rm -rf "$MERGED"
    mkdir -p "$MERGED"
    local ARCHIVES=()
    for l in "${LIBS[@]}"; do ARCHIVES+=("$PREFIX/lib/$l.a"); done
    xcrun libtool -static -o "$MERGED/libffmpeg.a" "${ARCHIVES[@]}" 2>/dev/null
    cp -R "$PREFIX/include" "$MERGED/include"
    # A `-library` xcframework has no module of its own; this modulemap makes `CFFmpeg` importable
    # from C and Swift targets and names exactly the headers the decode shims call.
    cat > "$MERGED/include/module.modulemap" <<'MODMAP'
module CFFmpeg {
    header "libavformat/avformat.h"
    header "libavcodec/avcodec.h"
    header "libswresample/swresample.h"
    header "libavutil/avutil.h"
    header "libavutil/opt.h"
    export *
}
MODMAP
}

build_slice device iphoneos "arm64-apple-ios${DEPLOYMENT_TARGET}" >/dev/null
build_slice simulator iphonesimulator "arm64-apple-ios${DEPLOYMENT_TARGET}-simulator" >/dev/null
build_slice macos macosx "arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}" >/dev/null
merge_slice device
merge_slice simulator
merge_slice macos

OUT="$OUT_DIR/$XCFRAMEWORK_NAME"
log "Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/merged-device/libffmpeg.a" -headers "$BUILD_ROOT/merged-device/include" \
    -library "$BUILD_ROOT/merged-simulator/libffmpeg.a" -headers "$BUILD_ROOT/merged-simulator/include" \
    -library "$BUILD_ROOT/merged-macos/libffmpeg.a" -headers "$BUILD_ROOT/merged-macos/include" \
    -output "$OUT" >/dev/null

cp "$FFMPEG/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
{
    echo "$FFMPEG_TAG"
    echo "profile: $PROFILE"
    echo "configured: ${CONFIGURE_FLAGS[*]}"
} > "$OUT/VERSION.txt"

log "Done"
du -sh "$OUT"
find "$OUT" -name 'libffmpeg.a' -exec ls -la {} \;
