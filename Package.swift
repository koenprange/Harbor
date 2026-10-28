// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Harbor", targets: ["HarborApp"]),
        .executable(name: "HarborCheck", targets: ["HarborCheck"])
    ],
    targets: [
        .target(name: "HarborCore"),
        .executableTarget(name: "HarborApp", dependencies: ["HarborCore"]),
        .executableTarget(name: "HarborCheck", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"])
    ]
)
