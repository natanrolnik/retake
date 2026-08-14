//
//  SwiftPackage.swift
//  retake
//
//  Created by Natan Rolnik on 14-08-2026.
//

import Foundation

/// A local Swift package, read from its own manifest.
///
/// Lets retake work in a repository that does not use Tuist at all. A package describes
/// itself well enough to host its previews: the products name the modules, and the
/// directory is all Tuist needs to depend on it from a generated project.
struct SwiftPackage {
    var directory: URL
    var name: String
    /// Library products, which are the modules previews report themselves as.
    var products: [String]

    enum Error: Swift.Error, CustomStringConvertible {
        case notAPackage(URL)
        case unreadableManifest(URL, String)

        var description: String {
            switch self {
            case .notAPackage(let url):
                "No Package.swift in \(url.path)."
            case .unreadableManifest(let url, let detail):
                "Could not read the package manifest in \(url.path): \(detail)"
            }
        }
    }

    static func load(at path: String, swift: String = "/usr/bin/swift") throws -> SwiftPackage {
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path
        ) else {
            throw Error.notAPackage(directory)
        }

        let result = try Shell.run(swift, ["package", "dump-package", "--package-path", directory.path])
        guard result.succeeded else {
            throw Error.unreadableManifest(directory, result.standardError)
        }

        guard
            let data = result.standardOutput.data(using: .utf8),
            let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = manifest["name"] as? String
        else {
            throw Error.unreadableManifest(directory, "the manifest dump was not JSON")
        }

        // Library products only: an executable cannot be linked into a host app, and a
        // plugin or test target has no previews worth rendering.
        let products = ((manifest["products"] as? [[String: Any]]) ?? [])
            .filter { ($0["type"] as? [String: Any])?["library"] != nil }
            .compactMap { $0["name"] as? String }

        return SwiftPackage(
            directory: directory,
            name: name,
            products: products.isEmpty ? [name] : products
        )
    }
}
