//
//  HostSelector.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import RetakeCore
import Foundation

/// Wraps `HostResolver` with the filesystem lookup the decision needs: where the
/// generated project has to live for Tuist to load the repo's config and helpers.
enum HostSelector {
    struct Selection {
        var assignments: [HostAssignment]
        /// Directory holding the repo's Tuist.swift.
        var tuistRoot: String
        var explanation: String
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case noTuistRoot(String)

        var description: String {
            switch self {
            case .noTuistRoot(let path):
                "Could not find a Tuist.swift above \(path); is this a Tuist repository?"
            }
        }
    }

    static func select(
        graph: TargetGraph,
        modules: [String],
        candidateHosts: [String]
    ) throws -> Selection {
        let assignments = try HostResolver.resolve(
            graph: graph,
            modules: modules,
            candidateHosts: candidateHosts
        )
        let anchor = assignments[0].host.linkedTargets[0].project

        let explanation = assignments
            .map { assignment in
                switch assignment.host {
                case .existingApp(let app):
                    "\(app.name) hosting \(assignment.modules.joined(separator: ", "))"
                case .synthesized(let linked):
                    "a synthesised host linking \(linked.map(\.name).joined(separator: ", "))"
                }
            }
            .joined(separator: "; ")

        return Selection(
            assignments: assignments,
            tuistRoot: try tuistRoot(startingAt: anchor),
            explanation: assignments.count == 1
                ? "rendering in \(explanation)"
                : "\(assignments.count) render passes: \(explanation)"
        )
    }

    /// Walks up until it finds the directory holding Tuist.swift.
    private static func tuistRoot(startingAt path: String) throws -> String {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Tuist.swift").path
            ) {
                return directory.path
            }
            directory = directory.deletingLastPathComponent()
        }
        throw Error.noTuistRoot(path)
    }
}
