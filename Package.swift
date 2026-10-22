// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TaskCore", targets: ["TaskCore"])],
    targets: [
        .target(name: "TaskCore"),
        .testTarget(name: "TaskCoreTests", dependencies: ["TaskCore"])
    ]
)
