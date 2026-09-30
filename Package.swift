// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "smkvm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SMKVM", targets: ["SMKVM"]),
        .library(name: "SMKVMCore", targets: ["SMKVMCore"]),
    ],
    targets: [
        .target(name: "SMKVMCore"),
        .executableTarget(name: "SMKVM", dependencies: ["SMKVMCore"]),
        .testTarget(name: "SMKVMCoreTests", dependencies: ["SMKVMCore"]),
    ]
)
