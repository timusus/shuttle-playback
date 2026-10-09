# ADR-0001: FFmpeg for demux and decode

Status: Accepted, amended by ADR-0006 (one build)
Date: 2026-09-09 (FFmpeg decode); 2026-10-09 (dynamic framework); superseded in part by ADR-0006 (one build, no profiles)

## Context

The engine needs a streaming demuxer and decoder for whatever container a server sends, including
MP4 with the `moov` atom at the end of the file. An app that also runs its own code against
libavformat can then decode with the same FFmpeg as the player.

## Decision

We demux and decode with FFmpeg (tag n7.1) through a custom seekable `AVIOContext`. The build is one
format set shared by both apps (ADR-0006).

FFmpeg ships as one dynamic `FFmpeg.framework` per slice, embedded in each app, because both apps are
closed source and LGPL-2.1 section 6 requires that a user can relink the app against a modified
library. This follows the checklist at https://ffmpeg.org/legal.html (item 2: link dynamically) and
VideoLAN's practice for MobileVLCKit. The other obligations on that list are met as follows:

- Source: `scripts/release.sh` writes the exact FFmpeg tag, `scripts/ffmpeg-patches/` and the
  configure line to `dist/ffmpeg-X.Y.Z-source.tar.xz`, attached to that release.
- Licence: `COPYING.LGPLv2.1` is inside every framework, so it ships in every app.
- App-side, owned by each app: an About notice that the app uses FFmpeg under the LGPL-2.1, with a
  link to the source, and a custom EULA that permits reverse engineering to debug such modifications
  (Apple's standard EULA does not).

The build never enables GPL, version3 or nonfree code, nor an external library beyond the system ones.

## Alternatives rejected

- `AudioFileStream` with `AudioConverter`: cannot stream an MP4 whose `moov` is at the end
  (`kAudioFileStreamError_NotOptimized`). We would write an MP4 sample-table parser and an Ogg
  demuxer ourselves.
- `AVAssetReader`: needs a finished, seekable asset. Given an `https://` URL it yields no frame and
  no error.
- Separate SwiftPM products per format set: two C targets built from the same sources, for no
  consumer.
- Static linking with object files on request: legal under LGPL-2.1 section 6(a), but every release
  would need its app objects published, and Xcode offers no supported way to relink an App Store build.
- One framework per FFmpeg library (as ffmpeg-kit ships): four binary targets and four embedded
  bundles for no gain, since the libraries are only ever used together.
- Mergeable libraries: an App Store build merges the framework back into the app binary, which undoes
  the point.

## Consequences

- A C shim and an FFmpeg build script to maintain. The framework binary is about 1.7 MB per platform
  slice, and all of it ships: an app can no longer dead-strip FFmpeg code its shim never calls.
- Adding Ogg was a rebuild flag, not a parser.
- FFmpeg's headers live in a `CFFmpeg` C target beside the binary target: FFmpeg's headers include
  each other as `libavutil/...`, which a framework's `Headers` directory cannot resolve.
- Each release carries a source tarball, and each app owes the About notice and EULA above.
- The shim stays codec-agnostic. A missing codec is FFmpeg saying no, never a branch of ours.
- FFmpeg bugs the tag lacks are fixed with local patches. See [contributing](../contributing.md#ffmpeg).

Links: [architecture](../architecture.md), [contributing](../contributing.md#ffmpeg).
