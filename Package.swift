// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeadyEye",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BeadyEye",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
