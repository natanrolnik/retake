//
//  Render.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import FlexViewCore
import Foundation

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render every preview reachable from a runner target to PNGs plus a manifest."
    )

    @Option(
        name: .long,
        help: "Path to a prebuilt runner executable. Mutually exclusive with --scheme."
    )
    var runner: String?

    @Option(name: .long, help: "Xcode scheme of the runner target, built before rendering.")
    var scheme: String?

    @Option(name: .long, help: "Path to the .xcworkspace containing --scheme.")
    var workspace: String?

    @Option(name: .long, help: "Path to the .xcodeproj containing --scheme.")
    var project: String?

    @Option(name: .long, help: "Build configuration used with --scheme.")
    var configuration: String = "Debug"

    @Option(name: .long, help: "DerivedData path used with --scheme.")
    var derivedData: String?

    @Option(name: .long, help: "Platform to render on.")
    var platform: RenderPlatform = .macos

    @Option(name: .long, help: "Appearance to force. Never inherited from the host.")
    var appearance: Appearance = .light

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Restrict rendering to these modules. Renders everything when omitted."
    )
    var modules: [String] = []

    @Option(name: .shortAndLong, help: "Directory for the PNGs and manifest.json.")
    var out: String

    @Option(name: .long, help: "Seconds to wait for the runner before giving up.")
    var timeout: Int = 600

    @Option(
        name: .long,
        help: "Simulator to render on, as 'name,OS' (iOS only), e.g. 'iPhone 16,18.2'."
    )
    var simulator: String?

    @Option(
        name: .long,
        help: "Tuist graph JSON. With this, flexview generates its own throwaway host project instead of needing a snapshot target in the repo."
    )
    var graph: String?

    @Option(name: .long, help: "Target to host the previews. Chosen from the graph when omitted.")
    var host: String?

    @Option(name: .long, help: "Path to the flexview checkout, if it cannot be inferred.")
    var runtimeSources: String?

    @Option(name: .long, help: "Path to the SnapshotPreviews checkout, if it cannot be inferred.")
    var snapshotPreviews: String?

    @Option(name: .long, help: "Keep the generated host project instead of deleting it.")
    var keepHostProject: Bool = false

    @Option(name: .long, help: "iOS deployment target for the generated host project.")
    var deploymentTarget: String = "17.0"

    @Flag(
        name: .long,
        help: "Wait for asynchronously loaded content before capturing. Slower, but required for previews whose content arrives late."
    )
    var settle: Bool = false

    @Option(name: .long, help: "Tuist executable. Pass an absolute path to bypass a version manager shim.")
    var tuist: String = "tuist"

    @Option(
        name: .long,
        help: "Directory to launch Tuist from. Defaults to the project being rendered; set it when that project is a worktree with no version manager config."
    )
    var tuistWorkingDirectory: String?

    func validate() throws {
        if workspace != nil, project != nil {
            throw ValidationError("--workspace and --project are mutually exclusive.")
        }

        switch platform {
        case .macos:
            switch (runner, scheme) {
            case (nil, nil):
                throw ValidationError("Pass either --runner <path> or --scheme <name>.")
            case (.some, .some):
                throw ValidationError("--runner and --scheme are mutually exclusive.")
            default:
                break
            }
        case .ios:
            // iOS has no host-side renderer: previews are rendered by an XCTest bundle
            // inside the simulator, so there is no prebuilt binary to point at.
            guard runner == nil else {
                throw ValidationError("--runner applies to --platform macos only; use --graph or --scheme for iOS.")
            }
            if graph == nil {
                guard scheme != nil else {
                    throw ValidationError(
                        "--platform ios needs either --graph <tuist graph json> to generate a host project, "
                            + "or --scheme <name> of a snapshot target you maintain."
                    )
                }
                guard workspace != nil || project != nil else {
                    throw ValidationError("--scheme needs --workspace or --project.")
                }
            }
        }
    }

    func run() async throws {
        switch platform {
        case .macos: try runOnHost()
        case .ios: graph == nil ? try runInSimulator() : try runWithGeneratedHost()
        }
    }

    private func runOnHost() throws {
        let outputDirectory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let executable = if let runner {
            URL(fileURLWithPath: runner)
        } else {
            try buildRunnerExecutable()
        }

        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RenderError.runnerNotExecutable(executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment[RunnerEnvironment.output] = outputDirectory.path
        environment[RunnerEnvironment.appearance] = appearance.rawValue
        if settle { environment[RunnerEnvironment.settle] = "1" }
        if !modules.isEmpty {
            environment[RunnerEnvironment.modules] = modules.joined(separator: ",")
        }

        print("flexview: rendering with \(executable.lastPathComponent) → \(outputDirectory.path)")
        let result = try Shell.run(
            executable.path,
            [],
            environment: environment,
            streamOutput: true,
            timeout: TimeInterval(timeout)
        )
        guard !result.timedOut else {
            throw RenderError.runnerTimedOut(seconds: timeout)
        }

        // Exit code 1 means some previews failed to render; the manifest still lists the
        // rest, and those failures are reported rather than dropped.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw RenderError.runnerFailed(exitCode: result.exitCode)
        }

        let manifest = try Manifest.read(from: outputDirectory)
        print("flexview: \(manifest.entries.count) previews rendered, \(manifest.failures.count) failed")
        for failure in manifest.failures {
            print("  failed: \(failure.previewID) — \(failure.message)")
        }
    }

    /// Generates a throwaway Tuist project that hosts the previews, renders through it,
    /// and removes it. The repository's own manifests are never modified.
    private func runWithGeneratedHost() throws {
        guard let graph else { throw RenderError.missingScheme }

        let targetGraph = try TuistGraphParser.parse(contentsOf: URL(fileURLWithPath: graph))
        let sources = try RuntimeSources.resolve(
            flexviewRoot: runtimeSources,
            snapshotPreviewsRoot: snapshotPreviews
        )

        let selection = try HostSelector.select(
            graph: targetGraph,
            modules: modules,
            explicitHost: host
        )
        print("flexview: \(selection.explanation)")

        // Inside the Tuist root so the generated project inherits the repo's config and
        // ProjectDescriptionHelpers, which targets it links by path depend on.
        let root = URL(fileURLWithPath: selection.tuistRoot)
        let hostProject = HostProject(
            scratchDirectory: root.appendingPathComponent(".flexview-host"),
            host: selection.host,
            sources: sources,
            deploymentTarget: deploymentTarget
        )

        try hostProject.write()
        defer {
            if keepHostProject {
                print("flexview: kept generated project at \(hostProject.scratchDirectory.path)")
            } else {
                hostProject.remove()
            }
        }

        print("flexview: generating host project in \(hostProject.scratchDirectory.lastPathComponent)")
        // Launched from the Tuist root rather than the scratch directory, and from the
        // caller's directory when given: inside a worktree a version manager shim has
        // no config to resolve a version from.
        let launchDirectory = tuistWorkingDirectory.map { URL(fileURLWithPath: $0) } ?? root
        try Tuist(command: tuist, workingDirectory: launchDirectory)
            .run(["generate", "--no-open"], at: hostProject.scratchDirectory)

        try runXcodeBuildTest(
            scheme: HostProject.schemeName,
            workspace: hostProject.scratchDirectory
                .appendingPathComponent("\(HostProject.projectName).xcworkspace").path,
            project: nil
        )
    }

    /// Drives `xcodebuild test`, which builds the snapshot test target, boots the
    /// simulator, and runs the render pass inside it.
    private func runInSimulator() throws {
        guard let scheme else { throw RenderError.missingScheme }
        try runXcodeBuildTest(scheme: scheme, workspace: workspace, project: project)
    }

    private func runXcodeBuildTest(scheme: String, workspace: String?, project: String?) throws {
        let outputDirectory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        // The manifest is how success is judged, so never let a stale one look like a
        // fresh render.
        try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(Manifest.fileName))

        var arguments = ["-scheme", scheme, "-configuration", configuration]
        if let workspace { arguments += ["-workspace", workspace] }
        if let project { arguments += ["-project", project] }
        if let derivedData { arguments += ["-derivedDataPath", derivedData] }
        arguments += ["-destination", Self.destination(for: simulator)]
        // Signing a throwaway host for the simulator is pointless and fails on machines
        // with no development identity.
        arguments += ["CODE_SIGNING_ALLOWED=NO"]

        // xcodebuild forwards TEST_RUNNER_-prefixed variables from its own environment
        // into the test process with the prefix stripped. They must be environment
        // entries, not command line arguments: as arguments xcodebuild would read them
        // as build setting overrides and never pass them on. This is how a host path
        // reaches code running inside the simulator.
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_RUNNER_\(RunnerEnvironment.output)"] = outputDirectory.path
        environment["TEST_RUNNER_\(RunnerEnvironment.appearance)"] = appearance.rawValue
        if settle { environment["TEST_RUNNER_\(RunnerEnvironment.settle)"] = "1" }
        if !modules.isEmpty {
            environment["TEST_RUNNER_\(RunnerEnvironment.modules)"] = modules.joined(separator: ",")
        }

        print("flexview: running \(scheme) on \(simulator ?? "the default simulator")")
        let result = try Shell.run(
            "/usr/bin/xcodebuild",
            arguments + ["test"],
            environment: environment,
            streamOutput: true,
            timeout: TimeInterval(timeout)
        )
        guard !result.timedOut else { throw RenderError.runnerTimedOut(seconds: timeout) }

        // The manifest, not the exit code, decides: xcodebuild reports failure when any
        // preview failed to render, and those are recorded rather than fatal.
        guard FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(Manifest.fileName).path
        ) else {
            throw RenderError.runnerFailed(exitCode: result.exitCode)
        }

        try report(outputDirectory: outputDirectory)
    }

    private static func destination(for simulator: String?) -> String {
        guard let simulator else { return "platform=iOS Simulator,name=iPhone 16" }
        let parts = simulator.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1 else { return "platform=iOS Simulator,name=\(parts[0])" }
        return "platform=iOS Simulator,name=\(parts[0]),OS=\(parts[1])"
    }

    private func report(outputDirectory: URL) throws {
        let manifest = try Manifest.read(from: outputDirectory)
        print("flexview: \(manifest.entries.count) previews rendered, \(manifest.failures.count) failed")
        for failure in manifest.failures {
            print("  failed: \(failure.previewID) — \(failure.message)")
        }
    }

    private func buildRunnerExecutable() throws -> URL {
        guard let scheme else { throw RenderError.missingScheme }

        var arguments = ["-scheme", scheme, "-configuration", configuration, "-destination", "platform=macOS"]
        if let workspace { arguments += ["-workspace", workspace] }
        if let project { arguments += ["-project", project] }
        if let derivedData { arguments += ["-derivedDataPath", derivedData] }

        print("flexview: building scheme \(scheme)")
        _ = try Shell.runChecked("/usr/bin/xcodebuild", arguments + ["build"], streamOutput: true)

        let settings = try Shell.runChecked("/usr/bin/xcodebuild", arguments + ["-showBuildSettings"])
        let values = BuildSettings.parse(settings.standardOutput)
        guard
            let productsDirectory = values["BUILT_PRODUCTS_DIR"],
            let executablePath = values["EXECUTABLE_PATH"]
        else {
            throw RenderError.buildSettingsMissing
        }
        return URL(fileURLWithPath: productsDirectory).appendingPathComponent(executablePath)
    }
}

/// Mirrors `FlexViewRuntime.RunnerOptions.EnvironmentKey`. Duplicated rather than shared
/// because the CLI must not link the runtime (which pulls in SnapshotPreviews and AppKit).
enum RunnerEnvironment {
    static let output = "FLEXVIEW_OUT"
    static let appearance = "FLEXVIEW_APPEARANCE"
    static let modules = "FLEXVIEW_MODULES"
    static let settle = "FLEXVIEW_SETTLE"
}

enum BuildSettings {
    static func parse(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator.lowerBound])
            guard !key.contains(" ") else { continue }
            values[key] = String(trimmed[separator.upperBound...])
        }
        return values
    }
}

enum RenderError: Error, CustomStringConvertible {
    case runnerNotExecutable(String)
    case runnerFailed(exitCode: Int32)
    case runnerTimedOut(seconds: Int)
    case missingScheme
    case buildSettingsMissing

    var description: String {
        switch self {
        case .runnerNotExecutable(let path):
            "No executable at \(path)."
        case .runnerFailed(let exitCode):
            "The runner exited with \(exitCode) without producing a usable manifest."
        case .runnerTimedOut(let seconds):
            "The runner did not finish within \(seconds)s. Raise --timeout if the repo has many previews."
        case .missingScheme:
            "No --scheme to build."
        case .buildSettingsMissing:
            "xcodebuild -showBuildSettings did not report BUILT_PRODUCTS_DIR and EXECUTABLE_PATH."
        }
    }
}

extension RenderPlatform: ExpressibleByArgument {}
extension Appearance: ExpressibleByArgument {}
