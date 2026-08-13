//
//  TuistGraphParser.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Reads `tuist graph --format json`.
///
/// Hand written rather than Codable because two fields are Swift dictionaries with
/// non-string keys, which serialize as flat alternating `[key, value, key, value]`
/// arrays rather than JSON objects.
public enum TuistGraphParser {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notAnObject
        case missingField(String)
        case unexpectedShape(String)

        public var description: String {
            switch self {
            case .notAnObject:
                "The graph is not a JSON object. Was it produced by `tuist graph --format json`?"
            case .missingField(let field):
                "The graph has no '\(field)' field. Check the Tuist version that produced it."
            case .unexpectedShape(let detail):
                "Unexpected graph shape: \(detail)"
            }
        }
    }

    public static func parse(contentsOf url: URL) throws -> TargetGraph {
        try parse(try Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> TargetGraph {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.notAnObject
        }
        return TargetGraph(
            targets: try parseTargets(root),
            dependencies: try parseDependencies(root)
        )
    }

    private static func parseTargets(_ root: [String: Any]) throws -> [TargetGraph.TargetID: TargetGraph.Target] {
        guard let projects = root["projects"] as? [Any] else {
            throw Error.missingField("projects")
        }

        var targets: [TargetGraph.TargetID: TargetGraph.Target] = [:]
        for element in projects {
            // Alternating [pathString, projectObject, …]; skip the keys.
            guard let project = element as? [String: Any] else { continue }
            guard let projectPath = project["path"] as? String else {
                throw Error.unexpectedShape("a project has no 'path'")
            }
            guard let projectTargets = project["targets"] as? [String: Any] else { continue }

            for (name, value) in projectTargets {
                guard let target = value as? [String: Any] else { continue }
                let id = TargetGraph.TargetID(project: projectPath, name: name)
                let folders = buildableFolders(in: target["buildableFolders"])
                targets[id] = TargetGraph.Target(
                    id: id,
                    productName: target["productName"] as? String ?? name,
                    product: target["product"] as? String ?? "",
                    // A buildable folder reports its current membership in resolvedFiles;
                    // the folder root additionally claims files added later.
                    sources: paths(in: target["sources"]) + folders.flatMap(\.resolvedFiles),
                    resources: paths(in: (target["resources"] as? [String: Any])?["resources"]),
                    buildableFolders: folders.map(\.folder)
                )
            }
        }
        return targets
    }

    private static func parseDependencies(
        _ root: [String: Any]
    ) throws -> [TargetGraph.TargetID: Set<TargetGraph.TargetID>] {
        guard let flattened = root["dependencies"] as? [Any] else {
            throw Error.missingField("dependencies")
        }
        guard flattened.count.isMultiple(of: 2) else {
            throw Error.unexpectedShape("'dependencies' has an odd number of elements; expected key/value pairs")
        }

        var dependencies: [TargetGraph.TargetID: Set<TargetGraph.TargetID>] = [:]
        for index in stride(from: 0, to: flattened.count, by: 2) {
            // Non-target dependencies (frameworks, packages, macros) have no target key
            // and are skipped: they cannot own a repo source file.
            guard let key = targetID(from: flattened[index]) else { continue }
            let values = flattened[index + 1] as? [Any] ?? []
            dependencies[key, default: []].formUnion(values.compactMap(targetID(from:)))
        }
        return dependencies
    }

    private static func targetID(from value: Any) -> TargetGraph.TargetID? {
        guard
            let wrapper = value as? [String: Any],
            let target = wrapper["target"] as? [String: Any],
            let name = target["name"] as? String,
            let path = target["path"] as? String
        else {
            return nil
        }
        return TargetGraph.TargetID(project: path, name: name)
    }

    private static func buildableFolders(
        in value: Any?
    ) -> [(folder: TargetGraph.BuildableFolder, resolvedFiles: [String])] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard
                let object = entry as? [String: Any],
                let root = object["path"] as? String
            else {
                return nil
            }
            // "exceptions" is itself wrapped in an object with the same key.
            let wrapper = object["exceptions"] as? [String: Any]
            let exceptions = (wrapper?["exceptions"] as? [Any]) ?? (object["exceptions"] as? [Any]) ?? []
            let excluded = exceptions.flatMap { exception -> [String] in
                guard let exception = exception as? [String: Any] else { return [] }
                return (exception["excluded"] as? [String]) ?? []
            }
            return (
                TargetGraph.BuildableFolder(root: root, excluded: Set(excluded)),
                paths(in: object["resolvedFiles"])
            )
        }
    }

    private static func paths(in value: Any?) -> [String] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry in
            if let object = entry as? [String: Any] { object["path"] as? String } else { entry as? String }
        }
    }
}
