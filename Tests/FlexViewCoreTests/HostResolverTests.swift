//
//  HostResolverTests.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Testing
@testable import FlexViewCore

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

private func graph(_ targets: [TargetGraph.Target]) -> TargetGraph {
    TargetGraph(
        targets: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) }),
        dependencies: [:]
    )
}

private let sample = graph([
    target("DesignSystem", product: "staticFramework"),
    target("Feature", product: "staticFramework", productName: "FeatureKit"),
    target("App", product: "app"),
    target("AppTests", product: "unitTests"),
])

@Suite("Host resolution")
struct HostResolverTests {
    @Test("A framework-only change synthesizes a host linking those frameworks")
    func frameworksSynthesizeAHost() throws {
        let host = try HostResolver.resolve(graph: sample, modules: ["DesignSystem", "FeatureKit"])

        #expect(host == .synthesized(linking: [id("DesignSystem"), id("Feature")]))
    }

    @Test("An app in scope hosts the previews itself")
    func appInScopeBecomesTheHost() throws {
        // One app cannot link another, so an app's own previews are only reachable
        // from inside it.
        let host = try HostResolver.resolve(graph: sample, modules: ["App", "DesignSystem"])

        #expect(host == .existingApp(id("App")))
    }

    @Test("Test bundles are never linked into a synthesized host")
    func testBundlesExcluded() throws {
        let host = try HostResolver.resolve(graph: sample, modules: ["DesignSystem", "AppTests"])

        #expect(host == .synthesized(linking: [id("DesignSystem")]))
    }

    @Test("An explicit host wins over the rule")
    func explicitHost() throws {
        let host = try HostResolver.resolve(
            graph: sample,
            modules: ["DesignSystem"],
            explicitHost: "App"
        )

        #expect(host == .existingApp(id("App")))
    }

    @Test("Two apps in scope is an error rather than an arbitrary pick")
    func severalAppsIsAnError() {
        let twoApps = graph([
            target("App", product: "app"),
            target("Watch", product: "app"),
        ])

        #expect(throws: HostResolver.Error.severalApps(["App", "Watch"])) {
            try HostResolver.resolve(graph: twoApps, modules: ["App", "Watch"])
        }
    }

    @Test("An unknown --host is rejected instead of silently ignored")
    func unknownHost() {
        #expect(throws: HostResolver.Error.unknownHost("Nope")) {
            try HostResolver.resolve(graph: sample, modules: [], explicitHost: "Nope")
        }
    }

    @Test("An empty scope has nothing to host")
    func emptyScope() {
        #expect(throws: HostResolver.Error.noTargetsInScope) {
            try HostResolver.resolve(graph: sample, modules: ["DoesNotExist"])
        }
    }
}
