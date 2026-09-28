// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibhorsNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VibhorsNotch",
            path: "Sources/VibhorsNotch"
        )
    ]
)
