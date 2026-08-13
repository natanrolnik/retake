//
//  PreviewRenderSession.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import CryptoKit
import FlexViewCore
import Foundation
import SnapshotPreviewsCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Discovers every preview linked into the running binary, renders them one at a time,
/// and writes PNGs plus a manifest.
///
/// Shared by both platforms: macOS drives it from an accessory app, iOS from an XCTest
/// case in the simulator. Only the rendering strategy differs.
@MainActor
public final class PreviewRenderSession {
    private let options: RunnerOptions
    private let strategy: RenderingStrategy
    private let platform: RenderPlatform
    private let simulator: String?

    private var queue: [Item] = []
    private var entries: [ManifestEntry] = []
    private var failures: [ManifestFailure] = []
    private var completion: ((Manifest) -> Void)?

    private struct Item {
        var preview: DiscoveredPreview
        var id: PreviewID
        var source: SnapshotPreviewsCore.Preview
    }

    public init(
        options: RunnerOptions,
        strategy: RenderingStrategy,
        platform: RenderPlatform,
        simulator: String? = nil
    ) {
        self.options = options
        self.strategy = strategy
        self.platform = platform
        self.simulator = simulator
    }

    /// - Throws: if the output directory cannot be created. Per-preview failures are
    ///   collected into the manifest instead of thrown.
    public func run(completion: @escaping (Manifest) -> Void) throws {
        self.completion = completion

        try FileManager.default.createDirectory(
            at: options.outputDirectory,
            withIntermediateDirectories: true
        )

        let types = FindPreviews.findPreviews(
            included: nil,
            excluded: nil,
            includedModules: options.modules
        )

        var sources: [DiscoveredPreview: SnapshotPreviewsCore.Preview] = [:]
        var discovered: [DiscoveredPreview] = []
        for type in types {
            for (index, preview) in type.previews.enumerated() {
                let record = DiscoveredPreview(
                    module: type.module,
                    typeName: type.typeName,
                    fileID: type.fileID,
                    line: type.line,
                    displayName: preview.displayName,
                    previewIndex: index
                )
                discovered.append(record)
                sources[record] = preview
            }
        }

        let resolved = PreviewIdentityResolver.resolve(discovered)
        for (id, colliding) in resolved.duplicates {
            let files = colliding.map { $0.fileID ?? $0.typeName }.joined(separator: ", ")
            warn("\(colliding.count) previews share the id '\(id)' (\(files)); only the first is rendered.")
        }

        var claimed: Set<PreviewID> = []
        queue = resolved.assignments.compactMap { assignment in
            guard claimed.insert(assignment.id).inserted else { return nil }
            return sources[assignment.preview].map {
                Item(preview: assignment.preview, id: assignment.id, source: $0)
            }
        }

        print("flexview: rendering \(queue.count) previews")
        renderNext()
    }

    private func renderNext() {
        guard let next = queue.first else {
            finish()
            return
        }
        queue.removeFirst()

        strategy.render(preview: next.source) { [weak self] result in
            MainActor.assumeIsolated {
                self?.record(result: result, for: next)
                self?.renderNext()
            }
        }
    }

    private func record(result: SnapshotResult, for item: Item) {
        switch result.image {
        case .success(let image):
            guard let png = image.flexviewPNGData() else {
                appendFailure(item, message: "rendered image could not be encoded as PNG")
                return
            }
            let fileName = "\(item.id.slug).png"
            do {
                try png.write(to: options.outputDirectory.appendingPathComponent(fileName))
            } catch {
                appendFailure(item, message: "could not write PNG: \(error)")
                return
            }
            entries.append(ManifestEntry(
                previewID: item.id,
                module: item.preview.module,
                sourceFile: item.preview.fileID,
                line: item.preview.line,
                displayName: item.preview.displayName,
                typeName: item.preview.typeName,
                pngPath: fileName,
                sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                width: image.size.width,
                height: image.size.height
            ))
        case .failure(let error):
            appendFailure(item, message: "\(error)")
        }
    }

    private func appendFailure(_ item: Item, message: String) {
        failures.append(ManifestFailure(
            previewID: item.id,
            module: item.preview.module,
            sourceFile: item.preview.fileID,
            displayName: item.preview.displayName,
            message: message
        ))
    }

    private func finish() {
        completion?(Manifest(
            configuration: RenderConfiguration(
                platform: platform,
                appearance: options.appearance,
                simulator: simulator
            ),
            entries: entries,
            failures: failures
        ))
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("flexview: warning: \(message)\n".utf8))
    }
}

#if canImport(UIKit)
extension UIImage {
    func flexviewPNGData() -> Data? { pngData() }
}
#elseif canImport(AppKit)
extension NSImage {
    func flexviewPNGData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
