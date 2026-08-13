//
//  MacRunner.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import CryptoKit
import FlexViewCore
import Foundation
import SnapshotPreviewsCore

/// Renders every `#Preview` linked into this binary, on the macOS host: no simulator,
/// no XCTest. The host repo's runner target links its modules plus this library and
/// calls `MacRunner.main()`.
public enum MacRunner {
    /// Call from the runner target's `main.swift`. Deliberately nonisolated so it works
    /// from top-level code in either Swift language mode; it asserts main-thread
    /// isolation internally, which top-level code always satisfies.
    public static func main() -> Never {
        let options: RunnerOptions
        do {
            options = try RunnerOptions.fromEnvironment()
        } catch {
            FileHandle.standardError.write(Data("flexview: \(error)\n".utf8))
            exit(2)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // Accessory, not regular: no Dock icon, no menu bar, nothing to steal focus in CI.
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: options.appearance == .dark ? .darkAqua : .aqua)

            let session = RenderSession(options: options)
            session.start { manifest in
                do {
                    try manifest.write(to: options.outputDirectory)
                } catch {
                    FileHandle.standardError.write(Data("flexview: failed writing manifest: \(error)\n".utf8))
                    exit(3)
                }
                print("flexview: rendered \(manifest.entries.count), failed \(manifest.failures.count)")
                exit(manifest.failures.isEmpty ? 0 : 1)
            }

            app.run()
        }
        exit(0)
    }
}

@MainActor
private final class RenderSession {
    private let options: RunnerOptions
    private let strategy = AppKitRenderingStrategy()
    private var queue: [(preview: DiscoveredPreview, id: PreviewID, source: SnapshotPreviewsCore.Preview)] = []
    private var entries: [ManifestEntry] = []
    private var failures: [ManifestFailure] = []
    private var completion: ((Manifest) -> Void)?

    init(options: RunnerOptions) {
        self.options = options
    }

    func start(completion: @escaping (Manifest) -> Void) {
        self.completion = completion

        do {
            try FileManager.default.createDirectory(
                at: options.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(Data("flexview: cannot create output directory: \(error)\n".utf8))
            exit(3)
        }

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
            let warning = "flexview: warning: \(colliding.count) previews share the id '\(id)' (\(files)); "
                + "only the first is rendered.\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }

        var claimed: Set<PreviewID> = []
        queue = resolved.assignments.compactMap { assignment in
            guard claimed.insert(assignment.id).inserted else { return nil }
            return sources[assignment.preview].map { (assignment.preview, assignment.id, $0) }
        }
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

    private func record(
        result: SnapshotResult,
        for item: (preview: DiscoveredPreview, id: PreviewID, source: SnapshotPreviewsCore.Preview)
    ) {
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

    private func appendFailure(
        _ item: (preview: DiscoveredPreview, id: PreviewID, source: SnapshotPreviewsCore.Preview),
        message: String
    ) {
        failures.append(ManifestFailure(
            previewID: item.id,
            module: item.preview.module,
            sourceFile: item.preview.fileID,
            displayName: item.preview.displayName,
            message: message
        ))
    }

    private func finish() {
        let manifest = Manifest(
            configuration: RenderConfiguration(platform: .macos, appearance: options.appearance),
            entries: entries,
            failures: failures
        )
        completion?(manifest)
    }
}

private extension NSImage {
    func flexviewPNGData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}

#endif
