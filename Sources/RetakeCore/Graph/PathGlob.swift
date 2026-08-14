//
//  PathGlob.swift
//  retake
//
//  Created by Natan Rolnik on 14-08-2026.
//

import Foundation

/// Matches repository-relative paths against shell-style patterns.
///
/// Deliberately lets `*` cross path separators, so `.github/**` and `.github/*` both
/// match a nested workflow file. Being strict here would make the common patterns
/// silently miss, and a missed ignore pattern widens the scope to the whole repository.
public struct PathGlob: Sendable, Hashable {
    public var pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    public func matches(_ path: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
    }

    /// - Parameters:
    ///   - path: an absolute path.
    ///   - root: the repository root the patterns are written against.
    public func matches(_ path: String, relativeTo root: String) -> Bool {
        matches(Self.relative(path, to: root))
    }

    static func relative(_ path: String, to root: String) -> String {
        let root = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}

public extension Collection<PathGlob> {
    func matchAny(_ path: String, relativeTo root: String) -> Bool {
        contains { $0.matches(path, relativeTo: root) }
    }
}
