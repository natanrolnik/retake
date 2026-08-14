//
//  Render.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import RetakeCore
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

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Render only the previews declared in these source files. Implies the modules that own them."
    )
    var files: [String] = []

    @Option(name: .shortAndLong, help: "Directory for the PNGs and manifest.json.")
    var out: String

    @Option(name: .long, help: "Seconds to wait for the runner before giving up.")
    var timeout: Int = 600

    @Option(
        name: .long,
        help: "How many times to restart past a preview that crashes the runner before giving up."
    )
    var maxRenderAttempts: Int = 6

    @Option(
        name: .long,
        help: "Simulator to render on, as 'name,OS' (iOS only), e.g. 'iPhone 16,18.2'."
    )
    var simulator: String?

    @Option(
        name: .long,
        help: "Tuist graph JSON. With this, retake generates its own throwaway host project instead of needing a snapshot target in the repo."
    )
    var graph: String?

    @Option(
        name: [.customLong("hosts"), .customLong("host")],
        parsing: .upToNextOption,
        help: "App targets allowed to host the previews. Without this every app in scope is used, which is rarely wanted in a repository with per-module preview apps."
    )
    var hosts: [String] = []

    @Option(name: .long, help: "Path to the retake checkout, if it cannot be inferred.")
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

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Pipe xcodebuild through xcbeautify when it is available. A full build log buries the few lines worth reading."
    )
    var pretty: Bool = true

    @Option(
        name: .long,
        help: "Tuist binary cache profile for the generated host: only-external, all-possible, none, or a custom profile. Reuses prebuilt binaries instead of compiling dependencies from source."
    )
    var cacheProfile: String?

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Extra environment for the render process, as KEY=VALUE. Defaults to telling swift-dependencies it is in a preview, since it otherwise treats the runner as a test and fails any dependency without a test implementation."
    )
    var env: [String] = ["SWIFT_DEPENDENCIES_CONTEXT=preview"]

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

    /// Turns `--files` paths into the `#fileID` values the runtime matches on, which are
    /// "Module/Basename.swift". The module comes from whichever target owns the file.
    private func fileIDs() -> [String] {
        guard
            let graph,
            let targetGraph = try? TuistGraphParser.parse(contentsOf: URL(fileURLWithPath: graph))
        else {
            return []
        }
        return files.compactMap { path in
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            guard
                let owner = targetGraph.owner(ofFile: absolute),
                let module = targetGraph.targets[owner]?.productName
            else {
                return nil
            }
            return "\(module)/\((absolute as NSString).lastPathComponent)"
        }
    }

    /// Modules owning `--files`, so the render only builds what it needs.
    func modulesForFiles() -> [String] {
        Array(Set(fileIDs().compactMap { $0.split(separator: "/").first.map(String.init) }))
    }

    /// Parsed `--env`, dropping anything that is not KEY=VALUE.
    private var runnerEnvironment: [String: String] {
        Dictionary(
            env.compactMap { entry in
                guard let separator = entry.firstIndex(of: "=") else { return nil }
                return (String(entry[entry.startIndex..<separator]), String(entry[entry.index(after: separator)...]))
            },
            uniquingKeysWith: { _, last in last }
        )
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
        for (key, value) in runnerEnvironment {
            environment[key] = value
        }
        if settle { environment[RunnerEnvironment.settle] = "1" }
        if !modules.isEmpty {
            environment[RunnerEnvironment.modules] = modules.joined(separator: ",")
        }

        print("retake: rendering with \(executable.lastPathComponent) → \(outputDirectory.path)")
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
        print("retake: \(manifest.entries.count) previews rendered, \(manifest.failures.count) failed")
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
            retakeRoot: runtimeSources,
            snapshotPreviewsRoot: snapshotPreviews
        )

        let selection = try HostSelector.select(
            graph: targetGraph,
            modules: modules.isEmpty ? modulesForFiles() : modules,
            candidateHosts: hosts
        )
        print("retake: \(selection.explanation)")

        let outputDirectory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var entries: [ManifestEntry] = []
        var failures: [ManifestFailure] = []

        // One pass per host. Modules are partitioned across hosts, so a preview is
        // rendered exactly once and the merged manifest has no duplicates.
        for (index, assignment) in selection.assignments.enumerated() {
            let passDirectory = outputDirectory.appendingPathComponent(".pass-\(index)")
            try? FileManager.default.removeItem(at: passDirectory)

            let manifest = try renderSurvivingCrashes(
                assignment: assignment,
                tuistRoot: URL(fileURLWithPath: selection.tuistRoot),
                sources: sources,
                into: passDirectory
            )
            for entry in manifest.entries {
                // The PNG names are keyed on the preview id, which is unique across
                // hosts because the modules are.
                let destination = outputDirectory.appendingPathComponent(entry.pngPath)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(
                    at: passDirectory.appendingPathComponent(entry.pngPath),
                    to: destination
                )
                entries.append(entry)
            }
            failures.append(contentsOf: manifest.failures)
            try? FileManager.default.removeItem(at: passDirectory)
        }

        try Manifest(
            configuration: RenderConfiguration(
                platform: .ios,
                appearance: appearance,
                simulator: simulator
            ),
            entries: entries,
            failures: failures
        ).write(to: outputDirectory)

        let manifest = try Manifest.read(from: outputDirectory)
        print("retake: \(entries.count) previews rendered, \(failures.count) failed")
        for failure in failures {
            print("  failed: \(failure.previewID) — \(failure.message)")
        }
        warnIfIdentical(manifest)
    }

    /// Reports the case where rendering "succeeded" but produced nothing.
    private func warnIfIdentical(_ manifest: Manifest) {
        guard manifest.rendersAreAllIdentical else { return }
        FileHandle.standardError.write(Data("""
        retake: warning: all \(manifest.entries.count) previews rendered to an identical \
        image, which means none of them actually drew. The window was captured before any \
        content reached it, or the host never handed the view over. A diff of two such \
        passes will report no changes at all.

        """.utf8))
    }

    /// Renders a host, restarting past any preview that crashes the process.
    ///
    /// Preview bodies are arbitrary view code running in one process, and some of it
    /// brings the process down: a corrupt image, a service that is not there. Without
    /// this, one such preview costs every other preview in the pass.
    private func renderSurvivingCrashes(
        assignment: HostAssignment,
        tuistRoot: URL,
        sources: RuntimeSources,
        into passDirectory: URL
    ) throws -> Manifest {
        var crashers: [PreviewID] = []

        for attempt in 1...maxRenderAttempts {
            try? render(
                assignment: assignment,
                tuistRoot: tuistRoot,
                sources: sources,
                into: passDirectory,
                skipping: crashers
            )

            // The runner saves after every preview, so a manifest exists even when the
            // process died part way.
            let manifest = try? Manifest.read(from: passDirectory)
            let inFlight = try? String(
                contentsOf: passDirectory.appendingPathComponent("in-flight.txt"),
                encoding: .utf8
            )

            guard let stalled = inFlight?.trimmingCharacters(in: .whitespacesAndNewlines), !stalled.isEmpty else {
                guard let manifest else { throw RenderError.runnerFailed(exitCode: 1) }
                return manifest
            }

            let culprit = PreviewID(rawValue: stalled)
            crashers.append(culprit)
            print("retake: \(culprit) crashed the runner; retrying without it (\(attempt) of \(maxRenderAttempts))")
            try? FileManager.default.removeItem(at: passDirectory.appendingPathComponent("in-flight.txt"))
        }

        throw RenderError.tooManyCrashes(crashers.map(\.rawValue))
    }

    /// Generates a throwaway Tuist project for one host, renders through it, and removes
    /// it. The repository's own manifests are never modified.
    private func render(
        assignment: HostAssignment,
        tuistRoot: URL,
        sources: RuntimeSources,
        into passDirectory: URL,
        skipping crashers: [PreviewID] = []
    ) throws {
        // Inside the Tuist root so the generated project inherits the repo's config and
        // ProjectDescriptionHelpers, which targets it links by path depend on.
        let hostProject = HostProject(
            scratchDirectory: tuistRoot.appendingPathComponent(".retake-host"),
            host: assignment.host,
            sources: sources,
            deploymentTarget: deploymentTarget
        )

        try hostProject.write()
        defer {
            if keepHostProject {
                print("retake: kept generated project at \(hostProject.scratchDirectory.path)")
            } else {
                hostProject.remove()
            }
        }

        print("retake: generating host project in \(hostProject.scratchDirectory.lastPathComponent)")
        // Launched from the Tuist root rather than the scratch directory, and from the
        // caller's directory when given: inside a worktree a version manager shim has
        // no config to resolve a version from.
        let launchDirectory = tuistWorkingDirectory.map { URL(fileURLWithPath: $0) } ?? tuistRoot
        var generateArguments = ["generate", "--no-open"]
        // Reuses the repository's warmed binary cache rather than compiling its
        // dependencies from source, which is both much faster and avoids inheriting
        // whatever a from-source build of those dependencies would surface.
        if let cacheProfile { generateArguments += ["--cache-profile", cacheProfile] }
        try Tuist(command: tuist, workingDirectory: launchDirectory)
            .run(generateArguments, at: hostProject.scratchDirectory)

        try runXcodeBuildTest(
            scheme: HostProject.schemeName,
            workspace: hostProject.scratchDirectory
                .appendingPathComponent("\(HostProject.projectName).xcworkspace").path,
            project: nil,
            modules: assignment.modules,
            out: passDirectory,
            skipping: crashers,
            hostIsFromRepository: {
                if case .existingApp = assignment.host { return true } else { return false }
            }()
        )
    }

    /// Drives `xcodebuild test`, which builds the snapshot test target, boots the
    /// simulator, and runs the render pass inside it.
    private func runInSimulator() throws {
        guard let scheme else { throw RenderError.missingScheme }
        try runXcodeBuildTest(scheme: scheme, workspace: workspace, project: project)
    }

    private func runXcodeBuildTest(
        scheme: String,
        workspace: String?,
        project: String?,
        modules: [String]? = nil,
        out: URL? = nil,
        skipping crashers: [PreviewID] = [],
        hostIsFromRepository: Bool = false
    ) throws {
        let modules = modules ?? self.modules
        let outputDirectory = out ?? URL(fileURLWithPath: self.out)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        // The manifest is how success is judged, so never let a stale one look like a
        // fresh render.
        try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(Manifest.fileName))

        var arguments = ["-scheme", scheme, "-configuration", configuration]
        if let workspace { arguments += ["-workspace", workspace] }
        if let project { arguments += ["-project", project] }
        if let derivedData { arguments += ["-derivedDataPath", derivedData] }
        let device = try resolvedSimulator()
        arguments += ["-destination", Self.destination(for: device)]
        // Only for a host retake generated itself, which has no entitlements to lose.
        // An app from the repository must keep its own: simulator builds carry
        // entitlements through an ad-hoc signature, and without one an app that reaches
        // for a CloudKit container gets a container that does not exist and traps on
        // launch. Previews of that app then never render at all.
        if !hostIsFromRepository {
            arguments += ["CODE_SIGNING_ALLOWED=NO"]
        }

        // xcodebuild forwards TEST_RUNNER_-prefixed variables from its own environment
        // into the test process with the prefix stripped. They must be environment
        // entries, not command line arguments: as arguments xcodebuild would read them
        // as build setting overrides and never pass them on. This is how a host path
        // reaches code running inside the simulator.
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_RUNNER_\(RunnerEnvironment.output)"] = outputDirectory.path
        environment["TEST_RUNNER_\(RunnerEnvironment.appearance)"] = appearance.rawValue
        // Not XCODE_RUNNING_FOR_PREVIEWS: setting that makes SwiftUI hand rendering to
        // Xcode's own preview harness, which is not there, and every preview comes back
        // as an identical blank window. Target the library that actually branches.
        for (key, value) in runnerEnvironment {
            environment["TEST_RUNNER_\(key)"] = value
        }
        if settle { environment["TEST_RUNNER_\(RunnerEnvironment.settle)"] = "1" }
        if !files.isEmpty {
            environment["TEST_RUNNER_\(RunnerEnvironment.files)"] = fileIDs().joined(separator: "\n")
        }
        if !crashers.isEmpty {
            // Newline separated: preview ids contain commas.
            environment["TEST_RUNNER_\(RunnerEnvironment.skip)"] = crashers.map(\.rawValue).joined(separator: "\n")
        }
        if !modules.isEmpty {
            environment["TEST_RUNNER_\(RunnerEnvironment.modules)"] = modules.joined(separator: ",")
        }

        print("retake: running \(scheme) on \(device)")
        let command = XcodeBuild.command(arguments: arguments + ["test"], pretty: pretty)
        let result = try Shell.run(
            command.executable,
            command.arguments,
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

        if out == nil { try report(outputDirectory: outputDirectory) }
    }

    /// The simulator to use, chosen from the machine when the caller named none.
    private func resolvedSimulator() throws -> String {
        if let simulator, !simulator.isEmpty { return simulator }
        let picked = try SimulatorPicker.pick()
        // Printed because a render is only comparable to another on the same device.
        print("retake: no --simulator given, using \(picked.descriptor)\(picked.isBooted ? " (already booted)" : "")")
        return picked.descriptor
    }

    private static func destination(for simulator: String?) -> String {
        guard let simulator else { return "platform=iOS Simulator" }
        let parts = simulator.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1 else { return "platform=iOS Simulator,name=\(parts[0])" }
        return "platform=iOS Simulator,name=\(parts[0]),OS=\(parts[1])"
    }

    private func report(outputDirectory: URL) throws {
        let manifest = try Manifest.read(from: outputDirectory)
        print("retake: \(manifest.entries.count) previews rendered, \(manifest.failures.count) failed")
        for failure in manifest.failures {
            print("  failed: \(failure.previewID) — \(failure.message)")
        }
        warnIfIdentical(manifest)
    }

    private func buildRunnerExecutable() throws -> URL {
        guard let scheme else { throw RenderError.missingScheme }

        var arguments = ["-scheme", scheme, "-configuration", configuration, "-destination", "platform=macOS"]
        if let workspace { arguments += ["-workspace", workspace] }
        if let project { arguments += ["-project", project] }
        if let derivedData { arguments += ["-derivedDataPath", derivedData] }

        print("retake: building scheme \(scheme)")
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

/// Mirrors `RetakeRuntime.RunnerOptions.EnvironmentKey`. Duplicated rather than shared
/// because the CLI must not link the runtime (which pulls in SnapshotPreviews and AppKit).
enum RunnerEnvironment {
    static let output = "RETAKE_OUT"
    static let appearance = "RETAKE_APPEARANCE"
    static let modules = "RETAKE_MODULES"
    static let settle = "RETAKE_SETTLE"
    static let skip = "RETAKE_SKIP"
    static let files = "RETAKE_FILES"
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
    case tooManyCrashes([String])

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
        case .tooManyCrashes(let previews):
            """
            Gave up after \(previews.count) previews crashed the runner: \
            \(previews.joined(separator: ", ")). Render them by hand to see why.
            """
        }
    }
}

extension RenderPlatform: ExpressibleByArgument {}
extension Appearance: ExpressibleByArgument {}
