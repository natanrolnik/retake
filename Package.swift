// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "flexview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flexview", targets: ["flexview"]),
        // Linked into the host repo's snapshot runner target (macOS executable or iOS XCTest bundle).
        .library(name: "FlexViewRuntime", targets: ["FlexViewRuntime"]),
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
        .testTarget(name: "FlexViewCoreTests", dependencies: ["FlexViewCore"]),
    ]
)
