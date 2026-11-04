// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LipDictation",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LipDictation", path: "Sources/LipDictation"),
        .testTarget(name: "LipDictationTests", dependencies: ["LipDictation"], path: "Tests"),
    ]
)
