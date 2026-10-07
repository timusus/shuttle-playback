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

git tag -a "$version" -m "shuttle-playback $version"
git push origin main
git push origin "$version"
echo "release.sh: released $version ($(git rev-parse --short HEAD))"
