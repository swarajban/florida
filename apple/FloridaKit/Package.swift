// swift-tools-version: 6.0
import PackageDescription

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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "FloridaKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "FloridaKitTests",
            dependencies: ["FloridaKit"]
        ),
    ]
)
