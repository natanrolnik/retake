import ProjectDescription

// macOS renders on the host: no simulator, no XCTest, just an app that links the
// modules and writes PNGs. Unlike iOS, retake does not yet generate this host for
// you, so the runner target below is the one piece a macOS repository adds.
let project = Project(
    name: "SampleMac",
    targets: [
        .target(
            name: "MacDesignSystem",
            destinations: [.mac],
            product: .framework,
            bundleId: "dev.retake.samplemac.designsystem",
            deploymentTargets: .macOS("14.0"),
            sources: ["Sources/MacDesignSystem/**"]
        ),
        // An app rather than a command line tool on purpose: Xcode then embeds and
        // re-signs the SnapshotPreviews framework with a matching identity. A loose
        // ad-hoc signed binary is rejected by macOS library validation at launch.
        .target(
            name: "PreviewRunner",
            destinations: [.mac],
            product: .app,
            bundleId: "dev.retake.samplemac.previewrunner",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: ["LSUIElement": true]),
            sources: ["Sources/PreviewRunner/**"],
            dependencies: [
                .target(name: "MacDesignSystem"),
                .external(name: "RetakeRuntime"),
            ]
        ),
    ]
)
