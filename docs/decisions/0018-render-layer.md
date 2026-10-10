# ADR-0018: A render layer over AVSampleBufferAudioRenderer

Status: Proposed (pending the iPhone checks below)
Date: 2026-10-11

## Context

Both apps hand-roll output on `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitTimePitch`
(podcasts about 2,700 lines, Shuttle2 about 1,700). Each has re-derived the same clock and scheduling
rules, and they share bugs:
- The time-pitch unit holds about 81 ms and runs the node clock 3584 frames ahead even at 1x. After
  a paused seek it plays stale audio (podcasts #396).
- `playerTime(forNodeTime:)` is nil while paused (#397, Shuttle2 #714).
- Output latency is added by hand.
A macOS spike (`Spikes/RenderSpike` on `worktree-render-spike`) reproduced all three on the engine.
On `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` it measured:
- after `flush()` + `setRate(0, time: 10)` the clock reads exactly 10.000000;
- while paused the clock is frozen and readable;
- output latency is already included;
- drift is 9 ppm against the host clock;
- a 1 → 2 → 1 rate change stays in media time with no auto-flush;
- 44.1k mono → 48k stereo mid-stream gives no error.
It also measured three gaps:
- the clock runs on through an underrun with no notification;
- PTS holes and overlaps are accepted silently;
- the renderer pulls once a second with near-zero headroom.

## Decision

We will add a `PlaybackRender` product, which depends on `PlaybackDecode` only.

It holds four parts:
- **An `AudioProcessor` pipeline** with media3 `AudioProcessingPipeline` semantics on Float32 interleaved: configure, then flush to apply; inactive processors are skipped; drain at end of stream.
- **A `MediaPositionMap`** with media3 `applyMediaPositionParameters` semantics. Dropped frames are credited when the playhead reaches them, not when they are processed. Item boundaries are reported on crossing.
- **A current-plus-next scheduler** that joins items gaplessly at each item's native rate and channel count.
- **One `AudioOutput` seam** over ASBAR and the synchronizer.

The core assigns contiguous output timestamps itself. It detects underruns from the clock passing the enqueued end. It keeps its own depth ahead of `currentTime()`, and does not wait to be asked. Speed is the synchronizer rate. The effects stay in the apps ([ADR-0005](0005-shared-engine-repo.md)), as processors.

### Layering

Each layer depends only on the one below it. Only one thing crosses a boundary: a *tagged chunk*,
which is PCM plus segment tags mapping its output frames to (item, media frame). A feature is a
component in one layer, and the layers beneath see only the tags it produced, never the feature.

| Layer | Owns | Does not know |
|---|---|---|
| Transport | play, pause, seek, set next, speed. It turns each into epochs and calls downward | PCM, timestamps |
| Sequencer | current and next item sources, and the join between them through one `Transition` strategy | processors, output |
| Pipeline | the processors, which transform chunks and rewrite tags when they drop or add frames | items, transport |
| Feeder | contiguous output timestamps, depth ahead of the clock, underruns, flush and re-feed | why a tag says what it says |
| Timeline | `MediaPositionMap` from the played output frame to (item, media frame), and boundary crossings | transitions, effects |
| Output | the `AudioOutput` seam and its ASBAR adapter, or a fake | everything above |

How features fit:
- A gapless join is the default `Transition`, which concatenates.
- Crossfade is a second `Transition` in its own file. It reads A's tail and B's head, brings B to A's format for the overlap, mixes them, and tags the overlap frames to whichever item should report the position. Nothing else changes.
- Skip-silence and ad cuts are pipeline processors that drop frames and rewrite tags.
- Speed is the transport setting the output rate.
- None of them adds a branch to the feeder, the timeline or the output. A feature that needs one is designed wrong.

## Alternatives rejected

- `AVAudioEngine`, which is what the apps run today: its clock is nil while paused and leaves output latency to us. Speed needs a time-pitch unit whose buffering the clock cannot see. It is not named for AirPlay 2 enhanced buffering.
- `AVAudioSourceNode` with our own ring buffer: we would own real-time-thread code and estimate latency ourselves, and every route behaviour would be our bug.
- Sonic in-process for speed: a speed change would wait behind the queued audio, and the position map would need a speed checkpoint. The synchronizer rate measured exact.
- One fixed output rate (as Shuttle2 does today): it rules out hi-res and multichannel, and ASBAR took the format change.

## Consequences

- There is no offline render mode, so every rule lives in the Apple-free core. The core is tested against a fake output with a manual clock that can inject an auto-flush, a configuration change or a stall. The ASBAR adapter stays thin and is checked on device.
- A route change may auto-flush. The core must re-feed from the flush time, which the sample-accurate seek ([ADR-0009](0009-seeks-are-sample-accurate.md)) allows.
- `audioTimePitchAlgorithm` must be set explicitly, because the iOS default (`lowQualityZeroLatency`) is wrong for speech.
- Tests to port from media3 and the fixtures are listed in [#93](https://github.com/timusus/AudioPlaybackKit/issues/93#issuecomment-6100145321).
- Before Accepted, an iPhone must answer:
  1. Does a mid-stream rate change, including 96/192 kHz, switch hardware rate or glitch?
  2. How deep is the AirPlay 2 buffer, and does the clock still match what is heard?
  3. Which route changes auto-flush?
  4. Does a rate change auto-flush on iOS, and is it audible?
  5. Is the one-second pull cadence audible?
  6. Are PTS holes heard as silence or butt-joined?
  7. What do `flush()` and `setRate` cost on device?

Links: [#93](https://github.com/timusus/AudioPlaybackKit/issues/93), [ADR-0005](0005-shared-engine-repo.md),
[ADR-0010](0010-the-decoder-owns-output-format-conversion.md).
