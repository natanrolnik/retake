//
//  RetakeSnapshotTests.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

#if canImport(UIKit)

import RetakeCore
import RetakeRuntime
import SnapshotPreviewsCore
import UIKit
import XCTest

/// Renders every preview linked into the test bundle from inside the simulator.
///
/// iOS has no host-side renderer, so the runner is an XCTest target rather than an app.
/// Subclass it in the host repo and the inherited test method does the work:
///
/// ```swift
/// import RetakeTestRuntime
/// final class PreviewSnapshots: RetakeSnapshotTests {}
/// ```
///
/// The output directory comes from `RETAKE_OUT` and is a **host** path, not a path
/// inside the simulator's container. `retake render` forwards it as
/// `TEST_RUNNER_RETAKE_OUT`, which xcodebuild passes to the test process.
open class RetakeSnapshotTests: XCTestCase {
    /// The base class is a template, not a test. Without this it would also be
    /// discovered and run, rendering everything twice.
    override open class var defaultTestSuite: XCTestSuite {
        guard self != RetakeSnapshotTests.self else {
            return XCTestSuite(name: "RetakeSnapshotTests (abstract)")
        }
        return super.defaultTestSuite
    }

    /// Seconds to allow for the whole render pass.
    open var renderTimeout: TimeInterval { 600 }

    /// Override to render on something other than the UIKit strategy.
    @MainActor
    open func makeRenderingStrategy(settle: Bool) -> RenderingStrategy {
        settle ? SettlingRenderingStrategy() : UIKitRenderingStrategy()
    }

    /// Errors, not XCTAssert: the global assertion functions are unavailable to a
    /// framework target, and a thrown error already fails the test.
    public enum Failure: Error, CustomStringConvertible {
        case noManifest
        case noPreviews

        public var description: String {
            switch self {
            case .noManifest: "The render pass produced no manifest."
            case .noPreviews: "No previews were rendered. Does the test target link the modules?"
            }
        }
    }

    @MainActor
    public func testRenderPreviews() throws {
        let options: RunnerOptions
        do {
            options = try RunnerOptions.fromEnvironment()
        } catch {
            // A missing RETAKE_OUT means this ran as an ordinary test rather than
            // through `retake render`, so there is nothing to do.
            print("retake: skipping, \(error)")
            return
        }

        overrideAppearance(options.appearance)

        let session = PreviewRenderSession(
            options: options,
            strategy: makeRenderingStrategy(settle: options.settle),
            platform: .ios,
            simulator: Self.currentSimulatorDescription()
        )

        let finished = expectation(description: "previews rendered")
        var rendered: Manifest?
        try session.run { manifest in
            rendered = manifest
            finished.fulfill()
        }
        wait(for: [finished], timeout: renderTimeout)

        guard let manifest = rendered else { throw Failure.noManifest }
        try manifest.write(to: options.outputDirectory)

        // Reported, not fatal: a manifest listing failures is more useful than none, and
        // `retake diff` keeps them out of the removed bucket.
        for failure in manifest.failures {
            print("retake: failed to render \(failure.previewID): \(failure.message)")
        }
        guard !manifest.entries.isEmpty else { throw Failure.noPreviews }
    }

    /// Forces the appearance rather than inheriting whatever the simulator was left in.
    @MainActor
    private func overrideAppearance(_ appearance: Appearance) {
        let style: UIUserInterfaceStyle = appearance == .dark ? .dark : .light
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private static func currentSimulatorDescription() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SIMULATOR_DEVICE_NAME"] else { return nil }
        guard let version = environment["SIMULATOR_RUNTIME_VERSION"] else { return name }
        return "\(name), \(version)"
    }
}

#endif
