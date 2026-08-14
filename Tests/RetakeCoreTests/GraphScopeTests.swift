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

    @Test("A file no target owns widens the scope to everything")
    func unownedFileWidens() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/DesignSystem/Button.swift", "/repo/Project.swift"]
        )

        #expect(scope.isEverything)
        #expect(scope.reasons.contains { $0.contains("Project.swift") })
        #expect(scope.targets.count == 3)
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

    @Test("Excluded buildable folder files widen the scope rather than being ignored")
    func excludedFileWidens() throws {
        let graph = try sampleGraph()
        let scope = ScopeResolver.resolve(
            graph: graph,
            changedFiles: ["/repo/Feature/Sources/Ignored.swift"]
        )

        #expect(scope.isEverything)
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
