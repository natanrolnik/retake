// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings

let packageSettings = PackageSettings(
    productTypes: ["RetakeRuntime": .framework]
)
#endif

let package = Package(
    name: "SampleMacDependencies",
    dependencies: [
        // The retake package at the root of this repository.
        .package(path: "../../..")
    ]
)
