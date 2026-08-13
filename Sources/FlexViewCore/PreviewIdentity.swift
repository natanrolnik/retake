//
//  PreviewIdentity.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// A preview as reported by the runtime, before it has been given a stable identity.
public struct DiscoveredPreview: Codable, Hashable, Sendable {
    /// Module the preview's type belongs to. Matches the Tuist target's `productName`.
    public var module: String
    /// Mangled runtime type name. Unstable for `#Preview` macros (it encodes the source
    /// line), so it is recorded for debugging but never used as a join key for them.
    public var typeName: String
    /// `#fileID` of the macro preview: `"Module/Basename.swift"`. Nil for `PreviewProvider`.
    public var fileID: String?
    public var line: Int?
    public var displayName: String?
    /// Index within `PreviewProvider._allPreviews`. Always 0 for macro previews.
    public var previewIndex: Int

    public init(
        module: String,
        typeName: String,
        fileID: String? = nil,
        line: Int? = nil,
        displayName: String? = nil,
        previewIndex: Int = 0
    ) {
        self.module = module
        self.typeName = typeName
        self.fileID = fileID
        self.line = line
        self.displayName = displayName
        self.previewIndex = previewIndex
    }
}

/// Stable join key for matching a preview across two commits.
///
/// Deliberately excludes line numbers and mangled type names so that moving a preview
/// within a file does not read as remove + add.
public struct PreviewID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Filesystem-safe stem, used for PNG filenames and object keys.
    public var slug: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}

public enum PreviewIdentityResolver {
    public struct Result: Sendable {
        public var assignments: [(preview: DiscoveredPreview, id: PreviewID)]
        /// IDs claimed by more than one preview. A safety net rather than an expected
        /// case: in-file ordinals disambiguate the file-anchored scheme, so this only
        /// fires if the runtime reports the same type twice.
        ///
        /// It notably does *not* catch two same-basename files in one module, which
        /// report an identical `#fileID` and share one ordinal space. That is invisible
        /// at runtime; see `SourceBasenameCollision`.
        public var duplicates: [PreviewID: [DiscoveredPreview]]
    }

    /// Assigns a stable `PreviewID` to every discovered preview.
    ///
    /// Two schemes, because the runtime reports two kinds of preview:
    /// - `#Preview` macro: anchored on `fileID` + display name, disambiguated by
    ///   in-file ordinal when the name is missing or repeated.
    /// - `PreviewProvider`: anchored on the declared type name, which is genuinely stable.
    public static func resolve(_ previews: [DiscoveredPreview]) -> Result {
        var assignments: [(DiscoveredPreview, PreviewID)] = []

        let fileAnchored = previews.filter { $0.fileID != nil }
        let typeAnchored = previews.filter { $0.fileID == nil }

        for (fileID, group) in Dictionary(grouping: fileAnchored, by: { $0.fileID! }) {
            let ordered = group.sorted(by: sourceOrder)
            var nameCounts: [String: Int] = [:]
            for preview in ordered where preview.displayName != nil {
                nameCounts[preview.displayName!, default: 0] += 1
            }

            for (ordinal, preview) in ordered.enumerated() {
                let key: String
                switch preview.displayName {
                case let name? where nameCounts[name] == 1:
                    key = name
                case let name?:
                    key = "\(name)@\(ordinal)"
                case nil:
                    key = "@\(ordinal)"
                }
                assignments.append((preview, PreviewID(rawValue: "\(fileID)#\(key)")))
            }
        }

        for preview in typeAnchored {
            // typeName is already module-prefixed, e.g. "Feature.Screen_Previews".
            assignments.append((preview, PreviewID(rawValue: "\(preview.typeName)#\(preview.previewIndex)")))
        }

        assignments.sort { $0.1 < $1.1 }

        let duplicates = Dictionary(grouping: assignments, by: { $0.1 })
            .filter { $0.value.count > 1 }
            .mapValues { $0.map(\.0) }

        return Result(
            assignments: assignments.map { (preview: $0.0, id: $0.1) },
            duplicates: duplicates
        )
    }

    /// Stable ordering within a file. Line first, then tiebreakers that do not depend on
    /// discovery order (which the runtime does not guarantee).
    private static func sourceOrder(_ lhs: DiscoveredPreview, _ rhs: DiscoveredPreview) -> Bool {
        if lhs.line != rhs.line { return (lhs.line ?? .max) < (rhs.line ?? .max) }
        if lhs.previewIndex != rhs.previewIndex { return lhs.previewIndex < rhs.previewIndex }
        return lhs.typeName < rhs.typeName
    }
}

/// `#fileID` carries only a basename, so two files sharing a basename inside one module
/// are indistinguishable at runtime. Xcode targets permit that, so detect it from the
/// build graph's source list instead and warn before the IDs silently collide.
public enum SourceBasenameCollision {
    public struct Collision: Hashable, Sendable {
        public var module: String
        public var basename: String
        public var paths: [String]
    }

    public static func detect(sourcesByModule: [String: [String]]) -> [Collision] {
        sourcesByModule.flatMap { module, paths -> [Collision] in
            Dictionary(grouping: paths, by: { ($0 as NSString).lastPathComponent })
                .filter { $0.value.count > 1 }
                .map { Collision(module: module, basename: $0.key, paths: $0.value.sorted()) }
        }
        .sorted { ($0.module, $0.basename) < ($1.module, $1.basename) }
    }
}
