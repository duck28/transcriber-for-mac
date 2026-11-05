// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("14.4")],
    dependencies: [
        // Whisper speech recognition that runs on this Mac (Core ML), used for dialects such as Swiss German.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/Transcriber"
        )
    ]
)
