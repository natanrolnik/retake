//
//  PreviewIdentityTests.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Testing
@testable import FlexViewCore

private func macroPreview(
    module: String = "DesignSystem",
    file: String = "Widget.swift",
    line: Int,
    displayName: String? = nil,
    mangledSuffix: String = "a"
) -> DiscoveredPreview {
    DiscoveredPreview(
        module: module,
        typeName: "\(module).$s_MX\(line - 1)_\(mangledSuffix)",
        fileID: "\(module)/\(file)",
        line: line,
        displayName: displayName
    )
}

@Suite("Preview identity")
struct PreviewIdentityTests {
    @Test("A named macro preview keeps its id when its line shifts")
    func namedPreviewSurvivesLineShift() {
        let before = PreviewIdentityResolver.resolve([macroPreview(line: 10, displayName: "Primary")])
        // Same preview, two lines added above it: line and mangled type name both move.
        let after = PreviewIdentityResolver.resolve([
            macroPreview(line: 12, displayName: "Primary", mangledSuffix: "b")
        ])

        #expect(before.assignments[0].id == after.assignments[0].id)
        #expect(before.assignments[0].id.rawValue == "DesignSystem/Widget.swift#Primary")
    }

    @Test("Unnamed previews fall back to an in-file ordinal")
    func unnamedPreviewsUseOrdinals() {
        let resolved = PreviewIdentityResolver.resolve([
            macroPreview(line: 20),
            macroPreview(line: 10),
        ])

        #expect(resolved.assignments.map(\.id.rawValue) == [
            "DesignSystem/Widget.swift#@0",
            "DesignSystem/Widget.swift#@1",
        ])
        // Ordinal follows source order, not discovery order.
        #expect(resolved.assignments.first { $0.id.rawValue.hasSuffix("@0") }?.preview.line == 10)
    }

    @Test("Display names repeated within one file are disambiguated by ordinal")
    func duplicateNamesWithinFile() {
        let resolved = PreviewIdentityResolver.resolve([
            macroPreview(line: 10, displayName: "Primary"),
            macroPreview(line: 30, displayName: "Primary"),
        ])

        #expect(resolved.assignments.map(\.id.rawValue).sorted() == [
            "DesignSystem/Widget.swift#Primary@0",
            "DesignSystem/Widget.swift#Primary@1",
        ])
        #expect(resolved.duplicates.isEmpty)
    }

    @Test("The same display name in two files does not collide")
    func sameNameDifferentFiles() {
        let resolved = PreviewIdentityResolver.resolve([
            macroPreview(file: "Widget.swift", line: 10, displayName: "Primary"),
            macroPreview(file: "Card.swift", line: 10, displayName: "Primary"),
        ])

        #expect(Set(resolved.assignments.map(\.id)).count == 2)
        #expect(resolved.duplicates.isEmpty)
    }

    @Test("PreviewProvider previews are keyed on the declared type name")
    func previewProviderIdentity() {
        let resolved = PreviewIdentityResolver.resolve([
            DiscoveredPreview(module: "Feature", typeName: "Feature.Screen_Previews", previewIndex: 0),
            DiscoveredPreview(module: "Feature", typeName: "Feature.Screen_Previews", previewIndex: 1),
        ])

        #expect(resolved.assignments.map(\.id.rawValue) == [
            "Feature.Screen_Previews#0",
            "Feature.Screen_Previews#1",
        ])
    }

    @Test("Same-basename files share an ordinal namespace, which only the graph can catch")
    func basenameCollisionInterleavesOrdinals() {
        // Two files both named Widget.swift in one module report the identical #fileID,
        // so their previews land in one ordinal space. Nothing here is detectably wrong:
        // the ids stay unique, but an unnamed preview's ordinal now depends on a file it
        // has never heard of. Only SourceBasenameCollision, working from the build graph,
        // can see this — hence the warning lives there and not in the resolver.
        let together = PreviewIdentityResolver.resolve([
            macroPreview(line: 10),  // Buttons/Widget.swift
            macroPreview(line: 20),  // Cards/Widget.swift
        ])
        #expect(Set(together.assignments.map(\.id)).count == 2)
        #expect(together.duplicates.isEmpty)

        // Delete the preview at line 10 and the surviving one silently changes identity.
        let alone = PreviewIdentityResolver.resolve([macroPreview(line: 20)])
        #expect(together.assignments.last?.id.rawValue == "DesignSystem/Widget.swift#@1")
        #expect(alone.assignments[0].id.rawValue == "DesignSystem/Widget.swift#@0")
    }

    @Test("Duplicate ids are reported rather than silently merged")
    func duplicateTypeAnchoredIdsAreReported() {
        let resolved = PreviewIdentityResolver.resolve([
            DiscoveredPreview(module: "Feature", typeName: "Feature.Screen_Previews", previewIndex: 0),
            DiscoveredPreview(module: "Feature", typeName: "Feature.Screen_Previews", previewIndex: 0),
        ])

        #expect(resolved.duplicates.count == 1)
        #expect(resolved.duplicates.values.first?.count == 2)
    }

    @Test("Resolution is stable regardless of input order")
    func orderIndependence() {
        let previews = [
            macroPreview(line: 30),
            macroPreview(file: "Card.swift", line: 5, displayName: "Card"),
            macroPreview(line: 10, displayName: "Primary"),
        ]

        let forward = PreviewIdentityResolver.resolve(previews).assignments.map(\.id)
        let reversed = PreviewIdentityResolver.resolve(previews.reversed()).assignments.map(\.id)
        #expect(forward == reversed)
    }

    @Test("Slugs are filesystem safe")
    func slug() {
        let id = PreviewID(rawValue: "DesignSystem/Widget.swift#Primary Button")
        #expect(id.slug == "DesignSystem-Widget.swift-Primary-Button")
    }
}

@Suite("Source basename collisions")
struct SourceBasenameCollisionTests {
    @Test("Two files sharing a basename in one module are flagged")
    func detectsCollision() {
        let collisions = SourceBasenameCollision.detect(sourcesByModule: [
            "DesignSystem": [
                "/repo/Sources/DesignSystem/Buttons/Widget.swift",
                "/repo/Sources/DesignSystem/Cards/Widget.swift",
                "/repo/Sources/DesignSystem/Card.swift",
            ],
        ])

        #expect(collisions.count == 1)
        #expect(collisions[0].basename == "Widget.swift")
        #expect(collisions[0].paths.count == 2)
    }

    @Test("The same basename in different modules is fine")
    func differentModulesDoNotCollide() {
        let collisions = SourceBasenameCollision.detect(sourcesByModule: [
            "DesignSystem": ["/repo/DesignSystem/Widget.swift"],
            "Feature": ["/repo/Feature/Widget.swift"],
        ])

        #expect(collisions.isEmpty)
    }
}
