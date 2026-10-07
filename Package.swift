// swift-tools-version: 5.9
// The decode layer shared by Shuttle Podcasts and Shuttle2 on iOS: a static FFmpeg built per app
// profile, the streaming decoder that drives it, and the stand-alone DSP stages. Nothing here knows
// what a podcast, an ad or a queue is. See CLAUDE.md for build, test and release.
import PackageDescription

let package = Package(
    name: "shuttle-playback",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The pull decoder: a `StreamByteReader` in, interleaved Float32 PCM at the source's own
        // rate out, seekable and cancellable.
        .library(name: "PlaybackDecode", targets: ["PlaybackDecode"]),
        // Skip silence: trims long silent runs from a PCM stream. Samples in, samples out.
        .library(name: "SilenceGate", targets: ["SilenceGate"]),
        // Voice Boost: the BS.1770 meter, makeup gain, EQ, compressor and limiter, as one
        // processor plus the stages it is built from.
        .library(name: "VoiceEnhance", targets: ["VoiceEnhance"]),
        // The static FFmpeg itself, for a consumer with its own C against libavformat (Shuttle
        // Podcasts' scanner decode). One FFmpeg per app: two copies of the same static symbols
        // would be a duplicate-symbol link failure, or worse, a silent pick of one.
        .library(name: "FFmpeg", targets: ["CFFmpeg"]),
    ],
    targets: [
        // Committed, not downloaded: see README.md "Where the xcframework lives". Rebuild with
        // `scripts/build-ffmpeg.sh` (profile `podcast`).
        .binaryTarget(name: "CFFmpeg", path: "Frameworks/FFmpeg.xcframework"),
        .target(
            name: "CStreamDecode",
            dependencies: ["CFFmpeg"],
            // libavformat's ID3v2 reader and MP4 `cmov` path call zlib, and its metadata
            // conversion calls iconv. Both ship with the system on iOS and macOS.
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]
        ),
        .target(name: "PlaybackDecode", dependencies: ["CStreamDecode"]),
        .target(name: "SilenceGate"),
        .target(name: "VoiceEnhance"),
        // The fixtures are committed (three 20 s tones, well under 250 KB each): a decoder that
        // has to be handed a podcast before it can be tested is a decoder nobody tests.
        .testTarget(
            name: "PlaybackDecodeTests",
            dependencies: ["PlaybackDecode", "CStreamDecode"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SilenceGateTests", dependencies: ["SilenceGate"]),
        .testTarget(name: "VoiceEnhanceTests", dependencies: ["VoiceEnhance"]),
    ]
)
