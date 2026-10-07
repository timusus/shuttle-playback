# ADR-0008: Conformance testing modelled on media3

Status: Accepted
Date: 2026-10-08

## Context

Two apps play whatever servers send, including truncated files, junk prefixes, odd encoders and
flaky connections. Comparing a decode with `AVAssetReader` shows only what Apple decodes. Android's
media3 already tests its extractors against such input, and the plan to follow it is in the Podcasts
repo's `playback-edge-case-catalogue.md`.

## Decision

The conformance suite follows media3:

- `FaultyByteReader` ports media3's `FakeExtractorInput`: partial reads, one-shot I/O errors and
  unknown length.
- The 7-combination fault matrix and the goldens mirror `ExtractorAsserts` and `DumpFileAsserts`.
  Every fixture must decode bit-identically to the clean decode under all 7, and match its golden.
- Every supported format has a fixture. An untested format is not supported.
- A decoder bug that is found and not fixed is pinned exactly in `KnownIssues.swift`, with its issue.
- The three media3 assets are copied unmodified, with their licence (Apache-2.0), under
  `Fixtures/NOTICE`. Every other fixture is synthesised by `make-fixtures.sh`.

## Alternatives rejected

- Synthetic fixtures only: they miss what real encoders do.
- Compare against `AVAssetReader` only: it cannot cover formats Apple does not decode and has no
  fault injection.

## Consequences

- A decoder change that moves PCM shows as a golden diff to review, and a regenerated golden is
  written only if the fault matrix passes against it.
- Some encoder outputs are not byte-reproducible, so `make-fixtures.sh` is re-run only on purpose.
- The byte source has the same treatment: `GrowingFileContractTests` ports media3's
  `DataSourceContractTest`. The extractor-test port is still partial (#33).

Links: [contributing](../contributing.md), [ADR-0006](0006-one-superset-ffmpeg.md).
