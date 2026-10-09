#!/usr/bin/env bash
#
# package-ffmpeg-source.sh X.Y.Z [OUT_DIR] — pack dist/ffmpeg-X.Y.Z-source.tar.xz (default OUT_DIR=dist).
#
# LGPL-2.1 section 6: the apps embed this release's FFmpeg, so its exact source, patches and build
# recipe are published beside it. The tarball is laid out like the repo (scripts/, the FFmpeg tree
# beside it), so scripts/build-ffmpeg.sh runs unchanged from the extracted directory. release.sh
# calls this before tagging; it can be run alone to check the tarball rebuilds.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/package-ffmpeg-source.sh X.Y.Z [OUT_DIR]" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
out_dir="${2:-dist}"

ffmpeg_tag="$(head -1 Frameworks/FFmpeg.xcframework/VERSION.txt)"
source_name="ffmpeg-$version-source"
archive="$out_dir/$source_name.tar.xz"
staging="$(mktemp -d)"
done_ok=0
cleanup() {
    rm -rf "$staging" "$staging.list"
    [[ "$done_ok" == 1 ]] || rm -f "$archive"
}
trap cleanup EXIT

echo "package-ffmpeg-source: FFmpeg $ffmpeg_tag source as $archive"
root="$staging/$source_name"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ffmpeg_tag" https://git.ffmpeg.org/ffmpeg.git \
    "$root/ffmpeg-$ffmpeg_tag"
rm -rf "$root/ffmpeg-$ffmpeg_tag/.git"
mkdir -p "$root/scripts"
cp -R scripts/ffmpeg-patches "$root/scripts/ffmpeg-patches"
cp scripts/build-ffmpeg.sh scripts/ffmpeg-exports.txt "$root/scripts/"
cp Frameworks/FFmpeg.xcframework/VERSION.txt "$root/"
cat > "$root/README.txt" <<README
FFmpeg $ffmpeg_tag source, local patches and build recipe for shuttle-playback $version.

Rebuild the dynamic framework (macOS, Xcode with the iOS SDKs):

    scripts/build-ffmpeg.sh

It finds the FFmpeg tree in ffmpeg-$ffmpeg_tag/ beside scripts/ (or at \$FFMPEG_SRC), applies
scripts/ffmpeg-patches/ and writes Frameworks/FFmpeg.xcframework. VERSION.txt records the configure
flags and patch hashes of the shipped binary.
README

mkdir -p "$out_dir"
# Reproducible archive (bsdtar): sorted members, the commit's date as mtime, root ownership.
stamp="$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d%H%M.%S HEAD)"
(cd "$staging" && find "$source_name" -exec touch -h -t "$stamp" {} + && find "$source_name" | LC_ALL=C sort > "$staging.list")
tar -cJf "$archive" -C "$staging" --no-recursion --uid 0 --gid 0 --numeric-owner -T "$staging.list"
done_ok=1
