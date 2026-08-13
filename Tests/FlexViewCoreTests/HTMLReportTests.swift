//
//  HTMLReportTests.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation
import Testing
@testable import FlexViewCore

private func diff(
    _ id: String,
    change: PreviewChange,
    module: String = "DesignSystem",
    displayName: String? = nil,
    basePNG: String? = nil,
    headPNG: String? = nil,
    diffPNG: String? = nil,
    suppressed: Bool = false
) -> PreviewDiff {
    PreviewDiff(
        previewID: PreviewID(rawValue: id),
        module: module,
        sourceFile: nil,
        displayName: displayName,
        change: change,
        basePNG: basePNG,
        headPNG: headPNG,
        diffPNG: diffPNG,
        changedPixelPercentage: change == .changed ? 12.5 : nil,
        suppressedByTolerance: suppressed
    )
}

private func render(_ report: DiffReport, options: HTMLReport.Options = .init()) -> String {
    HTMLReport.render(
        report: report,
        diffDirectory: URL(fileURLWithPath: "/tmp/flexview-does-not-exist"),
        options: options
    )
}

@Suite("HTML report")
struct HTMLReportTests {
    @Test("Unchanged previews are excluded unless asked for")
    func unchangedExcluded() {
        let report = DiffReport(tolerance: 0, previews: [
            diff("a", change: .changed),
            diff("b", change: .unchanged),
        ])

        #expect(!render(report).contains("&quot;b&quot;") )
        #expect(render(report).contains(">a<") || render(report).contains("a</code>"))
        #expect(render(report, options: .init(includeUnchanged: true)).contains("b</code>"))
    }

    @Test("Every bucket gets its own badge")
    func badges() {
        let report = DiffReport(tolerance: 0, previews: [
            diff("a", change: .changed),
            diff("b", change: .added),
            diff("c", change: .removed),
        ])
        let html = render(report)

        #expect(html.contains(#"class="badge changed""#))
        #expect(html.contains(#"class="badge added""#))
        #expect(html.contains(#"class="badge removed""#))
    }

    @Test("Tolerance suppression is stated in the report, not just the log")
    func suppressionIsVisible() {
        let report = DiffReport(tolerance: 1.5, previews: [
            diff("a", change: .unchanged, suppressed: true),
        ])

        #expect(render(report).contains("1.50% tolerance"))
    }

    @Test("Preview names are escaped rather than injected as markup")
    func escaping() {
        let report = DiffReport(tolerance: 0, previews: [
            diff("x", change: .changed, displayName: "<script>alert('xss')</script>"),
        ])
        let html = render(report)

        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test("A missing image degrades to a placeholder instead of a broken tag")
    func missingImage() {
        let report = DiffReport(
            tolerance: 0,
            baseDirectory: "/tmp/flexview-missing",
            previews: [diff("a", change: .changed, basePNG: "nope.png")]
        )

        #expect(render(report).contains("image unavailable"))
    }

    @Test("The document is well formed and self-describing")
    func documentShape() {
        let html = render(DiffReport(tolerance: 0, previews: [diff("a", change: .changed)]))

        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.hasSuffix("</html>"))
        #expect(html.contains("<title>flexview</title>"))
    }
}
