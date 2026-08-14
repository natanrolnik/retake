//
//  Review.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import RetakeCore
import Foundation

/// Renders the merge base and the working tree, then diffs and reports.
///
/// The base is rendered from a detached git worktree rather than by checking out the
/// base ref, so the working tree keeps whatever uncommitted work is in it. That is the
/// point of running this locally: reviewing changes that are not committed yet.
struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render before and after, diff them, and write a report. The whole loop."
    )

    @Option(name: .long, help: "Ref to compare against. The merge base with HEAD is used.")
    var base: String = "main"

    @Option(name: .long, help: "Repository to review.")
    var repo: String = FileManager.default.currentDirectoryPath

    @Option(name: .shortAndLong, help: "Directory for renders, the diff and the report.")
    var out: String

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Modules to render. Derived from the changed files when omitted."
    )
    var modules: [String] = []

    @Option(name: .long, help: "Simulator to render on, as 'name,OS'.")
    var simulator: String?

    @Option(name: .long, help: "iOS deployment target for the generated host project.")
    var deploymentTarget: String = "17.0"

    @Option(name: .long, help: "Appearance to force on both sides.")
    var appearance: Appearance = .light

    @Option(name: .long, help: "Changed-pixel percentage at or below which a preview counts as unchanged.")
    var tolerance: Double = 0.01

    @Option(name: .long, help: "Per-channel delta below which two pixels count as equal.")
    var pixelThreshold: Int = 0

    @Option(name: .long, help: "Where to write the HTML report. Defaults to <out>/report.html.")
    var html: String?

    @Flag(name: .long, help: "Skip rendering the base if its manifest is already there.")
    var reuseBase: Bool = false

    @Flag(
        name: .long,
        help: "Render head twice and exclude previews that do not reproduce, rather than reporting them as changes."
    )
    var verify: Bool = false

    @Option(name: .long, help: "Path to the retake checkout, if it cannot be inferred.")
    var runtimeSources: String?

    @Option(name: .long, help: "Path to the SnapshotPreviews checkout, if it cannot be inferred.")
    var snapshotPreviews: String?

    @Option(name: .long, help: "Tuist executable. Pass an absolute path to bypass a version manager shim.")
    var tuist: String = "tuist"

    @Option(name: .long, help: "Tuist binary cache profile for the generated host.")
    var cacheProfile: String?

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Extra environment for the render process, as KEY=VALUE."
    )
    var env: [String] = ["SWIFT_DEPENDENCIES_CONTEXT=preview"]

    @Option(
        name: [.customLong("hosts"), .customLong("host")],
        parsing: .upToNextOption,
        help: "App targets allowed to host the previews."
    )
    var hosts: [String] = []

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Glob patterns, relative to the repository, for files that cannot affect rendering. Without these a single unowned file widens the scope to everything."
    )
    var ignore: [String] = [".github/**", "*.md", "**/*.md", "docs/**", ".gitignore"]

    @Option(name: .long, help: "Seconds allowed for each render.")
    var timeout: Int = 1800

    @Flag(name: .long, help: "Wait for asynchronously loaded content before capturing.")
    var settle: Bool = false

    func run() async throws {
        // The Tuist project and the git repository are not always the same directory:
        // a repo can hold the project in a subdirectory. Git operations need the
        // repository root, Tuist needs the project directory.
        let projectDirectory = URL(fileURLWithPath: repo).standardizedFileURL
        let repoRoot = try git(["rev-parse", "--show-toplevel"], in: projectDirectory.path)
        let projectSubpath = projectDirectory.path == repoRoot
            ? ""
            : String(projectDirectory.path.dropFirst(repoRoot.count + 1))
        let outputDirectory = URL(fileURLWithPath: out)
        let baseSnapshots = outputDirectory.appendingPathComponent("base")
        let headSnapshots = outputDirectory.appendingPathComponent("head")
        let diffDirectory = outputDirectory.appendingPathComponent("diff")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let mergeBase = try git(["merge-base", base, "HEAD"], in: repoRoot)
        print("retake: comparing against \(base) at \(mergeBase.prefix(8))")

        // Working tree included on purpose: uncommitted changes are exactly what a local
        // review is for.
        let changedFiles = try git(["diff", "--name-only", mergeBase], in: repoRoot)
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !changedFiles.isEmpty else {
            print("retake: nothing changed since \(mergeBase.prefix(8)); nothing to review.")
            return
        }
        print("retake: \(changedFiles.count) changed file\(changedFiles.count == 1 ? "" : "s")")

        let headGraph = try graph(of: projectDirectory, label: "head")

        let renderedModules: [String]
        if modules.isEmpty {
            let scope = ScopeResolver.resolve(
                graph: try TuistGraphParser.parse(contentsOf: headGraph),
                changedFiles: changedFiles.map { URL(fileURLWithPath: repoRoot).appendingPathComponent($0).path },
                ignored: ignore.map(PathGlob.init),
                root: repoRoot
            )
            for warning in scope.warnings { print("retake: warning: \(warning)") }
            for reason in scope.reasons { print("retake: \(reason)") }
            renderedModules = scope.isEverything ? [] : scope.modules
        } else {
            renderedModules = modules
        }

        let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retake-base-\(mergeBase.prefix(8))")

        let needsBase = !reuseBase || !FileManager.default.fileExists(
            atPath: baseSnapshots.appendingPathComponent(Manifest.fileName).path
        )

        if needsBase {
            try? FileManager.default.removeItem(at: worktree)
            print("retake: checking out the base into a worktree")
            _ = try Shell.runChecked(
                "/usr/bin/env",
                ["git", "worktree", "add", "--detach", worktree.path, mergeBase],
                currentDirectory: URL(fileURLWithPath: repoRoot)
            )
        } else {
            print("retake: reusing the existing base render")
        }

        defer {
            if needsBase {
                _ = try? Shell.run(
                    "/usr/bin/env",
                    ["git", "worktree", "remove", worktree.path, "--force"],
                    currentDirectory: URL(fileURLWithPath: repoRoot)
                )
            }
        }

        if needsBase {
            // The same subdirectory, inside the worktree.
            let baseProject = projectSubpath.isEmpty
                ? worktree
                : worktree.appendingPathComponent(projectSubpath)

            // Only when the repository actually declares external dependencies: with no
            // Tuist/Package.swift there is nothing to resolve, and Tuist treats being
            // asked as an error.
            if FileManager.default.fileExists(
                atPath: baseProject.appendingPathComponent("Tuist/Package.swift").path
            ) {
                print("retake: resolving dependencies in the worktree")
                // Launched from the head project, which has the version manager
                // config, but targeting the worktree.
                try Tuist(command: tuist, workingDirectory: projectDirectory)
                    .run(["install"], at: baseProject)
            }
            let baseGraph = try graph(of: baseProject, label: "base")
            try await render(graph: baseGraph, modules: renderedModules, out: baseSnapshots, label: "base")
        }

        try await render(graph: headGraph, modules: renderedModules, out: headSnapshots, label: "head")

        // A second render of the same commit. Anything that differs between the two
        // cannot be compared against the base at all.
        var verifySnapshots: URL?
        if verify {
            let directory = outputDirectory.appendingPathComponent("head-verify")
            try await render(graph: headGraph, modules: renderedModules, out: directory, label: "head again")
            verifySnapshots = directory
        }

        var diffArguments = [
            "--base", baseSnapshots.path,
            "--head", headSnapshots.path,
            "--out", diffDirectory.path,
            "--tolerance", String(tolerance),
            "--pixel-threshold", String(pixelThreshold),
            "--html", html ?? outputDirectory.appendingPathComponent("report.html").path,
        ]
        if let verifySnapshots { diffArguments += ["--verify", verifySnapshots.path] }

        let diff = try Diff.parse(diffArguments)
        try await diff.run()
    }

    // MARK: - Steps

    private func render(graph: URL, modules: [String], out: URL, label: String) async throws {
        print("retake: rendering \(label)")
        var arguments = [
            "--platform", "ios",
            "--graph", graph.path,
            "--out", out.path,
            "--appearance", appearance.rawValue,
            "--deployment-target", deploymentTarget,
            "--timeout", String(timeout),
        ]
        if let simulator { arguments += ["--simulator", simulator] }
        if settle { arguments += ["--settle"] }
        arguments += ["--tuist", tuist]
        if let cacheProfile { arguments += ["--cache-profile", cacheProfile] }
        if !hosts.isEmpty { arguments += ["--hosts"] + hosts }
        if !env.isEmpty { arguments += ["--env"] + env }
        // The base renders from a worktree, which has no version manager config, so
        // Tuist is always launched from the project under review.
        arguments += ["--tuist-working-directory", URL(fileURLWithPath: repo).standardizedFileURL.path]
        if let runtimeSources { arguments += ["--runtime-sources", runtimeSources] }
        if let snapshotPreviews { arguments += ["--snapshot-previews", snapshotPreviews] }
        if !modules.isEmpty { arguments += ["--modules"] + modules }

        let render = try Render.parse(arguments)
        try await render.run()
    }

    private func graph(of root: URL, label: String) throws -> URL {
        let directory = URL(fileURLWithPath: out).appendingPathComponent("graph-\(label)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Launched from the project under review, which has the version manager config.
        try Tuist(command: tuist, workingDirectory: URL(fileURLWithPath: repo).standardizedFileURL).run(
            ["graph", "--format", "json", "--no-open", "--output-path", directory.path],
            at: root
        )
        return directory.appendingPathComponent("graph.json")
    }

    private func git(_ arguments: [String], in directory: String) throws -> String {
        try Shell.runChecked("/usr/bin/env", ["git"] + arguments, currentDirectory: URL(fileURLWithPath: directory))
            .standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
