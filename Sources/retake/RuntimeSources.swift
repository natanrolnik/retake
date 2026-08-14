//
//  RuntimeSources.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Locates the sources the generated host project compiles.
///
/// The runtime is compiled from source rather than pulled in as a Swift package, so the
/// host repository's dependency graph is never touched. Adding a package to an existing
/// Tuist graph can collide with settings it already applies to every target, which is
/// exactly the failure this avoids.
struct RuntimeSources {
    var retake: URL
    var snapshotPreviews: URL

    enum Error: Swift.Error, CustomStringConvertible {
        case retakeSourcesNotFound(URL)
        case snapshotPreviewsNotFound(searched: [URL])

        var description: String {
            switch self {
            case .retakeSourcesNotFound(let url):
                """
                Could not find retake's own sources at \(url.path).
                Pass --runtime-sources <path to the retake checkout>.
                """
            case .snapshotPreviewsNotFound(let searched):
                """
                Could not find the SnapshotPreviews checkout. Looked in:
                \(searched.map { "  \($0.path)" }.joined(separator: "\n"))
                Run `swift build` in the retake checkout to resolve it, \
                or pass --snapshot-previews <path>.
                """
            }
        }
    }

    /// - Parameters:
    ///   - retakeRoot: explicit override, otherwise derived from this file's compile
    ///     time path, which is correct whenever retake was built from its checkout.
    static func resolve(retakeRoot: String?, snapshotPreviewsRoot: String?) throws -> RuntimeSources {
        let retake = retakeRoot.map { URL(fileURLWithPath: $0) } ?? Self.defaultFlexviewRoot()
        guard FileManager.default.fileExists(
            atPath: retake.appendingPathComponent("Sources/RetakeTestRuntime").path
        ) else {
            throw Error.retakeSourcesNotFound(retake)
        }

        if let snapshotPreviewsRoot {
            return RuntimeSources(retake: retake, snapshotPreviews: URL(fileURLWithPath: snapshotPreviewsRoot))
        }

        let candidates = [
            retake.appendingPathComponent(".build/checkouts/SnapshotPreviews-iOS"),
            retake.appendingPathComponent(".build/checkouts/snapshotpreviews-ios"),
        ]
        guard let found = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sources").path)
        }) else {
            throw Error.snapshotPreviewsNotFound(searched: candidates)
        }
        return RuntimeSources(retake: retake, snapshotPreviews: found)
    }

    /// This file lives at <root>/Sources/retake/RuntimeSources.swift.
    private static func defaultFlexviewRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
