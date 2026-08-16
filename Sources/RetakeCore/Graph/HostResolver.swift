//
//  HostResolver.swift
//  retake
//
//  Created by Natan Rolnik on 14-08-2026.
//

import Foundation

/// What the previews are rendered inside.
///
/// A preview only exists inside a process that links its module, and a static framework
/// only exists once some app links it. So the question is never *whether* there is a
/// host, only which one.
public enum PreviewHost: Equatable, Sendable {
    /// An app the repository already has, which is the only way to reach its own previews.
    case existingApp(TargetGraph.TargetID)
    /// Frameworks with no app to host them: an empty app is synthesised to link them, so
    /// nothing in the repository has to change and no unrelated app has to be built.
    case synthesized(linking: [TargetGraph.TargetID])

    public var linkedTargets: [TargetGraph.TargetID] {
        switch self {
        case .existingApp(let id): [id]
        case .synthesized(let targets): targets
        }
    }
}

/// One render pass: a host, and the modules whose previews it is responsible for.
public struct HostAssignment: Equatable, Sendable {
    public var host: PreviewHost
    /// Product names, for `--modules`.
    public var modules: [String]

    public init(host: PreviewHost, modules: [String]) {
        self.host = host
        self.modules = modules
    }
}

public enum HostResolver {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case noTargetsInScope
        case unknownHost(String)

        public var description: String {
            switch self {
            case .noTargetsInScope:
                "No modules in scope, so there is nothing to host."
            case .unknownHost(let name):
                "\(name) is not an app target in the graph."
            }
        }
    }

    /// Splits the modules in scope across one render pass per host.
    ///
    /// An app hosts only the previews declared in the app target itself. Every other
    /// module is hosted by a synthesised app, even when some app in scope already links
    /// it, because a static framework linked normally contributes only the object files
    /// something references: a preview in a file the app never touches is dropped by the
    /// linker and silently never discovered. The synthesised host passes `-all_load`, so
    /// every object file survives. It is also the cheaper build for a leaf change.
    ///
    /// Each module is assigned to exactly one host, because rendering a shared module in
    /// two hosts would produce the same preview twice, and the same preview can render
    /// differently in different hosts. Assignment is by sorted name so it is stable
    /// between the base and head passes; an unstable choice here would make every preview
    /// in a moved module look changed.
    ///
    /// - Parameters:
    ///   - candidateHosts: app targets allowed to host. Empty considers every app in
    ///     scope, which is rarely what a repository with per-module preview apps wants.
    public static func resolve(
        graph: TargetGraph,
        modules: [String],
        candidateHosts: [String] = [],
        platform: RenderPlatform = .ios
    ) throws -> [HostAssignment] {
        let inScope = modules.isEmpty
            ? graph.renderableTargets(for: platform)
            : graph.targets.values.filter { modules.contains($0.productName) }
        let renderable = inScope.filter {
            !graph.isTestBundle($0.id) && !$0.isExternal && $0.supports(platform)
        }
        guard !renderable.isEmpty else { throw Error.noTargetsInScope }

        let apps: [TargetGraph.Target]
        if candidateHosts.isEmpty {
            apps = renderable.filter { graph.isApp($0.id) }
        } else {
            apps = try candidateHosts.map { name in
                guard let target = graph.targets.values.first(where: {
                    graph.isApp($0.id) && ($0.id.name == name || $0.productName == name)
                }) else {
                    throw Error.unknownHost(name)
                }
                return target
            }
        }
        let sortedApps = apps.sorted { $0.id < $1.id }

        // An app is the only thing that can reach its own previews, so it hosts those and
        // nothing else.
        let inScopeApps = Set(renderable.map(\.id))
        var assignments: [HostAssignment] = sortedApps
            .filter { inScopeApps.contains($0.id) }
            .map { HostAssignment(host: .existingApp($0.id), modules: [$0.productName]) }

        // Everything that is not an app renders in a synthesised host, which force-loads
        // what it links rather than trusting an app to reference the right files.
        let frameworks = renderable.filter { !graph.isApp($0.id) }
        if !frameworks.isEmpty {
            assignments.append(HostAssignment(
                host: .synthesized(linking: frameworks.map(\.id).sorted()),
                modules: frameworks.map(\.productName).sorted()
            ))
        }

        guard !assignments.isEmpty else { throw Error.noTargetsInScope }
        return assignments
    }
}
