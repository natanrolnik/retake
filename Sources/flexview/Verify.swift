//
//  Verify.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import FlexViewCore
import Foundation

/// Renders the same commit repeatedly and reports previews whose pixels move.
///
/// The whole tool rests on an assumption: that a preview renders identically given
/// identical input. Where that fails, a diff reports changes nobody made, and no amount
/// of tolerance tuning fixes a preview that renders two genuinely different pictures.
/// This is how you find those before trusting a report.
struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the same commit several times and report previews that are not reproducible."
    )

    @Option(name: .long, help: "Tuist graph JSON.")
    var graph: String

    @Option(name: .long, parsing: .upToNextOption, help: "Modules to render.")
    var modules: [String] = []

    @Option(name: .long, help: "How many times to render.")
    var runs: Int = 3

    @Option(name: .long, help: "Simulator to render on, as 'name,OS'.")
    var simulator: String?

    @Option(name: .long, help: "iOS deployment target for the generated host project.")
    var deploymentTarget: String = "17.0"

    @Option(name: .long, help: "Appearance to force.")
    var appearance: Appearance = .light

    @Option(name: .shortAndLong, help: "Directory for the renders.")
    var out: String

    @Flag(name: .long, help: "Wait for asynchronously loaded content before capturing.")
    var settle: Bool = false

    func validate() throws {
        guard runs >= 2 else {
            throw ValidationError("--runs must be at least 2; there is nothing to compare otherwise.")
        }
    }

    func run() async throws {
        let outputDirectory = URL(fileURLWithPath: out)
        var hashesByPreview: [PreviewID: [String]] = [:]
        var modulesByPreview: [PreviewID: String] = [:]

        for run in 1...runs {
            let runDirectory = outputDirectory.appendingPathComponent("run-\(run)")
            print("flexview: run \(run) of \(runs)")

            var arguments = [
                "--platform", "ios",
                "--graph", graph,
                "--out", runDirectory.path,
                "--appearance", appearance.rawValue,
                "--deployment-target", deploymentTarget,
            ]
            if let simulator { arguments += ["--simulator", simulator] }
            if settle { arguments += ["--settle"] }
            if !modules.isEmpty { arguments += ["--modules"] + modules }

            var render = try Render.parse(arguments)
            try await render.run()

            for entry in try Manifest.read(from: runDirectory).entries {
                hashesByPreview[entry.previewID, default: []].append(entry.sha256)
                modulesByPreview[entry.previewID] = entry.module
            }
        }

        let unstable = hashesByPreview
            .filter { Set($0.value).count > 1 || $0.value.count != runs }
            .keys
            .sorted()

        print("")
        print("flexview: \(hashesByPreview.count - unstable.count) of \(hashesByPreview.count) previews reproducible over \(runs) runs")

        guard !unstable.isEmpty else {
            print("flexview: rendering is reproducible; diffs from this repository can be trusted.")
            return
        }

        print("flexview: \(unstable.count) preview\(unstable.count == 1 ? "" : "s") did not render identically:")
        for id in unstable {
            let distinct = Set(hashesByPreview[id] ?? []).count
            let seen = hashesByPreview[id]?.count ?? 0
            let detail = seen != runs
                ? "rendered in only \(seen) of \(runs) runs"
                : "\(distinct) different images across \(runs) runs"
            print("  \(id) — \(detail)")
        }
        print("")
        print("""
        flexview: these will show up as changes nobody made. Exclude them with \
        --modules, or make them deterministic: content that arrives asynchronously \
        (RealityKit scenes, .task loads, animations) is the usual cause.
        """)
        throw ExitCode(1)
    }
}
