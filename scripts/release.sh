#!/usr/bin/env bash
#
# release.sh X.Y.Z — test, tag and push a release that consumers can pin.
#
# Refuses a dirty tree, a branch other than main, a malformed or existing tag, and a red
# `swift test`. Tags are bare semver (0.1.0), which is what SwiftPM's `from:` resolves.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/release.sh X.Y.Z" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
    echo "release.sh: on '$branch', releases are cut from main" >&2
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
if git rev-parse -q --verify origin/main >/dev/null \
    && ! git merge-base --is-ancestor origin/main HEAD; then
    echo "release.sh: origin/main has commits this branch lacks; pull first" >&2
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

git tag -a "$version" -m "shuttle-playback $version"
git push origin main
git push origin "$version"
echo "release.sh: released $version ($(git rev-parse --short HEAD))"
