// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "smkvm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SMKVM", targets: ["SMKVM"]),
        .executable(name: "smkvm-probe", targets: ["smkvm-probe"]),
        .library(name: "SMKVMCore", targets: ["SMKVMCore"]),
    ],
    dependencies: [
        // Packaged Google libwebrtc (binary xcframework) for the JetKVM console.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "154.0.0"),
    ],
    targets: [
        .target(name: "SMKVMCore", dependencies: [.product(name: "WebRTC", package: "WebRTC")]),
        .executableTarget(name: "SMKVM", dependencies: ["SMKVMCore"]),
        .executableTarget(name: "smkvm-probe", dependencies: ["SMKVMCore"]),
        .testTarget(name: "SMKVMCoreTests", dependencies: ["SMKVMCore"]),
    ]
)
