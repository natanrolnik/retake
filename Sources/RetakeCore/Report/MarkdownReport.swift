//
//  MarkdownReport.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Renders a diff report as Markdown, for a pull request comment or a job summary.
///
/// No images: this is the variant for the artifact workflow, where the pictures live in
/// a downloadable HTML report rather than on a bucket. It says what changed and where to
/// look, and is careful not to imply it is showing the change itself.
public enum MarkdownReport {
    /// Identifies the comment so pushes update one comment instead of spamming a thread.
    public static let marker = "<!-- retake -->"

    public struct Options: Sendable {
        /// Where the full report can be downloaded, usually the workflow run page.
        public var artifactURL: String?
        public var artifactName: String
        /// Previews listed per module before the rest are summarised as a count.
        public var previewLimit: Int

        public init(artifactURL: String? = nil, artifactName: String = "retake-report", previewLimit: Int = 20) {
            self.artifactURL = artifactURL
            self.artifactName = artifactName
            self.previewLimit = previewLimit
        }
    }

    public static func render(report: DiffReport, options: Options = Options()) -> String {
        let summary = report.summary
        var lines: [String] = [marker, ""]

        guard summary.changed + summary.added + summary.removed + summary.unstable + summary.failed > 0 else {
            lines.append("**No visual changes.** \(summary.unchanged) preview\(summary.unchanged == 1 ? "" : "s") rendered identically.")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("### Preview snapshots")
        lines.append("")
        lines.append(summary.headline)
        lines.append("")

        let interesting = report.previews.filter { $0.change != .unchanged }
        for (module, previews) in Dictionary(grouping: interesting, by: \.module).sorted(by: { $0.key < $1.key }) {
            lines.append("<details><summary><b>\(escape(module))</b> — \(previews.count) preview\(previews.count == 1 ? "" : "s")</summary>")
            lines.append("")
            let sorted = previews.sorted { $0.previewID < $1.previewID }
            // With published images the table shows the change; without them it can only
            // name it, and the reader has to open the report.
            let hasImages = sorted.contains { $0.baseURL != nil || $0.headURL != nil }

            if hasImages {
                lines.append("| Preview | Before | After | Diff |")
                lines.append("| --- | --- | --- | --- |")
                for preview in sorted.prefix(options.previewLimit) {
                    let name = preview.displayName ?? preview.previewID.rawValue
                    let detail = preview.changedPixelPercentage
                        .map { String(format: " (%.2f%%)", $0) } ?? ""
                    lines.append(
                        "| **\(escape(name))**<br>\(label(for: preview.change))\(escape(detail)) "
                            + "| \(image(preview.baseURL, alt: "before")) "
                            + "| \(image(preview.headURL, alt: "after")) "
                            + "| \(image(preview.diffURL, alt: "diff")) |"
                    )
                }
            } else {
                lines.append("| Preview | Change | Pixels |")
                lines.append("| --- | --- | --- |")
                for preview in sorted.prefix(options.previewLimit) {
                    let name = preview.displayName ?? preview.previewID.rawValue
                    let pixels = preview.changedPixelPercentage
                        .map { String(format: "%.2f%%", $0) } ?? "—"
                    lines.append("| `\(escape(name))` | \(label(for: preview.change)) | \(preview.change == .changed ? pixels : "—") |")
                }
            }
            if sorted.count > options.previewLimit {
                lines.append("")
                lines.append("_\(sorted.count - options.previewLimit) more not listed._")
            }
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }

        if summary.unstable > 0 {
            lines.append(
                "> [!WARNING]\n"
                    + "> \(summary.unstable) preview\(summary.unstable == 1 ? "" : "s") "
                    + "render\(summary.unstable == 1 ? "s" : "") differently on the same commit and "
                    + "\(summary.unstable == 1 ? "was" : "were") excluded. "
                    + "Content that arrives asynchronously is the usual cause."
            )
            lines.append("")
        }
        if summary.suppressed > 0 {
            lines.append(
                "_\(summary.suppressed) preview\(summary.suppressed == 1 ? "" : "s") differed by less than "
                    + "the \(String(format: "%.2f", report.tolerance))% tolerance and "
                    + "\(summary.suppressed == 1 ? "was" : "were") filed as unchanged._"
            )
            lines.append("")
        }
        if summary.failed > 0 {
            lines.append("**\(summary.failed) preview\(summary.failed == 1 ? "" : "s") failed to render:**")
            for failure in report.failures.prefix(options.previewLimit) {
                lines.append("- `\(escape(failure.previewID.rawValue))` — \(escape(failure.message))")
            }
            lines.append("")
        }

        if let reportURL = report.reportURL {
            lines.append("[**Open the full report**](\(reportURL))")
            lines.append("")
        } else if let artifactURL = options.artifactURL {
            lines.append("[**See the images**](\(artifactURL)) — download the `\(options.artifactName)` artifact and open `report.html`.")
        } else {
            lines.append("_Download the `\(options.artifactName)` artifact and open `report.html` to see the images._")
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// Width-constrained so a table of previews stays readable in a comment.
    private static func image(_ url: String?, alt: String) -> String {
        guard let url else { return "—" }
        return #"<img src="\#(url)" alt="\#(alt)" width="220">"#
    }

    private static func label(for change: PreviewChange) -> String {
        switch change {
        case .added: "🆕 new"
        case .removed: "🗑️ removed"
        case .changed: "🎨 changed"
        case .unchanged: "unchanged"
        case .unstable: "⚠️ unstable"
        }
    }

    /// Keeps preview names from breaking the table or injecting markup.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
