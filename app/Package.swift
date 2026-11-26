// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Agent2",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device Kokoro voice (Apache 2.0). Models download on first use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["TTS"]),
    ],
    targets: [
        .executableTarget(
            name: "Agent2",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Agent2",
            // Swift 5 language mode: the app predates strict concurrency checking.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
