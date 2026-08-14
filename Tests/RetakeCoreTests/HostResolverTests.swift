//
//  HostResolverTests.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Testing
@testable import RetakeCore

private func id(_ name: String) -> TargetGraph.TargetID {
    TargetGraph.TargetID(project: "/repo", name: name)
}

private func target(_ name: String, product: String, productName: String? = nil) -> TargetGraph.Target {
    TargetGraph.Target(
        id: id(name),
        productName: productName ?? name,
        product: product,
        sources: ["/repo/\(name)/File.swift"],
        resources: []
    )
}

/// Theme is shared by three apps, one of which is a per-module preview app. That shape
/// is what makes host selection interesting.
private let sample = TargetGraph(
    targets: Dictionary(uniqueKeysWithValues: [
        target("Theme", product: "staticFramework"),
        target("Toss", product: "staticFramework"),
        target("App", product: "app"),
        target("Watch", product: "app"),
        target("ThemePreview", product: "app"),
        target("AppTests", product: "unitTests"),
    ].map { ($0.id, $0) }),
    dependencies: [
        id("App"): [id("Theme"), id("Toss")],
        id("Watch"): [id("Theme")],
        id("ThemePreview"): [id("Theme")],
    ]
)

@Suite("Host resolution")
struct HostResolverTests {
    @Test("A framework with no app to host it gets a synthesised one")
    func frameworksSynthesiseAHost() throws {
        let graph = TargetGraph(
            targets: Dictionary(uniqueKeysWithValues: [
                target("Theme", product: "staticFramework"),
            ].map { ($0.id, $0) }),
            dependencies: [:]
        )
        let assignments = try HostResolver.resolve(graph: graph, modules: ["Theme"])

        #expect(assignments == [
            HostAssignment(host: .synthesized(linking: [id("Theme")]), modules: ["Theme"]),
        ])
    }

    @Test("An app in scope hosts itself and what it links")
    func appHostsWhatItLinks() throws {
        let assignments = try HostResolver.resolve(
            graph: sample,
            modules: ["App", "Theme", "Toss"],
            candidateHosts: ["App"]
        )

        #expect(assignments == [
            HostAssignment(host: .existingApp(id("App")), modules: ["App", "Theme", "Toss"]),
        ])
    }

    @Test("Several apps become several passes, each with its own modules")
    func severalAppsBecomeSeveralPasses() throws {
        // Previously an error. A change to a module shared by an app and a watch app is
        // ordinary, not exceptional.
        let assignments = try HostResolver.resolve(graph: sample, modules: ["App", "Watch", "Theme"])

        #expect(assignments.count == 2)
        #expect(assignments[0] == HostAssignment(host: .existingApp(id("App")), modules: ["App", "Theme"]))
        // Theme is claimed by App, so Watch renders only its own previews.
        #expect(assignments[1] == HostAssignment(host: .existingApp(id("Watch")), modules: ["Watch"]))
    }

    @Test("A shared module is rendered exactly once")
    func sharedModuleRenderedOnce() throws {
        let assignments = try HostResolver.resolve(graph: sample, modules: [])
        let rendered = assignments.flatMap(\.modules)

        #expect(rendered.count == Set(rendered).count)
        #expect(!rendered.contains("AppTests"))
    }

    @Test("Naming the hosts keeps preview apps out of the render")
    func candidateHostsExcludePreviewApps() throws {
        // The point of the option: ThemePreview exists to look at Theme by hand, and
        // rendering Theme inside it as well would be pure cost.
        let assignments = try HostResolver.resolve(
            graph: sample,
            modules: ["Theme", "App", "Watch", "ThemePreview"],
            candidateHosts: ["App"]
        )

        #expect(assignments.contains { $0.host == .existingApp(id("App")) })
        #expect(!assignments.contains { $0.host == .existingApp(id("ThemePreview")) })
        // Watch is an app, so it cannot be linked into the synthesised host either.
        #expect(assignments.allSatisfy { !$0.modules.contains("Watch") })
    }

    @Test("Modules no chosen host links still get rendered")
    func orphansGetASynthesisedHost() throws {
        let assignments = try HostResolver.resolve(
            graph: sample,
            modules: ["Theme", "Toss", "App"],
            candidateHosts: ["Watch"]
        )

        // Watch links only Theme, so Toss and App need somewhere else to go.
        #expect(assignments.contains { $0.host == .existingApp(id("Watch")) })
        #expect(assignments.contains { assignment in
            if case .synthesized = assignment.host { return assignment.modules.contains("Toss") }
            return false
        })
    }

    @Test("Assignment does not depend on the order modules arrive in")
    func stableAcrossOrdering() throws {
        let forward = try HostResolver.resolve(graph: sample, modules: ["Theme", "App", "Watch"])
        let reversed = try HostResolver.resolve(graph: sample, modules: ["Watch", "App", "Theme"])

        #expect(forward == reversed)
    }

    @Test("An unknown host is rejected instead of silently ignored")
    func unknownHost() {
        #expect(throws: HostResolver.Error.unknownHost("Nope")) {
            try HostResolver.resolve(graph: sample, modules: [], candidateHosts: ["Nope"])
        }
        // A framework is not an app and cannot host anything.
        #expect(throws: HostResolver.Error.unknownHost("Theme")) {
            try HostResolver.resolve(graph: sample, modules: [], candidateHosts: ["Theme"])
        }
    }

    @Test("An empty scope has nothing to host")
    func emptyScope() {
        #expect(throws: HostResolver.Error.noTargetsInScope) {
            try HostResolver.resolve(graph: sample, modules: ["DoesNotExist"])
        }
    }
}
