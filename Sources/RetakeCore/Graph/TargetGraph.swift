//
//  TargetGraph.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// The build graph, reduced to what scoping needs: which files a target owns and which
/// targets depend on it.
public struct TargetGraph: Sendable {
    public struct TargetID: Hashable, Sendable, Codable, Comparable {
        /// Directory of the project declaring the target. Disambiguates same-named
        /// targets across projects in one workspace.
        public var project: String
        public var name: String

        public init(project: String, name: String) {
            self.project = project
            self.name = name
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.name, lhs.project) < (rhs.name, rhs.project)
        }
    }

    /// An Xcode buildable folder: everything underneath it belongs to the target unless
    /// explicitly excluded. Unlike a source list, this also claims files that do not
    /// exist yet, which is what makes newly added files attributable.
    public struct BuildableFolder: Sendable, Equatable {
        public var root: String
        public var excluded: Set<String>

        public init(root: String, excluded: Set<String>) {
            self.root = root
            self.excluded = excluded
        }

        public func contains(_ path: String) -> Bool {
            guard !excluded.contains(path) else { return false }
            return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    public struct Target: Sendable, Equatable {
        public var id: TargetID
        /// The module name previews report. Not always equal to the target name.
        public var productName: String
        /// Tuist's product kind, e.g. "app", "framework", "staticFramework", "unitTests".
        public var product: String = ""
        /// Explicit sources plus the files a buildable folder currently resolves to.
        public var sources: [String]
        public var resources: [String]
        public var buildableFolders: [BuildableFolder]
        /// A dependency Tuist generated a project for, rather than a target the
        /// repository wrote. Nothing here has previews worth rendering.
        public var isExternal: Bool
        /// Tuist destinations, e.g. iPhone, iPad, appleTv, appleWatch, mac.
        public var destinations: [String]
        /// Needed to clear a stale install of a host app off the simulator.
        public var bundleID: String?

        public init(
            id: TargetID,
            productName: String,
            product: String = "",
            sources: [String],
            resources: [String],
            buildableFolders: [BuildableFolder] = [],
            isExternal: Bool = false,
            destinations: [String] = [],
            bundleID: String? = nil
        ) {
            self.id = id
            self.productName = productName
            self.product = product
            self.sources = sources
            self.resources = resources
            self.buildableFolders = buildableFolders
            self.isExternal = isExternal
            self.destinations = destinations
            self.bundleID = bundleID
        }

        /// Whether this target can run on the platform being rendered.
        ///
        /// A watch or TV app has nothing to contribute to an iOS render, and pulling one
        /// in makes the build fail on a machine that has no such simulator.
        public func supports(_ platform: RenderPlatform) -> Bool {
            guard !destinations.isEmpty else { return true }
            let wanted: Set<String> = switch platform {
            case .ios: ["iPhone", "iPad", "macWithiPadDesign"]
            case .macos: ["mac", "macWithiPadDesign", "macCatalyst"]
            }
            return !wanted.isDisjoint(with: Set(destinations))
        }

        public func owns(_ path: String) -> Bool {
            sources.contains(path)
                || resources.contains(path)
                || buildableFolders.contains { $0.contains(path) }
        }
    }

    public var targets: [TargetID: Target]
    /// target -> the targets it depends on.
    public var dependencies: [TargetID: Set<TargetID>]

    public init(targets: [TargetID: Target], dependencies: [TargetID: Set<TargetID>]) {
        self.targets = targets
        self.dependencies = dependencies
    }

    /// target -> the targets that depend on it, directly.
    public var dependents: [TargetID: Set<TargetID>] {
        var reversed: [TargetID: Set<TargetID>] = [:]
        for (target, requirements) in dependencies {
            for requirement in requirements {
                reversed[requirement, default: []].insert(target)
            }
        }
        return reversed
    }

    /// The seeds plus everything that transitively depends on them.
    ///
    /// This is the direction that matters: a change in a leaf design-system module must
    /// pull in every feature module that consumes it, none of whose files appear in the
    /// diff.
    public func transitiveDependents(of seeds: Set<TargetID>) -> Set<TargetID> {
        let dependents = self.dependents
        var reached = seeds
        var pending = Array(seeds)

        while let current = pending.popLast() {
            for dependent in dependents[current] ?? [] where reached.insert(dependent).inserted {
                pending.append(dependent)
            }
        }
        return reached
    }

    /// Everything the given targets depend on, transitively. The direction an app needs
    /// to know what it can host.
    public func transitiveDependencies(of roots: Set<TargetID>) -> Set<TargetID> {
        var reached = roots
        var pending = Array(roots)
        while let current = pending.popLast() {
            for requirement in dependencies[current] ?? [] where reached.insert(requirement).inserted {
                pending.append(requirement)
            }
        }
        return reached
    }

    /// The targets of the project whose directory contains this file.
    ///
    /// A file can matter to rendering without belonging to a target: a `Project.swift`
    /// declaring how the targets are built, a resource the manifest globs in, a file too
    /// new to be in the graph. Attributing it to its project is far closer to the truth
    /// than the alternative of treating every target in the repository as affected,
    /// which on a large graph means rendering nothing useful for an hour.
    ///
    /// Longest matching project path wins, so a file in a nested project is not claimed
    /// by the root one.
    public func targetsOfProject(containing path: String) -> Set<TargetID>? {
        let projects = Set(targets.keys.map(\.project))
        let match = projects
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
        guard let match else { return nil }
        return Set(targets.keys.filter { $0.project == match })
    }

    /// Maps an absolute file path to the target that compiles or bundles it.
    public func owner(ofFile path: String) -> TargetID? {
        targets.values.first { $0.owns(path) }?.id
    }

    /// Only an app can host a test bundle that renders previews.
    public func isApp(_ id: TargetID) -> Bool {
        targets[id]?.product == "app"
    }

    public func isTestBundle(_ id: TargetID) -> Bool {
        // Tuist writes these snake_cased in the graph ("unit_tests"), not as they are
        // spelled in a manifest. Matching the manifest spelling silently matched nothing,
        // and test bundles were linked into hosts.
        let product = (targets[id]?.product ?? "").replacingOccurrences(of: "_", with: "").lowercased()
        return product.hasSuffix("tests")
    }

    /// An extension, app clip or watch app: something a host app embeds rather than
    /// links, and which therefore cannot be rendered.
    ///
    /// A synthesised host embeds it and the build fails validation, because an
    /// extension's bundle id has to be prefixed by its host app's. Hosting it in the real
    /// app does not work either: an embedded bundle runs as its own process, so its
    /// preview metadata never appears in the app's.
    public func isEmbeddedBundle(_ id: TargetID) -> Bool {
        let product = (targets[id]?.product ?? "").replacingOccurrences(of: "_", with: "").lowercased()
        return product.hasSuffix("extension") || product.hasSuffix("clip") || product == "watch2app"
    }

    /// Targets worth rendering: the repository's own, excluding test bundles and
    /// anything a host app embeds rather than links.
    ///
    /// Without this, "render everything" means every package Tuist generated a project
    /// for, and a run tries to host SwiftSyntax and GRDB.
    public func renderableTargets(for platform: RenderPlatform = .ios) -> [Target] {
        targets.values
            .filter {
                !$0.isExternal && !isTestBundle($0.id) && !isEmbeddedBundle($0.id)
                    && $0.supports(platform)
            }
            .sorted { $0.id < $1.id }
    }

    public var sourcesByModule: [String: [String]] {
        Dictionary(
            targets.values.map { ($0.productName, $0.sources) },
            uniquingKeysWith: { $0 + $1 }
        )
    }

    /// Targets that claim no files at all. Ownership lookups can never hit them, so a
    /// change inside one would be invisible to scoping.
    public var targetsWithoutFileOwnership: [Target] {
        targets.values
            .filter { $0.sources.isEmpty && $0.resources.isEmpty && $0.buildableFolders.isEmpty }
            .sorted { $0.id < $1.id }
    }
}
