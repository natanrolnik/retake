//
//  HostSelector.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import FlexViewCore
import Foundation

/// Wraps `HostResolver` with the filesystem lookup the decision needs: where the
/// generated project has to live for Tuist to load the repo's config and helpers.
enum HostSelector {
    struct Selection {
        var host: PreviewHost
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
        explicitHost: String?
    ) throws -> Selection {
        let host = try HostResolver.resolve(graph: graph, modules: modules, explicitHost: explicitHost)
        let anchor = host.linkedTargets[0].project

        let explanation = switch host {
        case .existingApp(let app) where explicitHost != nil:
            "hosting previews in \(app.name) (--host)"
        case .existingApp(let app):
            "hosting previews in \(app.name), which is itself in scope"
        case .synthesized(let linked):
            "synthesizing a host app linking \(linked.map(\.name).joined(separator: ", "))"
        }

        return Selection(
            host: host,
            tuistRoot: try tuistRoot(startingAt: anchor),
            explanation: explanation
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
