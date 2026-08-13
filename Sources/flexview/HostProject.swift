//
//  HostProject.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import FlexViewCore
import Foundation

/// Writes a throwaway Tuist project that can render a repository's previews without the
/// repository knowing it exists.
///
/// The project sits in a scratch directory inside the Tuist root, so it inherits the
/// repo's config and ProjectDescriptionHelpers, and links existing targets by path. None
/// of the repo's own manifests are touched, and the directory is removed afterwards.
struct HostProject {
    var scratchDirectory: URL
    var host: PreviewHost
    var sources: RuntimeSources
    var deploymentTarget: String

    static let projectName = "FlexViewHost"
    /// Tuist emits one scheme named after the project, not one per target.
    static var schemeName: String { projectName }

    func write() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: scratchDirectory)
        try fileManager.createDirectory(
            at: scratchDirectory.appendingPathComponent("Tests"),
            withIntermediateDirectories: true
        )

        if case .synthesized = host {
            try fileManager.createDirectory(
                at: scratchDirectory.appendingPathComponent("Sources"),
                withIntermediateDirectories: true
            )
            try write(Self.hostAppSource, to: "Sources/FlexViewHostApp.swift")
        }
        try write(Self.testSource, to: "Tests/GeneratedSnapshots.swift")
        try write(manifest(), to: "Project.swift")
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        try Data(contents.utf8).write(to: scratchDirectory.appendingPathComponent(relativePath))
    }

    // MARK: - Manifest

    private func manifest() -> String {
        let flexviewSources = sources.flexview.path
        let previewsSources = sources.snapshotPreviews.path

        var targets: [String] = [
            runtimeTarget(
                name: "SnapshotSharedModels",
                sources: ["\(previewsSources)/Sources/SnapshotSharedModels/**"],
                dependencies: []
            ),
            runtimeTarget(
                name: "SnapshotPreviewsCore",
                sources: ["\(previewsSources)/Sources/SnapshotPreviewsCore/**"],
                dependencies: [
                    #".target(name: "SnapshotSharedModels")"#,
                    #".xcframework(path: "\#(previewsSources)/PreviewsSupport/PreviewsSupport.xcframework")"#,
                ]
            ),
            runtimeTarget(
                name: "FlexViewCore",
                sources: ["\(flexviewSources)/Sources/FlexViewCore/**"],
                dependencies: []
            ),
            runtimeTarget(
                name: "FlexViewRuntime",
                sources: ["\(flexviewSources)/Sources/FlexViewRuntime/**"],
                dependencies: [
                    #".target(name: "FlexViewCore")"#,
                    #".target(name: "SnapshotPreviewsCore")"#,
                ]
            ),
            runtimeTarget(
                name: "FlexViewTestRuntime",
                sources: ["\(flexviewSources)/Sources/FlexViewTestRuntime/**"],
                dependencies: [
                    #".target(name: "FlexViewCore")"#,
                    #".target(name: "FlexViewRuntime")"#,
                    #".target(name: "SnapshotPreviewsCore")"#,
                ],
                // This target imports XCTest, which a framework target cannot resolve
                // without the testing search paths.
                settings: [#""ENABLE_TESTING_SEARCH_PATHS": "YES""#]
            ),
        ]

        let hostTargetName: String
        var testDependencies: [String] = [#".target(name: "FlexViewTestRuntime")"#]

        switch host {
        case .synthesized(let linked):
            hostTargetName = "FlexViewHostApp"
            let links = linked.map { projectDependency($0) }
            targets.append("""
                    .target(
                        name: "FlexViewHostApp",
                        destinations: [.iPhone],
                        product: .app,
                        bundleId: "dev.flexview.host.app",
                        deploymentTargets: .iOS("\(deploymentTarget)"),
                        infoPlist: .default,
                        sources: ["Sources/**"],
                        dependencies: [
                \(links.map { "            \($0)," }.joined(separator: "\n"))
                        ],
                        // The host references nothing from the frameworks it links, so
                        // with static products the linker drops every object file and no
                        // preview metadata survives to be scanned. -all_load keeps them.
                        settings: .settings(base: ["OTHER_LDFLAGS": "$(inherited) -all_load"])
                    ),
                """)
            testDependencies.append(#".target(name: "FlexViewHostApp")"#)

        case .existingApp(let app):
            hostTargetName = app.name
            testDependencies.append(projectDependency(app))
        }

        targets.append("""
                .target(
                    name: "FlexViewHostTests",
                    destinations: [.iPhone],
                    product: .unitTests,
                    bundleId: "dev.flexview.host.tests",
                    deploymentTargets: .iOS("\(deploymentTarget)"),
                    infoPlist: .default,
                    sources: ["Tests/**"],
                    dependencies: [
            \(testDependencies.map { "            \($0)," }.joined(separator: "\n"))
                    ]
                ),
            """)

        return """
        // Generated by flexview. Throwaway: this directory is deleted after rendering.
        //
        // The runtime is compiled from source rather than added as a Swift package, so
        // the repository's own dependency graph is left untouched. Previews are hosted
        // by \(hostTargetName).
        import ProjectDescription

        let project = Project(
            name: "\(Self.projectName)",
            targets: [
        \(targets.joined(separator: "\n"))
            ],
            // Declared rather than inferred: Tuist's automatic scheme names depend on
            // what the project contains, and flexview has to know the name up front.
            schemes: [
                .scheme(
                    name: "\(Self.schemeName)",
                    shared: true,
                    buildAction: .buildAction(targets: ["FlexViewHostTests"]),
                    testAction: .targets(["FlexViewHostTests"])
                ),
            ]
        )

        """
    }

    private func runtimeTarget(
        name: String,
        sources: [String],
        dependencies: [String],
        settings: [String] = []
    ) -> String {
        let sourceList = sources.map { #""\#($0)""# }.joined(separator: ", ")
        let dependencyList = dependencies.isEmpty
            ? "[]"
            : "[\n\(dependencies.map { "                \($0)," }.joined(separator: "\n"))\n            ]"
        let settingsLine = settings.isEmpty
            ? ""
            : ",\n            settings: .settings(base: [\(settings.joined(separator: ", "))])"
        return """
                .target(
                    name: "\(name)",
                    destinations: [.iPhone],
                    product: .framework,
                    bundleId: "dev.flexview.runtime.\(name.lowercased())",
                    deploymentTargets: .iOS("\(deploymentTarget)"),
                    infoPlist: .default,
                    sources: [\(sourceList)],
                    dependencies: \(dependencyList)\(settingsLine)
                ),
            """
    }

    /// Links a target that lives in one of the repository's own projects.
    private func projectDependency(_ target: TargetGraph.TargetID) -> String {
        let path = Self.relativePath(from: scratchDirectory.path, to: target.project)
        return #".project(target: "\#(target.name)", path: "\#(path)")"#
    }

    /// Tuist resolves manifest paths relative to the manifest's own directory.
    static func relativePath(from base: String, to target: String) -> String {
        let baseComponents = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: target).standardizedFileURL.pathComponents

        var shared = 0
        while shared < min(baseComponents.count, targetComponents.count),
              baseComponents[shared] == targetComponents[shared] {
            shared += 1
        }

        let up = Array(repeating: "..", count: baseComponents.count - shared)
        let down = targetComponents[shared...]
        let path = (up + down).joined(separator: "/")
        return path.isEmpty ? "." : path
    }

    // MARK: - Generated sources

    private static let hostAppSource = """
    // Generated by flexview. An empty shell whose only job is to link the frameworks
    // under test, so their previews are reachable through runtime metadata.
    import SwiftUI

    @main
    struct FlexViewHostApp: App {
        var body: some Scene {
            WindowGroup { Color.clear }
        }
    }

    """

    private static let testSource = """
    // Generated by flexview.
    import FlexViewTestRuntime

    final class GeneratedPreviewSnapshots: FlexViewSnapshotTests {}

    """
}
