#!/usr/bin/env bash
#
# build-ffmpeg.sh — the FFmpeg dynamic xcframework the decoder links: ONE build, the music
# superset, embedded by both apps (docs/decisions/0006).
#
# The C shim (`Sources/CStreamDecode`) has no `#if` per codec, it asks FFmpeg to probe and find a
# decoder, so a codec that is not compiled in simply means "FFmpeg said no".
#
#   decoders  mp3, AAC (ADTS and LATM), Opus, Vorbis, FLAC, ALAC, PCM (s16/s24/s32/f32/f64/u8)
#   demuxers  mp3, aac, loas, mov (MP4/M4A), ogg, flac, wav, aiff, matroska (WebM)
#   zlib      the system zlib, for Matroska header compression
#
# Output, both COMMITTED (CLAUDE.md says why):
#   Frameworks/FFmpeg.xcframework  ONE dynamic FFmpeg.framework per slice (ios-arm64,
#                                  ios-arm64-simulator, macos-arm64) holding libavformat +
#                                  libavcodec + libswresample + libavutil, install name
#                                  @rpath/FFmpeg.framework/FFmpeg.
#   Sources/CFFmpeg/include/lib*   their headers, identical across slices. They live in the
#                                  `CFFmpeg` target, not the framework, so `#include
#                                  <libavformat/avformat.h>` keeps working: a framework header
#                                  path would need `<FFmpeg/...>`, which FFmpeg's own headers do not use.
# The macOS slice is never shipped in an app; it is what lets `swift test` run the decoder tests on
# the Mac without a simulator.
#
# LICENCE: plain LGPL v2.1+. No --enable-gpl, no --enable-version3, no --enable-nonfree, and no
# external libraries are linked, so the only third-party code in the framework is FFmpeg's own
# LGPL-2.1 tree. The licence text is copied into the xcframework and every framework. The library
# is a separate dynamic framework in each app so a user can swap in a modified FFmpeg (LGPL-2.1
# section 6, https://ffmpeg.org/legal.html); never link it statically and never add a GPL-only
# component to the build.
#
# Usage:
#   scripts/build-ffmpeg.sh                         # clones n7.1 itself
#   FFMPEG_SRC=/path/to/ffmpeg-n7.1 scripts/build-ffmpeg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_DIR/Frameworks}"
HEADERS_DIR="$REPO_DIR/Sources/CFFmpeg/include"

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

BUILD_ROOT="${BUILD_ROOT:-${TMPDIR:-/tmp}/shuttle-playback-ffmpeg}"
FFMPEG_TAG="${FFMPEG_TAG:-n7.1}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-17.0}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-14.0}"

# The four libraries the decode path needs, in link order.
LIBS=(libavformat libavcodec libswresample libavutil)

# What the libraries call outside themselves, all shipped with the OS: zlib (ID3v2, MP4 `cmov`,
# Matroska header compression), iconv (metadata conversion), and the frameworks libavutil's
# VideoToolbox hardware context needs (built in although nothing here decodes video).
SYSTEM_LIBS=(-lz -liconv -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox)
FRAMEWORK_ID="com.simplecityapps.FFmpeg"
FRAMEWORK_VERSION="${FFMPEG_TAG#n}"

# ── formats ──────────────────────────────────────────────────────────────────
# The superset: Shuttle Podcasts' formats (mp3/aac/mov, Ogg Opus and Vorbis) plus Shuttle2's music
# formats (FLAC, ALAC, WAV/AIFF PCM, Matroska). Shuttle2's own list is the floor.
DECODERS=mp3,mp3float,aac,aac_latm,opus,vorbis,flac,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_u8
DEMUXERS=mp3,aac,loas,mov,ogg,flac,wav,aiff,matroska
PARSERS=mpegaudio,aac,aac_latm,opus,vorbis,flac
XCFRAMEWORK_NAME="FFmpeg.xcframework"

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
    --disable-autodetect
    --enable-zlib
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
# The published source tarball carries the FFmpeg tree beside scripts/, so it builds as extracted.
if [ -z "${FFMPEG_SRC:-}" ] && [ -f "$REPO_DIR/ffmpeg-$FFMPEG_TAG/configure" ]; then
    FFMPEG="$REPO_DIR/ffmpeg-$FFMPEG_TAG"
fi
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

# ── local patches ────────────────────────────────────────────────────────────
# Fixes the decoder needs that the FFmpeg tag lacks, each a small diff with its reason in its
# header. Applied once (a patch that already reverse-applies is in place) and listed in VERSION.txt.
PATCHES=()
PATCH_HASHES=()
for PATCH in "$SCRIPT_DIR"/ffmpeg-patches/*.patch; do
    [ -e "$PATCH" ] || continue
    PATCHES+=("$(basename "$PATCH")")
    PATCH_HASHES+=("$(shasum -a 256 "$PATCH" | cut -d' ' -f1) $(basename "$PATCH")")
    if git -C "$FFMPEG" apply --reverse --check "$PATCH" 2>/dev/null; then continue; fi
    log "Applying $(basename "$PATCH")"
    git -C "$FFMPEG" apply "$PATCH"
done

# Identifies what the static libraries were built from; RELINK_ONLY refuses libraries that differ.
BUILD_STAMP="$({ echo "$FFMPEG_TAG"; echo "${CONFIGURE_FLAGS[*]}"; echo "$DEPLOYMENT_TARGET $MACOS_DEPLOYMENT_TARGET"; printf '%s\n' ${PATCH_HASHES[@]+"${PATCH_HASHES[@]}"}; } | shasum -a 256 | cut -d' ' -f1)"

# ── one platform ─────────────────────────────────────────────────────────────
# $1 slice name (device|simulator|macos), $2 SDK, $3 clang -target triple
build_slice() {
    local NAME="$1" SDK="$2" TRIPLE="$3"
    local PREFIX="$BUILD_ROOT/prefix-$NAME"
    local BUILD_DIR="$BUILD_ROOT/build-$NAME"
    local SYSROOT
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"

    log "Building FFmpeg for $NAME ($TRIPLE)"
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
    echo "$BUILD_STAMP" > "$PREFIX/lib/build.stamp"
}

# One dynamic framework per slice. Every object of the four archives goes in (-force_load), not only
# what today's shim calls: the framework is the replaceable unit, so it carries the whole public API.
# $1 slice name, $2 SDK, $3 clang -target triple, $4 CFBundleSupportedPlatforms entry
framework_slice() {
    local NAME="$1" SDK="$2" TRIPLE="$3" PLATFORM="$4"
    local PREFIX="$BUILD_ROOT/prefix-$NAME"
    local FW="$BUILD_ROOT/framework-$NAME/FFmpeg.framework"
    local SYSROOT
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    rm -rf "$BUILD_ROOT/framework-$NAME"

    local BINARY INSTALL_NAME RESOURCES MIN_OS_KEY MIN_OS
    if [ "$NAME" = macos ]; then
        # macOS frameworks use the versioned bundle layout; codesign rejects a shallow one.
        RESOURCES="$FW/Versions/A/Resources"
        mkdir -p "$RESOURCES"
        ln -s A "$FW/Versions/Current"
        ln -s Versions/Current/FFmpeg "$FW/FFmpeg"
        ln -s Versions/Current/Resources "$FW/Resources"
        BINARY="$FW/Versions/A/FFmpeg"
        INSTALL_NAME="@rpath/FFmpeg.framework/Versions/A/FFmpeg"
        MIN_OS_KEY=LSMinimumSystemVersion
        MIN_OS="$MACOS_DEPLOYMENT_TARGET"
    else
        RESOURCES="$FW"
        mkdir -p "$FW"
        BINARY="$FW/FFmpeg"
        INSTALL_NAME="@rpath/FFmpeg.framework/FFmpeg"
        MIN_OS_KEY=MinimumOSVersion
        MIN_OS="$DEPLOYMENT_TARGET"
    fi

    local FORCE_LOAD=()
    for l in "${LIBS[@]}"; do FORCE_LOAD+=("-Wl,-force_load,$PREFIX/lib/$l.a"); done
    xcrun --sdk "$SDK" clang -target "$TRIPLE" -isysroot "$SYSROOT" -dynamiclib \
        -install_name "$INSTALL_NAME" \
        -compatibility_version 1 -current_version "$FRAMEWORK_VERSION" \
        -Wl,-dead_strip \
        -Wl,-exported_symbols_list,"$SCRIPT_DIR/ffmpeg-exports.txt" \
        "${FORCE_LOAD[@]}" "${SYSTEM_LIBS[@]}" \
        -o "$BINARY"

    cat > "$RESOURCES/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FFmpeg</string>
    <key>CFBundleIdentifier</key>
    <string>$FRAMEWORK_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FFmpeg</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>$FRAMEWORK_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$FRAMEWORK_VERSION</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$PLATFORM</string>
    </array>
    <key>$MIN_OS_KEY</key>
    <string>$MIN_OS</string>
</dict>
</plist>
PLIST
    plutil -lint "$RESOURCES/Info.plist" >/dev/null
    # App Store upload requires a manifest per embedded framework. The binary imports fstat, a
    # file-timestamp API. C617.1 covers files in the app, app-group or CloudKit containers; 3B52.1
    # covers files the user granted access to (document picker, security-scoped URLs). The apps
    # read both kinds. FFmpeg itself touches no other required-reason API.
    cat > "$RESOURCES/PrivacyInfo.xcprivacy" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
                <string>3B52.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
    plutil -lint "$RESOURCES/PrivacyInfo.xcprivacy" >/dev/null
    # The licence travels inside every app that embeds the framework.
    cp "$FFMPEG/COPYING.LGPLv2.1" "$RESOURCES/COPYING.LGPLv2.1"
}

# RELINK_ONLY=1 reuses the static libraries of an earlier run, for a change to the link step alone.
# VERSION.txt is written from the current patches and flags, so the libraries must match them.
if [ "${RELINK_ONLY:-0}" = 1 ]; then
    for NAME in device simulator macos; do
        LIB_DIR="$BUILD_ROOT/prefix-$NAME/lib"
        for l in "${LIBS[@]}"; do
            [ -f "$LIB_DIR/$l.a" ] || { echo "ERROR: RELINK_ONLY=1 but $LIB_DIR/$l.a is missing; run a full build first" >&2; exit 1; }
        done
        if [ ! -f "$LIB_DIR/build.stamp" ]; then
            echo "ERROR: RELINK_ONLY=1 but $LIB_DIR has no build.stamp (built before stamps existed); run a full build" >&2
            exit 1
        fi
        if [ "$(cat "$LIB_DIR/build.stamp")" != "$BUILD_STAMP" ]; then
            echo "ERROR: RELINK_ONLY=1 but the $NAME libraries were built from different patches, flags, deployment targets or FFmpeg tag; run a full build" >&2
            exit 1
        fi
    done
else
    build_slice device iphoneos "arm64-apple-ios${DEPLOYMENT_TARGET}" >/dev/null
    build_slice simulator iphonesimulator "arm64-apple-ios${DEPLOYMENT_TARGET}-simulator" >/dev/null
    build_slice macos macosx "arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}" >/dev/null
fi
framework_slice device iphoneos "arm64-apple-ios${DEPLOYMENT_TARGET}" iPhoneOS
framework_slice simulator iphonesimulator "arm64-apple-ios${DEPLOYMENT_TARGET}-simulator" iPhoneSimulator
framework_slice macos macosx "arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}" MacOSX

OUT="$OUT_DIR/$XCFRAMEWORK_NAME"
log "Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework \
    -framework "$BUILD_ROOT/framework-device/FFmpeg.framework" \
    -framework "$BUILD_ROOT/framework-simulator/FFmpeg.framework" \
    -framework "$BUILD_ROOT/framework-macos/FFmpeg.framework" \
    -output "$OUT" >/dev/null

cp "$FFMPEG/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
{
    echo "$FFMPEG_TAG"
    echo "configured: ${CONFIGURE_FLAGS[*]}"
    echo "patches: ${PATCHES[*]:-none}"
    for h in ${PATCH_HASHES[@]+"${PATCH_HASHES[@]}"}; do echo "patch-sha256: $h"; done
    echo "linkage: dynamic FFmpeg.framework per slice, install name @rpath/FFmpeg.framework/FFmpeg, exports only $(tr '\n' ' ' < "$SCRIPT_DIR/ffmpeg-exports.txt")(ffmpeg-exports.txt), links ${SYSTEM_LIBS[*]}"
} > "$OUT/VERSION.txt"

# The headers are the same on every slice (arm64 only); the module map beside them is hand-written.
log "Installing headers into $HEADERS_DIR"
diff -r "$BUILD_ROOT/prefix-device/include" "$BUILD_ROOT/prefix-simulator/include" >/dev/null
diff -r "$BUILD_ROOT/prefix-device/include" "$BUILD_ROOT/prefix-macos/include" >/dev/null
mkdir -p "$HEADERS_DIR"
for l in "${LIBS[@]}"; do
    rm -rf "${HEADERS_DIR:?}/$l"
    cp -R "$BUILD_ROOT/prefix-device/include/$l" "$HEADERS_DIR/$l"
done

log "Done"
du -sh "$OUT"
find "$OUT" -type f -name FFmpeg -exec ls -la {} \;
