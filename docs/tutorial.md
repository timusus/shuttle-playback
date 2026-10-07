# Tutorial: play your first file

In this tutorial you build a small command-line tool that decodes an audio file to PCM and prints its
duration and frame count. You need a Mac with Apple silicon, Xcode 15 or later, and any MP3 or M4A
file. It takes about ten minutes.

## Create the package

In a terminal:

```sh
mkdir -p first-file/Sources/first-file && cd first-file
```

Create `Package.swift` in that directory:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "first-file",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/timusus/shuttle-playback.git", from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "first-file",
            dependencies: [.product(name: "PlaybackDecode", package: "shuttle-playback")],
            linkerSettings: [
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
    ]
)
```

The three frameworks are there because the static FFmpeg refers to them, and a bare command-line
target does not link them for you.

## Decode the file

Create `Sources/first-file/main.swift`:

```swift
import Foundation
import PlaybackDecode

guard CommandLine.arguments.count > 1 else {
    print("usage: first-file <audio file>")
    exit(1)
}

let reader = try FileByteReader(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let decoder = FFmpegStreamDecoder(reader: reader)
let format = try decoder.open()
print("\(format.codec) in \(format.container), \(format.sampleRate) Hz, \(format.channelCount) channels")
print("duration: \(format.duration) s")

var frames = 0
while let chunk = decoder.nextChunk() {
    frames += chunk.count / format.channelCount
}
print("decoded \(frames) frames, ended: \(decoder.endReason)")
```

## Run it

```sh
swift run first-file /path/to/your/file.mp3
```

The first build fetches the package and takes a minute or two. You will see output like this, with
your own file's numbers:

```
mp3 in mp3, 44100.0 Hz, 2 channels
duration: 20.035918 s
decoded 882000 frames, ended: eof
```

Notice that the frame count divided by the sample rate is the duration. The decoder hands you the
samples at the file's own rate, and it has not resampled anything. The `ended: eof` line says the
decoder reached the end of the file, rather than stopping on a failure.

## Try it on another file

Run the tool again on an M4A file, or an Ogg file with Opus or Vorbis. You will see the same three
lines with a different codec and container.

You have decoded audio to Float32 PCM with `FFmpegStreamDecoder`. To play a URL while it downloads,
seek, or cancel from another thread, see [Integrating](integrating.md). For what each type does, see
[Reference](reference.md).
