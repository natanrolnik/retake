//
//  HostResolver.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// What the previews are rendered inside.
///
/// A preview only exists inside a process that links its module, and a static framework
/// only exists once some app links it. So the question is never *whether* there is a
/// host, only which one.
public enum PreviewHost: Equatable, Sendable {
    /// The scope includes an app, whose own previews are reachable only from inside it.
    case existingApp(TargetGraph.TargetID)
    /// Frameworks only: an empty app is synthesized to link them, so nothing in the
    /// repository has to change and no unrelated app has to be built.
    case synthesized(linking: [TargetGraph.TargetID])

    public var linkedTargets: [TargetGraph.TargetID] {
        switch self {
        case .existingApp(let id): [id]
        case .synthesized(let targets): targets
        }
    }
}

public enum HostResolver {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case noTargetsInScope
        case unknownHost(String)
        case severalApps([String])

        public var description: String {
            switch self {
            case .noTargetsInScope:
                "No modules in scope, so there is nothing to host."
            case .unknownHost(let name):
                "--host \(name) is not a target in the graph."
            case .severalApps(let names):
                """
                The change spans several app targets (\(names.joined(separator: ", "))), \
                which cannot host each other. Render them separately, or pass --host.
                """
            }
        }
    }

    /// - Parameters:
    ///   - modules: product names in scope. Empty means everything.
    ///   - explicitHost: overrides the rule. Worth pinning across base and head, since
    ///     the same preview can render differently in different hosts and a host that
    ///     changed between the two sides would make every preview look changed.
    public static func resolve(
        graph: TargetGraph,
        modules: [String],
        explicitHost: String? = nil
    ) throws -> PreviewHost {
        let inScope = modules.isEmpty
            ? Array(graph.targets.values)
            : graph.targets.values.filter { modules.contains($0.productName) }
        guard !inScope.isEmpty else { throw Error.noTargetsInScope }

        if let explicitHost {
            guard let target = graph.targets.values.first(where: {
                $0.id.name == explicitHost || $0.productName == explicitHost
            }) else {
                throw Error.unknownHost(explicitHost)
            }
            return .existingApp(target.id)
        }

        let apps = inScope.filter { graph.isApp($0.id) }.map(\.id).sorted()
        if apps.count > 1 {
            throw Error.severalApps(apps.map(\.name))
        }
        if let app = apps.first {
            return .existingApp(app)
        }
        // Test bundles cannot host anything and have no previews worth rendering.
        let linkable = inScope.filter { !graph.isTestBundle($0.id) }.map(\.id).sorted()
        guard !linkable.isEmpty else { throw Error.noTargetsInScope }
        return .synthesized(linking: linkable)
    }
}
