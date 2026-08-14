//
//  MacRunner.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RetakeCore
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
            FileHandle.standardError.write(Data("retake: \(error)\n".utf8))
            exit(2)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // Accessory, not regular: no Dock icon, no menu bar, nothing to steal focus in CI.
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: options.appearance == .dark ? .darkAqua : .aqua)

            let session = PreviewRenderSession(
                options: options,
                strategy: AppKitRenderingStrategy(),
                platform: .macos
            )
            do {
                try session.run { manifest in
                    do {
                        try manifest.write(to: options.outputDirectory)
                    } catch {
                        FileHandle.standardError.write(
                            Data("retake: failed writing manifest: \(error)\n".utf8)
                        )
                        exit(3)
                    }
                    print("retake: rendered \(manifest.entries.count), failed \(manifest.failures.count)")
                    exit(manifest.failures.isEmpty ? 0 : 1)
                }
            } catch {
                FileHandle.standardError.write(Data("retake: \(error)\n".utf8))
                exit(3)
            }

            app.run()
        }
        exit(0)
    }
}

#endif
