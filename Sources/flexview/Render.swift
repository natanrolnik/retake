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

    func validate() throws {
        guard platform == .macos else {
            throw ValidationError("--platform ios is not implemented yet; only macos renders today.")
        }
        switch (runner, scheme) {
        case (nil, nil):
            throw ValidationError("Pass either --runner <path> or --scheme <name>.")
        case (.some, .some):
            throw ValidationError("--runner and --scheme are mutually exclusive.")
        default:
            break
        }
        if workspace != nil, project != nil {
            throw ValidationError("--workspace and --project are mutually exclusive.")
        }
    }

    func run() async throws {
        let outputDirectory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let executable = if let runner {
            URL(fileURLWithPath: runner)
        } else {
            try buildRunner()
        }

        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RenderError.runnerNotExecutable(executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment[RunnerEnvironment.output] = outputDirectory.path
        environment[RunnerEnvironment.appearance] = appearance.rawValue
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

    private func buildRunner() throws -> URL {
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
