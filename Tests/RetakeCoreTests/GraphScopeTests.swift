//
//  GraphScopeTests.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation
import Testing
@testable import RetakeCore

/// Mirrors `tuist graph --format json`, including the two fields that serialize as flat
/// alternating key/value arrays rather than JSON objects.
private let graphJSON = """
{
  "name": "Sample",
  "projects": [
    "/repo",
    {
      "path": "/repo",
      "targets": {
        "DesignSystem": {
          "name": "DesignSystem",
          "productName": "DesignSystem",
          "sources": [{"path": "/repo/DesignSystem/Button.swift"}],
          "resources": {"resources": [{"path": "/repo/DesignSystem/Colors.xcassets"}]},
          "buildableFolders": []
        },
        "Feature": {
          "name": "Feature",
          "productName": "FeatureKit",
          "sources": [],
          "resources": {"resources": []},
          "buildableFolders": [
            {
              "path": "/repo/Feature/Sources",
              "resolvedFiles": [{"path": "/repo/Feature/Sources/Screen.swift"}],
              "exceptions": {"exceptions": [{"excluded": ["/repo/Feature/Sources/Ignored.swift"]}]}
            }
          ]
        },
        "App": {
          "name": "App",
          "productName": "App",
          "sources": [{"path": "/repo/App/App.swift"}],
          "resources": {"resources": []},
          "buildableFolders": []
        }
      }
    }
  ],
  "dependencies": [
    {"target": {"name": "Feature", "path": "/repo", "status": "required"}},
    [{"target": {"name": "DesignSystem", "path": "/repo", "status": "required"}}],
    {"target": {"name": "App", "path": "/repo", "status": "required"}},
    [{"target": {"name": "Feature", "path": "/repo", "status": "required"}}],
    {"framework": {"path": "/somewhere/Prebuilt.framework"}},
    []
  ]
}
"""

private func sampleGraph() throws -> TargetGraph {
    try TuistGraphParser.parse(Data(graphJSON.utf8))
}

private func id(_ name: String) -> TargetGraph.TargetID {
    TargetGraph.TargetID(project: "/repo", name: name)
}

@Suite("Tuist graph parsing")
struct TuistGraphParserTests {
    @Test("Targets are read out of the alternating projects array")
    func parsesTargets() throws {
        let graph = try sampleGraph()

        #expect(graph.targets.count == 3)
        // productName, not target name, is what previews report as their module.
        #expect(graph.targets[id("Feature")]?.productName == "FeatureKit")
        #expect(graph.targets[id("DesignSystem")]?.resources == ["/repo/DesignSystem/Colors.xcassets"])
    }

    @Test("Dependencies are read out of the alternating key/value array")
    func parsesDependencies() throws {
        let graph = try sampleGraph()

        #expect(graph.dependencies[id("Feature")] == [id("DesignSystem")])
        #expect(graph.dependencies[id("App")] == [id("Feature")])
        // A non-target dependency owns no repo source file and is skipped.
        #expect(graph.dependencies.count == 2)
    }

    @Test("Buildable folders resolve to both current files and the folder root")
    func parsesBuildableFolders() throws {
        let graph = try sampleGraph()
        let feature = try #require(graph.targets[id("Feature")])

        #expect(feature.sources == ["/repo/Feature/Sources/Screen.swift"])
        #expect(feature.owns("/repo/Feature/Sources/Screen.swift"))
        // The folder claims files that do not exist yet, which is how a newly added
        // file still gets attributed to a target.
        #expect(feature.owns("/repo/Feature/Sources/Nested/BrandNew.swift"))
        #expect(!feature.owns("/repo/Feature/Sources/Ignored.swift"))
        #expect(!feature.owns("/repo/Elsewhere/Other.swift"))
    }

    @Test("A malformed graph fails loudly")
    func rejectsMalformedGraph() {
        #expect(throws: TuistGraphParser.Error.self) {
            try TuistGraphParser.parse(Data("[]".utf8))
        }
        #expect(throws: TuistGraphParser.Error.self) {
            try TuistGraphParser.parse(Data(#"{"projects": []}"#.utf8))
        }
    }
}

@Suite("Scope resolution")
struct ScopeResolverTests {
    @Test("A leaf change pulls in everything downstream of it")
    func reverseClosure() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/DesignSystem/Button.swift"]
        )

        #expect(!scope.isEverything)
        // App and Feature own none of the changed files, but both consume DesignSystem.
        #expect(scope.modules == ["App", "DesignSystem", "FeatureKit"])
    }

    @Test("A change with no downstream consumers stays narrow")
    func narrowScope() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(graph: graph, changedFiles: ["/repo/App/App.swift"])

        #expect(scope.modules == ["App"])
    }

    @Test("A file no target owns falls back to the project holding it")
    func unownedFileFallsBackToItsProject() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/DesignSystem/Button.swift", "/repo/Project.swift"]
        )

        // A manifest belongs to no target but decides how that project's targets build,
        // so the project bounds the blast radius. Widening to the whole repository is
        // what this avoids: on a large graph it means rendering hundreds of targets to
        // find out a manifest moved.
        #expect(!scope.isEverything)
        #expect(scope.reasons.contains { $0.contains("Project.swift") })
        #expect(scope.targets.count == 3)
    }

    @Test("A file outside every project still widens the scope to everything")
    func fileOutsideAnyProjectWidens() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/elsewhere/Shared.swift"]
        )

        // Nothing bounds what it could have changed, so the conservative answer is the
        // only honest one.
        #expect(scope.isEverything)
        #expect(scope.reasons.contains { $0.contains("no project contains") })
    }

    @Test("A manifest in one project does not drag in another")
    func manifestStaysInItsProject() throws {
        // The case this exists for: a new module added by a pull request, whose manifest
        // no target owns, must not put an unrelated app in scope.
        let graph = TargetGraph(
            targets: Dictionary(uniqueKeysWithValues: [
                TargetGraph.Target(
                    id: .init(project: "/repo", name: "App"),
                    productName: "App",
                    product: "app",
                    sources: ["/repo/App/Main.swift"],
                    resources: []
                ),
                TargetGraph.Target(
                    id: .init(project: "/repo/Features/New", name: "NewFeature"),
                    productName: "NewFeature",
                    product: "staticFramework",
                    sources: ["/repo/Features/New/Sources/View.swift"],
                    resources: []
                ),
            ].map { ($0.id, $0) }),
            dependencies: [:]
        )
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/Features/New/Project.swift"]
        )

        #expect(!scope.isEverything)
        #expect(scope.modules == ["NewFeature"])
    }

    @Test("A glob keeps an unowned file from widening the scope")
    func ignoredPaths() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/DesignSystem/Button.swift", "/repo/README.md"],
            ignored: [PathGlob("*.md")],
            root: "/repo"
        )

        #expect(!scope.isEverything)
        #expect(scope.modules == ["App", "DesignSystem", "FeatureKit"])
    }

    @Test("Resources count as owned files")
    func resourceOwnership() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/DesignSystem/Colors.xcassets"]
        )

        #expect(!scope.isEverything)
        #expect(scope.modules.contains("DesignSystem"))
    }

    @Test("Excluded buildable folder files fall back to their project, not to nothing")
    func excludedFileFallsBackToItsProject() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/Feature/Sources/Ignored.swift"]
        )

        // Excluded from its target's buildable folder, so no target owns it, but it is
        // still inside a project and cannot be silently dropped.
        #expect(!scope.isEverything)
        #expect(!scope.modules.isEmpty)
    }
}


@Suite("Path globs")
struct PathGlobTests {
    @Test("A directory pattern matches nested files")
    func nestedFiles() {
        // The case that motivated this: adding the workflow that runs retake must not
        // make retake render the entire repository.
        let glob = PathGlob(".github/**")

        #expect(glob.matches(".github/workflows/preview-snapshots.yml"))
        #expect(glob.matches("/repo/.github/workflows/ci.yml", relativeTo: "/repo"))
        #expect(!glob.matches("Sources/App/App.swift"))
    }

    @Test("A single star also crosses separators, so common patterns do not silently miss")
    func singleStarCrossesSeparators() {
        #expect(PathGlob(".github/*").matches(".github/workflows/ci.yml"))
    }

    @Test("Extension patterns match at any depth when written that way")
    func extensionPatterns() {
        #expect(PathGlob("*.md").matches("README.md"))
        #expect(PathGlob("**/*.md").matches("docs/guide/setup.md"))
        #expect(!PathGlob("*.md").matches("Sources/Markdown.swift"))
    }

    @Test("Paths are matched relative to the root, and anything outside it is left absolute")
    func relativeToRoot() {
        #expect(PathGlob("Sources/**").matches("/repo/Sources/App.swift", relativeTo: "/repo"))
        // Outside the root there is nothing to strip, so the absolute path is matched as
        // given. A permissive pattern still matches it, since * crosses separators.
        #expect(!PathGlob("Sources/**").matches("/elsewhere/Sources/App.swift", relativeTo: "/repo"))
        #expect(PathGlob("*.md").matches("/elsewhere/README.md", relativeTo: "/repo"))
    }
}

@Suite("File filtering")
struct FileFilterTests {
    /// The runtime matches on `#fileID`, which is "Module/Basename.swift". Turning a path
    /// into one needs the graph, because the module is whichever target owns the file.
    @Test("A path becomes the file id the runtime matches on")
    func pathToFileID() throws {
        let graph = try sampleGraph()
        let owner = try #require(graph.owner(ofFile: "/repo/Feature/Sources/Screen.swift"))

        #expect(graph.targets[owner]?.productName == "FeatureKit")
        // Deliberately the product name, not the target name: that is what a preview
        // reports as its module.
        #expect(owner.name == "Feature")
    }

    @Test("A file no target owns cannot be turned into a file id")
    func unownedFile() throws {
        let graph = try sampleGraph()

        #expect(graph.owner(ofFile: "/repo/Scripts/tool.swift") == nil)
    }
}

@Suite("Renderable targets")
struct RenderableTargetTests {
    private func graph(_ targets: [(String, String, Bool)]) -> TargetGraph {
        TargetGraph(
            targets: Dictionary(uniqueKeysWithValues: targets.map { name, product, external in
                let id = TargetGraph.TargetID(project: "/repo", name: name)
                return (id, TargetGraph.Target(
                    id: id,
                    productName: name,
                    product: product,
                    sources: [],
                    resources: [],
                    isExternal: external
                ))
            }),
            dependencies: [:]
        )
    }

    @Test("Test bundles are recognised however the graph spells them")
    func testBundleSpelling() {
        // Tuist writes "unit_tests"; matching only the manifest spelling meant test
        // bundles were treated as renderable and linked into hosts.
        let sample = graph([("AppTests", "unit_tests", false), ("UITests", "uiTests", false)])

        #expect(sample.isTestBundle(TargetGraph.TargetID(project: "/repo", name: "AppTests")))
        #expect(sample.isTestBundle(TargetGraph.TargetID(project: "/repo", name: "UITests")))
    }

    @Test("Targets for other platforms are not rendered")
    func otherPlatformsExcluded() {
        // A watch or TV app has nothing to contribute to an iOS render, and pulling one
        // in makes the build fail on a machine with no such simulator.
        let sample = TargetGraph(
            targets: Dictionary(uniqueKeysWithValues: [
                ("App", ["iPhone", "iPad"]),
                ("Watch", ["appleWatch"]),
                ("TV", ["appleTv"]),
                ("Shared", ["iPhone", "appleWatch", "appleTv"]),
            ].map { name, destinations in
                let id = TargetGraph.TargetID(project: "/repo", name: name)
                return (id, TargetGraph.Target(
                    id: id,
                    productName: name,
                    product: name == "App" ? "app" : "staticFramework",
                    sources: [],
                    resources: [],
                    destinations: destinations
                ))
            }),
            dependencies: [:]
        )

        #expect(sample.renderableTargets(for: .ios).map(\.id.name) == ["App", "Shared"])
    }

    @Test("A target that declares no destinations is assumed to fit")
    func noDestinations() {
        let id = TargetGraph.TargetID(project: "/repo", name: "Thing")
        let target = TargetGraph.Target(id: id, productName: "Thing", sources: [], resources: [])

        #expect(target.supports(.ios))
        #expect(target.supports(.macos))
    }

    @Test("Dependencies are not rendered, however many of them there are")
    func externalsExcluded() {
        let sample = graph([
            ("App", "app", false),
            ("Theme", "staticFramework", false),
            ("AppTests", "unit_tests", false),
            ("SwiftSyntax", "staticFramework", true),
            ("GRDB", "framework", true),
        ])

        #expect(sample.renderableTargets().map(\.id.name) == ["App", "Theme"])
    }

    @Test("A Tuist generated dependency project is external")
    func externalProjectPaths() {
        #expect(TuistGraphParser.isExternalProject("/repo/Tuist/.build/tuist-derived/Projects/GRDB"))
        #expect(!TuistGraphParser.isExternalProject("/repo/Modules/Theme"))
    }
}
