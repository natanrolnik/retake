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
        /// Never silent: a target dropped without a word reads as one with no previews.
        var warnings: [String] = []
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
        candidateHosts: [String],
        platform: RenderPlatform = .ios
    ) throws -> Selection {
        let assignments = try HostResolver.resolve(
            graph: graph,
            modules: modules,
            candidateHosts: candidateHosts,
            platform: platform
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

        let embedded = graph.targets.values
            .filter { graph.isEmbeddedBundle($0.id) && !$0.isExternal }
            .filter { modules.isEmpty || modules.contains($0.productName) }
            .map(\.productName)
            .sorted()

        return Selection(
            assignments: assignments,
            tuistRoot: try tuistRoot(startingAt: anchor),
            explanation: assignments.count == 1
                ? "rendering in \(explanation)"
                : "\(assignments.count) render passes: \(explanation)",
            warnings: embedded.isEmpty ? [] : [
                """
                not rendering \(embedded.joined(separator: ", ")): an app embeds these \
                rather than linking them, so they run as their own process and their \
                previews are not reachable from a host
                """,
            ]
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
