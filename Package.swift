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
    targets: [
        .target(name: "SMKVMCore"),
        .executableTarget(name: "SMKVM", dependencies: ["SMKVMCore"]),
        .executableTarget(name: "smkvm-probe", dependencies: ["SMKVMCore"]),
        .testTarget(name: "SMKVMCoreTests", dependencies: ["SMKVMCore"]),
    ]
)
