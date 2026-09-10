// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "adi205-captions",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CaptionCore", path: "Sources/CaptionCore"),
        .executableTarget(name: "gate", path: "Sources/gate"),
        .executableTarget(name: "setinput", path: "Sources/setinput"),
        .executableTarget(name: "bench", dependencies: ["CaptionCore"], path: "Sources/bench"),
        .executableTarget(name: "captiond", dependencies: ["CaptionCore"], path: "Sources/captiond"),
    ]
)
