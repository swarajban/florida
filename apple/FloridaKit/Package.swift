// swift-tools-version: 6.0
import PackageDescription

// Local store (GRDB/SQLite), sync client, and settings shared by the apps and the widgets.
// Re-exports FloridaCore, so `import FloridaKit` is enough for app code.
let package = Package(
    name: "FloridaKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "FloridaKit", targets: ["FloridaKit"]),
    ],
    dependencies: [
        .package(path: "../FloridaCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "FloridaKit",
            dependencies: [
                .product(name: "FloridaCore", package: "FloridaCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "FloridaKitTests",
            dependencies: ["FloridaKit"]
        ),
    ]
)
