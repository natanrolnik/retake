//
//  ManifestJoinTests.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Testing
@testable import FlexViewCore

private func entry(_ id: String, sha: String, module: String = "DesignSystem") -> ManifestEntry {
    ManifestEntry(
        previewID: PreviewID(rawValue: id),
        module: module,
        sourceFile: "\(module)/Widget.swift",
        line: 10,
        displayName: "Primary",
        typeName: "\(module).Preview",
        pngPath: "\(id).png",
        sha256: sha,
        width: 100,
        height: 50
    )
}

private func manifest(_ entries: [ManifestEntry], failures: [ManifestFailure] = []) -> Manifest {
    Manifest(
        configuration: RenderConfiguration(platform: .macos, appearance: .light),
        entries: entries,
        failures: failures
    )
}

@Suite("Manifest join")
struct ManifestJoinTests {
    @Test("Equal hashes settle as unchanged without a pixel comparison")
    func identicalHashesShortCircuit() {
        let outcome = ManifestJoin.join(
            base: manifest([entry("a", sha: "same")]),
            head: manifest([entry("a", sha: "same")])
        )

        #expect(outcome.candidates.isEmpty)
        #expect(outcome.settled.map(\.change) == [.unchanged])
    }

    @Test("Head-only previews are added, base-only are removed")
    func addedAndRemoved() {
        let outcome = ManifestJoin.join(
            base: manifest([entry("gone", sha: "x")]),
            head: manifest([entry("fresh", sha: "y")])
        )

        let byID = Dictionary(uniqueKeysWithValues: outcome.settled.map { ($0.previewID.rawValue, $0) })
        #expect(byID["fresh"]?.change == .added)
        #expect(byID["gone"]?.change == .removed)
        // An added preview has no "before", so no base image and no diff image.
        #expect(byID["fresh"]?.basePNG == nil)
        #expect(byID["fresh"]?.diffPNG == nil)
        #expect(byID["gone"]?.headPNG == nil)
    }

    @Test("Differing hashes become candidates for a pixel comparison")
    func differingHashesNeedPixels() {
        let outcome = ManifestJoin.join(
            base: manifest([entry("a", sha: "one")]),
            head: manifest([entry("a", sha: "two")])
        )

        #expect(outcome.settled.isEmpty)
        #expect(outcome.candidates.map(\.previewID.rawValue) == ["a"])
    }

    @Test("A difference under the tolerance is suppressed, not hidden")
    func toleranceSuppresses() {
        let outcome = ManifestJoin.join(
            base: manifest([entry("a", sha: "one")]),
            head: manifest([entry("a", sha: "two")])
        )
        let diff = ManifestJoin.resolve(
            candidate: outcome.candidates[0],
            comparison: ImageComparison(changedPixels: 5, totalPixels: 10_000, sizeChanged: false),
            tolerance: 0.5,
            diffPNG: "a.diff.png"
        )

        #expect(diff.change == .unchanged)
        #expect(diff.suppressedByTolerance)
        #expect(diff.changedPixelPercentage == 0.05)
        // No diff image is kept for a suppressed preview.
        #expect(diff.diffPNG == nil)
    }

    @Test("A difference over the tolerance is a real change")
    func aboveToleranceIsChanged() {
        let outcome = ManifestJoin.join(
            base: manifest([entry("a", sha: "one")]),
            head: manifest([entry("a", sha: "two")])
        )
        let diff = ManifestJoin.resolve(
            candidate: outcome.candidates[0],
            comparison: ImageComparison(changedPixels: 500, totalPixels: 10_000, sizeChanged: false),
            tolerance: 0.5,
            diffPNG: "a.diff.png"
        )

        #expect(diff.change == .changed)
        #expect(!diff.suppressedByTolerance)
        #expect(diff.diffPNG == "a.diff.png")
    }

    @Test("A size change is never suppressed by the tolerance")
    func sizeChangeAlwaysCounts() {
        let outcome = ManifestJoin.join(
            base: manifest([entry("a", sha: "one")]),
            head: manifest([entry("a", sha: "two")])
        )
        // A one pixel taller preview differs in very few pixels but is still a real change.
        let diff = ManifestJoin.resolve(
            candidate: outcome.candidates[0],
            comparison: ImageComparison(changedPixels: 1, totalPixels: 10_000, sizeChanged: true),
            tolerance: 5,
            diffPNG: "a.diff.png"
        )

        #expect(diff.change == .changed)
        #expect(diff.sizeChanged)
    }

    @Test("Render failures are reported separately, never as removals")
    func failuresAreNotRemovals() {
        let failure = ManifestFailure(
            previewID: PreviewID(rawValue: "broken"),
            module: "DesignSystem",
            sourceFile: nil,
            displayName: nil,
            message: "timed out"
        )
        let outcome = ManifestJoin.join(
            base: manifest([entry("a", sha: "same")]),
            head: manifest([entry("a", sha: "same")], failures: [failure])
        )
        let report = DiffReport(tolerance: 0, previews: outcome.settled, failures: [failure])

        #expect(report.summary.removed == 0)
        #expect(report.summary.failed == 1)
        #expect(report.summary.headline == "0 changed · 0 new · 0 removed · 1 failed")
    }

    @Test("The summary counts each bucket once")
    func summaryCounts() {
        let report = DiffReport(tolerance: 0, previews: [
            PreviewDiff(previewID: PreviewID(rawValue: "a"), module: "M", sourceFile: nil, displayName: nil, change: .changed),
            PreviewDiff(previewID: PreviewID(rawValue: "b"), module: "M", sourceFile: nil, displayName: nil, change: .changed),
            PreviewDiff(previewID: PreviewID(rawValue: "c"), module: "M", sourceFile: nil, displayName: nil, change: .added),
            PreviewDiff(previewID: PreviewID(rawValue: "d"), module: "M", sourceFile: nil, displayName: nil, change: .unchanged),
        ])

        #expect(report.summary == DiffReport.Summary(
            added: 1, removed: 0, changed: 2, unchanged: 1, unstable: 0, suppressed: 0, failed: 0
        ))
        #expect(report.summary.headline == "2 changed · 1 new · 0 removed")
    }
}
