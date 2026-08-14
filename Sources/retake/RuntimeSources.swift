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
///
/// A released binary is therefore not enough on its own: it ships these sources beside
/// itself and finds them relative to the executable.
struct RuntimeSources {
    var retake: URL
    var snapshotPreviews: URL

    enum Error: Swift.Error, CustomStringConvertible {
        case notFound([URL])

        var description: String {
            guard case .notFound(let searched) = self else { return "" }
            return """
            Could not find the runtime sources retake compiles into the generated host \
            project. Looked in:
            \(searched.map { "  \($0.path)" }.joined(separator: "\n"))
            Pass --runtime-sources <a retake checkout, or the runtime directory shipped \
            beside the binary>.
            """
        }
    }

    /// - Parameter retakeRoot: explicit override. Otherwise the layout shipped beside the
    ///   executable is tried first, then this file's compile time path, which is correct
    ///   whenever retake was built from its own checkout.
    static func resolve(retakeRoot: String?, snapshotPreviewsRoot: String?) throws -> RuntimeSources {
        var searched: [URL] = []

        for candidate in candidates(explicit: retakeRoot) {
            searched.append(candidate.retake)
            guard exists(candidate.retake.appendingPathComponent("Sources/RetakeTestRuntime")) else {
                continue
            }
            let previews = snapshotPreviewsRoot.map { URL(fileURLWithPath: $0) } ?? candidate.snapshotPreviews
            guard exists(previews.appendingPathComponent("Sources/SnapshotPreviewsCore")) else {
                searched.append(previews)
                continue
            }
            return RuntimeSources(retake: candidate.retake, snapshotPreviews: previews)
        }

        throw Error.notFound(searched)
    }

    private static func candidates(explicit: String?) -> [(retake: URL, snapshotPreviews: URL)] {
        var result: [(URL, URL)] = []

        if let explicit {
            let root = URL(fileURLWithPath: explicit)
            result.append((root, root.appendingPathComponent(".build/checkouts/SnapshotPreviews-iOS")))
            // The release layout, where the two sit side by side.
            result.append((root.appendingPathComponent("retake"), root.appendingPathComponent("snapshot-previews")))
        }

        // Shipped beside the binary: <prefix>/bin/retake, with <prefix>/runtime alongside.
        let runtime = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("runtime")
        result.append((runtime.appendingPathComponent("retake"), runtime.appendingPathComponent("snapshot-previews")))

        // Built from a checkout: this file is <root>/Sources/retake/RuntimeSources.swift.
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        result.append((development, development.appendingPathComponent(".build/checkouts/SnapshotPreviews-iOS")))

        return result.map { (retake: $0.0, snapshotPreviews: $0.1) }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
