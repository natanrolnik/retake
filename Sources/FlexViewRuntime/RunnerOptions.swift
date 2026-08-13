//
//  RunnerOptions.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import FlexViewCore
import Foundation

/// Configuration for a render pass, passed via environment so the host runner target
/// needs no argument parsing of its own.
public struct RunnerOptions: Sendable {
    public var outputDirectory: URL
    public var appearance: Appearance
    /// Restricts rendering to these modules. Nil renders everything.
    ///
    /// Note this filters at render time, not build time: the runner binary still links
    /// every module, so scoping saves rendering, never compilation.
    public var modules: [String]?

    public init(outputDirectory: URL, appearance: Appearance = .light, modules: [String]? = nil) {
        self.outputDirectory = outputDirectory
        self.appearance = appearance
        self.modules = modules
    }

    public enum EnvironmentKey {
        public static let output = "FLEXVIEW_OUT"
        public static let appearance = "FLEXVIEW_APPEARANCE"
        public static let modules = "FLEXVIEW_MODULES"
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingOutputDirectory
        case invalidAppearance(String)

        public var description: String {
            switch self {
            case .missingOutputDirectory:
                "\(EnvironmentKey.output) is not set; it must point at the output directory."
            case .invalidAppearance(let value):
                "\(EnvironmentKey.appearance) is '\(value)'; expected one of "
                    + Appearance.allCases.map(\.rawValue).joined(separator: ", ")
            }
        }
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RunnerOptions {
        guard let output = environment[EnvironmentKey.output], !output.isEmpty else {
            throw Error.missingOutputDirectory
        }

        let appearance: Appearance
        if let raw = environment[EnvironmentKey.appearance], !raw.isEmpty {
            guard let parsed = Appearance(rawValue: raw.lowercased()) else {
                throw Error.invalidAppearance(raw)
            }
            appearance = parsed
        } else {
            appearance = .light
        }

        let modules = environment[EnvironmentKey.modules]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }

        return RunnerOptions(
            outputDirectory: URL(fileURLWithPath: output),
            appearance: appearance,
            modules: modules
        )
    }
}
