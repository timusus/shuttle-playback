#!/usr/bin/env bash
#
# release.sh X.Y.Z — test, tag and push a release that consumers can pin.
#
# Refuses a dirty tree, a branch other than main (a detached HEAD must equal origin/main), a malformed or existing tag, and a red
# `swift test`. Tags are bare semver (0.1.0), which is what SwiftPM's `from:` resolves.
# Writes dist/ffmpeg-X.Y.Z-source.tar.xz (package-ffmpeg-source.sh: FFmpeg tree, patches, build script) for
# the owner to attach to the GitHub release; this script creates no release itself.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/release.sh X.Y.Z" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" && "$branch" != "HEAD" ]]; then
    echo "release.sh: on '$branch', releases are cut from main or a detached origin/main" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "release.sh: working tree is dirty; commit or discard first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "release.sh: tag $version already exists" >&2
    exit 1
fi

git fetch --quiet origin
# The landing worktree has no main branch; a detached HEAD must be exactly what was landed.
if [[ "$branch" == "HEAD" && "$(git rev-parse HEAD)" != "$(git rev-parse -q --verify origin/main || true)" ]]; then
    echo "release.sh: detached HEAD is not origin/main; run from the landing worktree after 'git checkout --detach origin/main'" >&2
    exit 1
fi
# A land pushes from its own worktree, leaving this checkout's main behind; catch up, never push ahead.
if git rev-parse -q --verify origin/main >/dev/null \
    && ! git merge-base --is-ancestor origin/main HEAD \
    && git merge-base --is-ancestor HEAD origin/main; then
    echo "release.sh: main is behind origin/main; fast-forwarding"
    git merge --ff-only --quiet origin/main
fi
if git rev-parse -q --verify origin/main >/dev/null \
    && ! git merge-base --is-ancestor origin/main HEAD; then
    echo "release.sh: origin/main has commits this branch lacks; pull first" >&2
    exit 1
fi
# Only landed work is released: tagging local commits ahead of origin would publish unverified code.
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse -q --verify origin/main || true)" ]]; then
    echo "release.sh: main differs from origin/main (unlanded commits); land them first" >&2
    exit 1
fi

# The published source must match the binary: VERSION.txt records the patches it was built with.
recorded_patches="$(sed -n 's/^patch-sha256: //p' Frameworks/FFmpeg.xcframework/VERSION.txt | LC_ALL=C sort)"
actual_patches="$(cd scripts/ffmpeg-patches && { shasum -a 256 *.patch 2>/dev/null || true; } | awk '{print $1 " " $2}' | LC_ALL=C sort)"
if [[ "$recorded_patches" != "$actual_patches" ]]; then
    echo "release.sh: scripts/ffmpeg-patches differs (by content) from the patches recorded in the framework's VERSION.txt; rebuild the framework" >&2
    exit 1
fi

echo "release.sh: swift test"
swift test

# The byte source runs on iOS URLSession in the apps, so its tests also run on a simulator,
# picked by UDID (IOS_SIM_UDID, else the first available iPhone).
udid="${IOS_SIM_UDID:-$(xcrun simctl list devices available | grep -E '^ +iPhone' | head -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')}"
if [[ -z "$udid" ]]; then
    echo "release.sh: no available iPhone simulator; set IOS_SIM_UDID" >&2
    exit 1
fi
echo "release.sh: PlaybackStreamingTests on iOS simulator $udid"
xcodebuild test -scheme shuttle-playback-Package -only-testing:PlaybackStreamingTests \
    -destination "platform=iOS Simulator,id=$udid" -quiet

# Built before tagging, so a tag never lacks its source (LGPL-2.1 section 6); a failed or
# interrupted run leaves no partial tarball.
source_name="ffmpeg-$version-source"
packaged=0
trap '[[ "$packaged" == 1 ]] || rm -f "dist/$source_name.tar.xz"' EXIT
scripts/package-ffmpeg-source.sh "$version"
packaged=1

git tag -a "$version" -m "shuttle-playback $version"
if ! git push origin "$version"; then
    git tag -d "$version" >/dev/null
    echo "release.sh: pushing tag $version failed; local tag removed, rerun to retry" >&2
    exit 1
fi
echo "release.sh: released $version ($(git rev-parse --short HEAD))"
echo "release.sh: attach dist/$source_name.tar.xz to the $version GitHub release"
