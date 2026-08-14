//
//  Scope.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Which modules a change could possibly affect.
///
/// Purely a cost optimization: it decides what *not* to render. Correctness still comes
/// from rendering and comparing images, so this must never narrow the scope on a guess.
/// Anything it cannot account for widens to everything.
public struct Scope: Codable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "affected-targets.json"

    public var version: Int
    public var isEverything: Bool
    /// Why the scope came out this way, in a form worth printing in CI.
    public var reasons: [String]
    /// Module names to pass to `retake render --modules`. Empty when `isEverything`.
    public var modules: [String]
    public var targets: [TargetGraph.TargetID]
    /// Non-fatal problems that make the result less trustworthy.
    public var warnings: [String]

    public init(
        version: Int = Scope.currentVersion,
        isEverything: Bool,
        reasons: [String],
        modules: [String],
        targets: [TargetGraph.TargetID],
        warnings: [String]
    ) {
        self.version = version
        self.isEverything = isEverything
        self.reasons = reasons
        self.modules = modules.sorted()
        self.targets = targets.sorted()
        self.warnings = warnings
    }
}

public enum ScopeResolver {
    /// Maps changed files to the modules whose previews could have changed.
    ///
    /// - Parameters:
    ///   - changedFiles: absolute paths.
    ///   - ignored: glob patterns for files judged incapable of affecting rendering.
    ///     Every match is reported, so the caller can see what was skipped.
    ///   - root: repository root the patterns are written against.
    public static func resolve(
        graph: TargetGraph,
        changedFiles: [String],
        ignored: [PathGlob] = [],
        root: String = ""
    ) -> Scope {
        var warnings: [String] = []

        // A target claiming no files can never be reached by an ownership lookup, so a
        // change inside it would silently narrow the scope. Say so rather than pretend.
        let unattributable = graph.targetsWithoutFileOwnership
        if !unattributable.isEmpty {
            warnings.append(
                "\(unattributable.count) targets list no sources, resources or buildable folders "
                    + "(\(unattributable.prefix(5).map(\.id.name).joined(separator: ", "))"
                    + "\(unattributable.count > 5 ? ", …" : "")); "
                    + "changes inside them cannot be attributed."
            )
        }

        for collision in SourceBasenameCollision.detect(sourcesByModule: graph.sourcesByModule) {
            warnings.append(
                "\(collision.module) has \(collision.paths.count) files named \(collision.basename) "
                    + "(\(collision.paths.joined(separator: ", "))). #fileID cannot tell them apart, "
                    + "so unnamed previews in those files may change identity."
            )
        }

        var seeds: Set<TargetGraph.TargetID> = []
        var unowned: [String] = []
        for file in changedFiles where !ignored.matchAny(file, relativeTo: root) {
            if let owner = graph.owner(ofFile: file) {
                seeds.insert(owner)
            } else {
                unowned.append(file)
            }
        }

        guard unowned.isEmpty else {
            // A manifest, an asset catalog, a new file not yet in the graph: any of these
            // can change rendering in ways no dependency edge describes.
            let listed = unowned.prefix(5).joined(separator: ", ")
            let more = unowned.count > 5 ? " and \(unowned.count - 5) more" : ""
            return everything(
                graph: graph,
                reasons: ["no target owns \(listed)\(more)"],
                warnings: warnings
            )
        }

        guard !seeds.isEmpty else {
            return Scope(
                isEverything: false,
                reasons: ["no changed file belongs to any target"],
                modules: [],
                targets: [],
                warnings: warnings
            )
        }

        let affected = graph.transitiveDependents(of: seeds)
        let seedNames = seeds.map(\.name).sorted().joined(separator: ", ")
        return Scope(
            isEverything: false,
            reasons: ["changed files belong to \(seedNames); included those and everything depending on them"],
            modules: Array(Set(affected.compactMap { graph.targets[$0]?.productName })),
            targets: Array(affected),
            warnings: warnings
        )
    }

    private static func everything(
        graph: TargetGraph,
        reasons: [String],
        warnings: [String]
    ) -> Scope {
        Scope(
            isEverything: true,
            reasons: reasons,
            modules: [],
            targets: Array(graph.targets.keys),
            warnings: warnings
        )
    }
}
