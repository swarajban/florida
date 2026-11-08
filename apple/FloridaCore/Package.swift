// swift-tools-version: 6.0
import PackageDescription

// Dependency-free logic shared by every Florida target: models, quick-add parsing, the keyboard
// engine, and calendar layout math. No I/O, no GRDB; builds and tests on Linux.
let package = Package(
    name: "FloridaCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "FloridaCore", targets: ["FloridaCore"]),
    ],
    targets: [
        .target(name: "FloridaCore"),
        .testTarget(name: "FloridaCoreTests", dependencies: ["FloridaCore"]),
    ]
)
