//
//  SettlingRenderingStrategy.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

#if canImport(UIKit) && !os(watchOS) && !os(tvOS) && !os(visionOS)

import SnapshotPreviewsCore
import SwiftUI
import UIKit

/// Captures a preview only after giving asynchronously loaded content time to arrive.
///
/// The default UIKit strategy snapshots as soon as layout settles, which is fine for
/// static SwiftUI and wrong for anything that fills in later: a RealityKit scene, a
/// `.task` load, a decoded image. Those previews render two different pictures on the
/// same commit, so a diff reports changes nobody made.
///
/// This is opt-in because it costs about two seconds per preview.
public final class SettlingRenderingStrategy: RenderingStrategy {
    private let window: UIWindow

    public init() {
        // Same window setup the default strategy uses: on top of everything, key and
        // visible, so the render target is actually on screen.
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.first

        window = (scene as? UIWindowScene).map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
    }

    @MainActor
    public func render(
        preview: SnapshotPreviewsCore.Preview,
        completion: @escaping (SnapshotResult) -> Void
    ) {
        let view = AnyView(preview.view())
        let controller = view.makeExpandingView(layout: preview.layout, window: window)
        // async: true is the library's settle path, which waits after layout before
        // capturing. The default strategy hardcodes false.
        view.snapshot(
            layout: preview.layout,
            controller: controller,
            window: window,
            async: true,
            completion: completion
        )
    }
}

#endif
