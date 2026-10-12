// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAmp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacAmpCore"),
        .executableTarget(name: "MacAmp", dependencies: ["MacAmpCore"]),
        .testTarget(name: "MacAmpCoreTests", dependencies: ["MacAmpCore"]),
    ]
)
