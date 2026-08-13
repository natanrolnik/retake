// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "flexview",
    // iOS 17 / macOS 14 is the floor for the #Preview macro, whose runtime metadata is
    // the only source of a per-preview file path.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "flexview", targets: ["flexview"]),
        // Linked into the host repo's macOS runner app.
        .library(name: "FlexViewRuntime", targets: ["FlexViewRuntime"]),
        // Linked into the host repo's iOS XCTest target. Split out so XCTest never
        // reaches an app target.
        .library(name: "FlexViewTestRuntime", targets: ["FlexViewTestRuntime"]),
        .library(name: "FlexViewCore", targets: ["FlexViewCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // Pinned to a main revision: the newest tag (v0.9.4, Aug 2024) predates the
        // runtime module filtering that flexview scope depends on.
        .package(
            url: "https://github.com/EmergeTools/SnapshotPreviews-iOS.git",
            revision: "856a1c1585e31d4113c019050d6d0712cf6ddadc"
        ),
    ],
    targets: [
        .executableTarget(
            name: "flexview",
            dependencies: [
                "FlexViewCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "FlexViewCore"),
        .target(
            name: "FlexViewRuntime",
            dependencies: [
                "FlexViewCore",
                .product(name: "SnapshotPreviewsCore", package: "SnapshotPreviews-iOS"),
            ]
        ),
        .target(
            name: "FlexViewTestRuntime",
            dependencies: [
                "FlexViewCore",
                "FlexViewRuntime",
                .product(name: "SnapshotPreviewsCore", package: "SnapshotPreviews-iOS"),
            ]
        ),
        .testTarget(name: "FlexViewCoreTests", dependencies: ["FlexViewCore"]),
    ]
)
