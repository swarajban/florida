// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloridaWidgetLogic",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [.package(path: "FloridaKit")],
    targets: [
        .target(
            name: "FloridaShareLogic",
            dependencies: [.product(name: "FloridaKit", package: "FloridaKit")],
            path: "Share/Model"),
        .testTarget(
            name: "FloridaShareLogicTests",
            dependencies: ["FloridaShareLogic"],
            path: "ShareTests"),
        .target(
            name: "FloridaWidgetLogic",
            dependencies: [.product(name: "FloridaKit", package: "FloridaKit")],
            path: "Widgets",
            exclude: ["FloridaWidgets.swift", "Support/WidgetSupport.swift", "Tasks", "Today", "UpNext"],
            sources: [
                "Store/WidgetModels.swift", "Store/WidgetDatabaseReader.swift", "Store/WidgetStore.swift",
                "Store/WidgetTaskTimeline.swift", "Support/WidgetDateFormatting.swift",
            ]),
        .testTarget(
            name: "FloridaWidgetLogicTests",
            dependencies: ["FloridaWidgetLogic"],
            path: "WidgetsTests",
            exclude: ["TodayTests.swift"],
            sources: ["WidgetIntegrityTests.swift", "WidgetPrivacyTests.swift", "TasksTests.swift"]),
    ])
