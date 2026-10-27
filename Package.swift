// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Summonbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Summonbar", path: "Sources/Summonbar")
    ]
)
