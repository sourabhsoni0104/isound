// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iSound",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "iSound", path: "Sources/iSound")
    ]
)
