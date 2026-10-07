# ADR-0005: A shared engine repository, scoped to decode

Status: Accepted
Date: 2026-10-07

## Context

Shuttle2 copied the decoder layer from Shuttle Podcasts, and the two copies diverged. The podcast app
should not carry music features.

## Decision

The decode layer lives in this repository, and both apps depend on it through SwiftPM. It holds
decode, byte sources and FFmpeg. It does not hold effects or DSP, and it knows nothing about podcasts,
ads, queues, players or UI. Effects such as skip-silence and Voice Boost stay in the apps. They are PCM
in and PCM out, with no coupling to the decoder, and each app's needs differ. FFmpeg formats come
from each app's build profile.

The repository has no hosted CI. It is built, tested and released with version tags locally.
It is public under GPL-3.0, with a commercial licence on request, so SwiftPM resolves it over HTTPS
with no token.

## Alternatives rejected

- A package inside one app's monorepo: SwiftPM needs `Package.swift` at the root of a repository for
  a URL dependency, and a path dependency needs a sibling checkout.
- Keep copying: the copies had already diverged.
- One build with every codec: it adds about 0.3 to 0.4 MB of code to an app that does not need it.
- Move the effects here too: they were extracted once and moved back. The repository stays about
  playback input, not audio processing.

## Consequences

- Every decoder fix is a fix, a tag and a version bump in each app.
- Byte sources specific to an app stay in the app. Only the growing-file source is shared, as an
  opt-in product, and its auth headers arrive already resolved.
- The FFmpeg xcframework is committed to the repository, because SwiftPM does not run Git LFS and
  there is no hosted CI to publish release assets. See [FFmpeg](../ffmpeg.md).
- A public API change is a minor bump while the version is 0.x. A change that alters the PCM the
  decoder produces is at least a minor bump too.

Links: [architecture](../architecture.md#package-layout), [testing](../testing.md).
