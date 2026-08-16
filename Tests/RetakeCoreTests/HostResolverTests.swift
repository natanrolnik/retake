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

    @Test("An app hosts its own previews, not those of what it links")
    func appHostsOnlyItself() throws {
        // The app links Theme and Toss, but linking is not enough: a static framework
        // contributes only the object files something references, so a preview in a file
        // the app never touches would be dropped by the linker and never discovered. The
        // synthesised host force-loads instead.
        let assignments = try HostResolver.resolve(
            graph: sample,
            modules: ["App", "Theme", "Toss"],
            candidateHosts: ["App"]
        )

        #expect(assignments == [
            HostAssignment(host: .existingApp(id("App")), modules: ["App"]),
            HostAssignment(
                host: .synthesized(linking: [id("Theme"), id("Toss")]),
                modules: ["Theme", "Toss"]
            ),
        ])
    }

    @Test("Several apps become several passes, plus one for the frameworks")
    func severalAppsBecomeSeveralPasses() throws {
        // Previously an error. A change to a module shared by an app and a watch app is
        // ordinary, not exceptional.
        let assignments = try HostResolver.resolve(graph: sample, modules: ["App", "Watch", "Theme"])

        #expect(assignments.count == 3)
        #expect(assignments[0] == HostAssignment(host: .existingApp(id("App")), modules: ["App"]))
        #expect(assignments[1] == HostAssignment(host: .existingApp(id("Watch")), modules: ["Watch"]))
        #expect(assignments[2] == HostAssignment(
            host: .synthesized(linking: [id("Theme")]),
            modules: ["Theme"]
        ))
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

    @Test("A named host that is not in scope hosts nothing")
    func hostOutsideScopeIsNotBuilt() throws {
        let assignments = try HostResolver.resolve(
            graph: sample,
            modules: ["Theme", "Toss"],
            candidateHosts: ["Watch"]
        )

        // Nothing in scope is an app, so building Watch would be pure cost.
        #expect(assignments == [
            HostAssignment(
                host: .synthesized(linking: [id("Theme"), id("Toss")]),
                modules: ["Theme", "Toss"]
            ),
        ])
    }

    @Test("An app whose previews are in scope is hosted even beside frameworks")
    func appAndFrameworksBothRender() throws {
        let assignments = try HostResolver.resolve(
            graph: sample,
            modules: ["Theme", "Toss", "App"],
            candidateHosts: ["App"]
        )

        #expect(assignments.contains { $0.host == .existingApp(id("App")) })
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
