// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Browser", path: "Sources/Browser")
    ]
)
