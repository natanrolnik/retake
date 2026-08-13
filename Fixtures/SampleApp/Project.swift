import ProjectDescription

let deploymentTargets: DeploymentTargets = .multiplatform(iOS: "17.0", macOS: "14.0")

let project = Project(
    name: "SampleApp",
    targets: [
        .target(
            name: "DesignSystem",
            destinations: [.iPhone, .mac],
            product: .framework,
            bundleId: "dev.flexview.sampleapp.designsystem",
            deploymentTargets: deploymentTargets,
            sources: ["Sources/DesignSystem/**"]
        ),
        .target(
            name: "Feature",
            destinations: [.iPhone, .mac],
            product: .framework,
            bundleId: "dev.flexview.sampleapp.feature",
            deploymentTargets: deploymentTargets,
            sources: ["Sources/Feature/**"],
            dependencies: [.target(name: "DesignSystem")]
        ),
        .target(
            name: "App",
            destinations: [.iPhone],
            product: .app,
            bundleId: "dev.flexview.sampleapp.app",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            sources: ["Sources/App/**"],
            dependencies: [.target(name: "Feature")]
        ),
    ]
)
