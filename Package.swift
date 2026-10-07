// swift-tools-version: 5.9
// The decode layer shared by Shuttle Podcasts and Shuttle2 on iOS: a static FFmpeg built per app
// profile, the streaming decoder that drives it and the byte-source plumbing around it. Nothing here knows
// what a podcast, an ad or a queue is. See CLAUDE.md for build, test and release.
import PackageDescription

let package = Package(
    name: "shuttle-playback",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The pull decoder: a `StreamByteReader` in, interleaved Float32 PCM at the source's own
        // rate out, seekable and cancellable.
        .library(name: "PlaybackDecode", targets: ["PlaybackDecode"]),
        // Opt-in networking: the growing-file byte source (one ranged download per transaction, read
        // while it grows, retried across drops) and its file store. A consumer that only wants the
        // decoder links `PlaybackDecode` and gets none of it.
        .library(name: "PlaybackStreaming", targets: ["PlaybackStreaming"]),
        // A loopback `Range`-aware HTTP server with fault knobs, for a consumer's own tests of
        // anything built on `PlaybackStreaming`. No fixtures in it.
        .library(name: "PlaybackStreamingTestSupport", targets: ["PlaybackStreamingTestSupport"]),
        // The static FFmpeg itself, for a consumer with its own C against libavformat. One FFmpeg per app: two copies of the same static symbols
        // would be a duplicate-symbol link failure, or worse, a silent pick of one.
        .library(name: "FFmpeg", targets: ["CFFmpeg"]),
    ],
    targets: [
        // Committed, not downloaded: see docs/ffmpeg.md#what-is-committed. Rebuild with
        // `scripts/build-ffmpeg.sh` (one music-superset build for both apps).
        .binaryTarget(name: "CFFmpeg", path: "Frameworks/FFmpeg.xcframework"),
        .target(
            name: "CStreamDecode",
            dependencies: ["CFFmpeg"],
            // libavformat's ID3v2 reader and MP4 `cmov` path call zlib, and its metadata
            // conversion calls iconv. Both ship with the system on iOS and macOS. libavutil's
            // VideoToolbox hardware context (hwcontext_videotoolbox.o, built in although nothing
            // here decodes video) calls CoreFoundation, CoreMedia, CoreVideo and VideoToolbox:
            // without them a plain consumer target fails to link (issue #10).
            linkerSettings: [
                .linkedLibrary("z"), .linkedLibrary("iconv"),
                .linkedFramework("CoreFoundation"), .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"), .linkedFramework("VideoToolbox"),
            ]
        ),
        .target(name: "PlaybackDecode", dependencies: ["CStreamDecode"]),
        .target(name: "PlaybackStreaming", dependencies: ["PlaybackDecode"]),
        .target(name: "PlaybackStreamingTestSupport"),
        // Two 20-45 s tone fixtures (under 250 KB each), served over the loopback server.
        .testTarget(
            name: "PlaybackStreamingTests",
            dependencies: ["PlaybackStreaming", "PlaybackStreamingTestSupport", "PlaybackDecode"],
            resources: [.copy("Fixtures")]
        ),
        // The fixtures are committed (three 20 s tones, well under 250 KB each): a decoder that
        // has to be handed a large real-world file before it can be tested is a decoder nobody tests.
        .testTarget(
            name: "PlaybackDecodeTests",
            dependencies: ["PlaybackDecode", "CStreamDecode"],
            resources: [.copy("Fixtures")]
        ),
        // Fault reader, fixture corpus and goldens for the decoder: every faulted decode must equal
        // the clean one. Fixtures and goldens are read by path (see Golden.swift), not as resources.
        .testTarget(name: "PlaybackDecodeConformanceTests", dependencies: ["PlaybackDecode"]),
    ]
)
