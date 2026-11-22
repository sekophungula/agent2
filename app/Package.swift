// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Agent2",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Agent2",
            path: "Sources/Agent2"
        )
    ]
)
