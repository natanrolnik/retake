//
//  PreviewRenderSession.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import CryptoKit
import RetakeCore
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
    /// Previews to skip, because a previous attempt died rendering them.
    private let skipped: Set<PreviewID>

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
        self.skipped = Set(options.skip.map(PreviewID.init(rawValue:)))
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
            guard !skipped.contains(assignment.id) else {
                failures.append(ManifestFailure(
                    previewID: assignment.id,
                    module: assignment.preview.module,
                    sourceFile: assignment.preview.fileID,
                    displayName: assignment.preview.displayName,
                    message: "skipped: rendering it crashed the runner"
                ))
                return nil
            }
            return sources[assignment.preview].map {
                Item(preview: assignment.preview, id: assignment.id, source: $0)
            }
        }

        print("retake: rendering \(queue.count) previews")
        renderNext()
    }

    private func renderNext() {
        guard let next = queue.first else {
            try? FileManager.default.removeItem(at: inFlightURL)
            finish()
            return
        }
        queue.removeFirst()

        // Rendering runs arbitrary view code in this process, and some of it crashes:
        // a corrupt image, an unavailable service. Recording what is in flight, and
        // saving progress after each one, means a crash costs one preview rather than
        // the whole pass, and the caller can name the preview that did it.
        try? Data(next.id.rawValue.utf8).write(to: inFlightURL)

        strategy.render(preview: next.source) { [weak self] result in
            MainActor.assumeIsolated {
                self?.record(result: result, for: next)
                self?.saveProgress()
                self?.renderNext()
            }
        }
    }

    private func record(result: SnapshotResult, for item: Item) {
        switch result.image {
        case .success(let image):
            guard let png = image.retakePNGData() else {
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

    private var inFlightURL: URL {
        options.outputDirectory.appendingPathComponent("in-flight.txt")
    }

    /// Written after every preview, so a crash leaves everything rendered so far.
    private func saveProgress() {
        try? currentManifest().write(to: options.outputDirectory)
    }

    private func currentManifest() -> Manifest {
        Manifest(
            configuration: RenderConfiguration(
                platform: platform,
                appearance: options.appearance,
                simulator: simulator
            ),
            entries: entries,
            failures: failures
        )
    }

    private func finish() {
        completion?(currentManifest())
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("retake: warning: \(message)\n".utf8))
    }
}

#if canImport(UIKit)
extension UIImage {
    func retakePNGData() -> Data? { pngData() }
}
#elseif canImport(AppKit)
extension NSImage {
    func retakePNGData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
