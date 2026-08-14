//
//  Snapshot.swift
//  retake
//
//  Created by Natan Rolnik on 14-08-2026.
//

import ArgumentParser
import RetakeCore
import Foundation

/// Renders everything and reports it, with nothing to compare against.
///
/// The rest of the tool answers "what changed"; this answers "what is there". Useful for
/// seeing a design system in one page, for checking a module renders at all before
/// wiring up CI, and for handing someone a catalogue of the app's screens.
struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render every preview in the current state and write a report. No comparison."
    )

    @Option(name: .long, help: "Repository to snapshot.")
    var repo: String = FileManager.default.currentDirectoryPath

    @Option(name: .shortAndLong, help: "Directory for the renders and the report.")
    var out: String

    @Option(name: .long, parsing: .upToNextOption, help: "Modules to render. Everything when omitted.")
    var modules: [String] = []

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Render only the previews declared in these source files. The fastest way to see what one file draws."
    )
    var files: [String] = []

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Local Swift package directories to render, for a repository that does not use Tuist."
    )
    var packages: [String] = []

    @Option(
        name: [.customLong("hosts"), .customLong("host")],
        parsing: .upToNextOption,
        help: "App targets allowed to host the previews."
    )
    var hosts: [String] = []

    @Option(name: .long, help: "Simulator to render on, as 'name,OS'.")
    var simulator: String?

    @Option(name: .long, help: "iOS deployment target for the generated host project.")
    var deploymentTarget: String = "17.0"

    @Option(name: .long, help: "Appearance to force.")
    var appearance: Appearance = .light

    @Flag(name: .long, help: "Wait for asynchronously loaded content before capturing.")
    var settle: Bool = false

    @Option(name: .long, help: "Where to write the HTML report. Defaults to <out>/report.html.")
    var html: String?

    @Option(name: .long, help: "Title shown at the top of the report.")
    var title: String?

    @Option(name: .long, help: "Tuist executable.")
    var tuist: String = "tuist"

    @Option(name: .long, help: "Tuist binary cache profile for the generated host.")
    var cacheProfile: String?

    @Flag(name: .long, help: "Warm the Tuist cache for the targets about to be rendered.")
    var warmCache: Bool = false

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Pipe xcodebuild through xcbeautify when available. It drops the render's own output, which is where a failure explains itself."
    )
    var pretty: Bool = true

    @Option(name: .long, help: "Path to the retake checkout, if it cannot be inferred.")
    var runtimeSources: String?

    @Option(name: .long, help: "Seconds allowed for the render.")
    var timeout: Int = 1800

    func run() async throws {
        let projectDirectory = URL(fileURLWithPath: repo).standardizedFileURL
        let outputDirectory = URL(fileURLWithPath: out)
        let snapshots = outputDirectory.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var arguments = [
            "--platform", "ios",
            "--out", snapshots.path,
            "--appearance", appearance.rawValue,
            "--deployment-target", deploymentTarget,
            "--timeout", String(timeout),
            "--tuist", tuist,
            "--tuist-working-directory", projectDirectory.path,
        ]
        if packages.isEmpty {
            // A Tuist repository: read its graph and let host selection work from it.
            let graphDirectory = outputDirectory.appendingPathComponent("graph")
            try FileManager.default.createDirectory(at: graphDirectory, withIntermediateDirectories: true)
            try Tuist(command: tuist, workingDirectory: projectDirectory).run(
                ["graph", "--format", "json", "--no-open", "--output-path", graphDirectory.path],
                at: projectDirectory
            )
            arguments += ["--graph", graphDirectory.appendingPathComponent("graph.json").path]
        } else {
            arguments += ["--packages"] + packages.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        if let simulator { arguments += ["--simulator", simulator] }
        if let cacheProfile { arguments += ["--cache-profile", cacheProfile] }
        if warmCache { arguments += ["--warm-cache"] }
        if !pretty { arguments += ["--no-pretty"] }
        if let runtimeSources { arguments += ["--runtime-sources", runtimeSources] }
        if settle { arguments += ["--settle"] }
        if !modules.isEmpty { arguments += ["--modules"] + modules }
        if !files.isEmpty {
            arguments += ["--files"] + files.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        if !hosts.isEmpty { arguments += ["--hosts"] + hosts }

        let render = try Render.parse(arguments)
        try await render.run()

        let manifest = try Manifest.read(from: snapshots)
        // Every preview is "added": there is no before, which is exactly what the added
        // bucket already means, so the report needs no special case.
        let report = DiffReport(
            tolerance: 0,
            headDirectory: snapshots.path,
            previews: manifest.entries.map { entry in
                PreviewDiff(
                    previewID: entry.previewID,
                    module: entry.module,
                    sourceFile: entry.sourceFile,
                    displayName: entry.displayName,
                    change: .added,
                    headPNG: entry.pngPath
                )
            },
            failures: manifest.failures
        )
        try report.write(to: outputDirectory.appendingPathComponent(DiffReport.fileName))

        let htmlURL = URL(fileURLWithPath: html ?? outputDirectory.appendingPathComponent("report.html").path)
        let rendered = HTMLReport.render(
            report: report,
            diffDirectory: outputDirectory,
            options: HTMLReport.Options(
                title: title ?? "\(projectDirectory.lastPathComponent) previews",
                inlineImages: true,
                includeUnchanged: true,
                style: .catalogue
            )
        )
        try Data(rendered.utf8).write(to: htmlURL)

        print("retake: \(manifest.entries.count) previews in \(Set(manifest.entries.map(\.module)).count) modules")
        print("retake: wrote \(htmlURL.path)")
    }
}
