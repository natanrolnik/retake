//
//  Review.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import FlexViewCore
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

    @Option(name: .long, help: "Skip rendering the base if its manifest is already there.")
    var reuseBase: Bool = false

    @Option(name: .long, help: "Seconds allowed for each render.")
    var timeout: Int = 1800

    @Flag(name: .long, help: "Wait for asynchronously loaded content before capturing.")
    var settle: Bool = false

    func run() async throws {
        let repoRoot = try git(["rev-parse", "--show-toplevel"], in: repo)
        let outputDirectory = URL(fileURLWithPath: out)
        let baseSnapshots = outputDirectory.appendingPathComponent("base")
        let headSnapshots = outputDirectory.appendingPathComponent("head")
        let diffDirectory = outputDirectory.appendingPathComponent("diff")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let mergeBase = try git(["merge-base", base, "HEAD"], in: repoRoot)
        print("flexview: comparing against \(base) at \(mergeBase.prefix(8))")

        // Working tree included on purpose: uncommitted changes are exactly what a local
        // review is for.
        let changedFiles = try git(["diff", "--name-only", mergeBase], in: repoRoot)
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !changedFiles.isEmpty else {
            print("flexview: nothing changed since \(mergeBase.prefix(8)); nothing to review.")
            return
        }
        print("flexview: \(changedFiles.count) changed file\(changedFiles.count == 1 ? "" : "s")")

        let headGraph = try graph(of: repoRoot, label: "head")

        let renderedModules: [String]
        if modules.isEmpty {
            let scope = ScopeResolver.resolve(
                graph: try TuistGraphParser.parse(contentsOf: headGraph),
                changedFiles: changedFiles.map { URL(fileURLWithPath: repoRoot).appendingPathComponent($0).path }
            )
            for warning in scope.warnings { print("flexview: warning: \(warning)") }
            for reason in scope.reasons { print("flexview: \(reason)") }
            renderedModules = scope.isEverything ? [] : scope.modules
        } else {
            renderedModules = modules
        }

        let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flexview-base-\(mergeBase.prefix(8))")

        let needsBase = !reuseBase || !FileManager.default.fileExists(
            atPath: baseSnapshots.appendingPathComponent(Manifest.fileName).path
        )

        if needsBase {
            try? FileManager.default.removeItem(at: worktree)
            print("flexview: checking out the base into a worktree")
            _ = try Shell.runChecked(
                "/usr/bin/env",
                ["git", "worktree", "add", "--detach", worktree.path, mergeBase],
                currentDirectory: URL(fileURLWithPath: repoRoot)
            )
        } else {
            print("flexview: reusing the existing base render")
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
            print("flexview: resolving dependencies in the worktree")
            _ = try Shell.runChecked(
                "/usr/bin/env",
                ["tuist", "install"],
                currentDirectory: worktree
            )
            let baseGraph = try graph(of: worktree.path, label: "base")
            try await render(graph: baseGraph, modules: renderedModules, out: baseSnapshots, label: "base")
        }

        try await render(graph: headGraph, modules: renderedModules, out: headSnapshots, label: "head")

        var diff = try Diff.parse([
            "--base", baseSnapshots.path,
            "--head", headSnapshots.path,
            "--out", diffDirectory.path,
            "--tolerance", String(tolerance),
            "--pixel-threshold", String(pixelThreshold),
            "--html", html ?? outputDirectory.appendingPathComponent("report.html").path,
        ])
        try await diff.run()
    }

    // MARK: - Steps

    private func render(graph: URL, modules: [String], out: URL, label: String) async throws {
        print("flexview: rendering \(label)")
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
        if !modules.isEmpty { arguments += ["--modules"] + modules }

        var render = try Render.parse(arguments)
        try await render.run()
    }

    private func graph(of root: String, label: String) throws -> URL {
        let directory = URL(fileURLWithPath: out).appendingPathComponent("graph-\(label)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try Shell.runChecked(
            "/usr/bin/env",
            ["tuist", "graph", "--format", "json", "--no-open", "--output-path", directory.path],
            currentDirectory: URL(fileURLWithPath: root)
        )
        return directory.appendingPathComponent("graph.json")
    }

    private func git(_ arguments: [String], in directory: String) throws -> String {
        try Shell.runChecked("/usr/bin/env", ["git"] + arguments, currentDirectory: URL(fileURLWithPath: directory))
            .standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
