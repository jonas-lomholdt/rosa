// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Rosa",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Rosa", path: "Sources/Rosa")
    ]
)
