// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GitSync", path: "Sources/GitSync"),
    ]
)
