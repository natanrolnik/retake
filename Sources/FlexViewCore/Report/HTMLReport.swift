//
//  HTMLReport.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Renders a diff report as a single HTML file.
///
/// Images are inlined as data URIs by default so the report is one portable file: a CI
/// artifact, an email attachment or a local `open` all work without a server or a
/// sibling directory of PNGs.
public enum HTMLReport {
    public struct Options: Sendable {
        public var title: String
        public var inlineImages: Bool
        /// Previews that did not change are omitted unless this is set.
        public var includeUnchanged: Bool

        public init(title: String = "flexview", inlineImages: Bool = true, includeUnchanged: Bool = false) {
            self.title = title
            self.inlineImages = inlineImages
            self.includeUnchanged = includeUnchanged
        }
    }

    public static func render(
        report: DiffReport,
        diffDirectory: URL,
        options: Options = Options()
    ) -> String {
        let baseDirectory = report.baseDirectory.map { URL(fileURLWithPath: $0) }
        let headDirectory = report.headDirectory.map { URL(fileURLWithPath: $0) }

        let shown = report.previews.filter { options.includeUnchanged || $0.change != .unchanged }
        let grouped = Dictionary(grouping: shown, by: \.module).sorted { $0.key < $1.key }

        var html = ""
        html += header(title: options.title)
        html += summary(report.summary, tolerance: report.tolerance)

        if shown.isEmpty {
            html += #"<p class="empty">No visual changes.</p>"#
        }

        for (module, previews) in grouped {
            html += #"<section><h2>\#(escape(module)) <span class="count">\#(previews.count)</span></h2>"#
            for preview in previews.sorted(by: { $0.previewID < $1.previewID }) {
                html += card(
                    preview,
                    baseDirectory: baseDirectory,
                    headDirectory: headDirectory,
                    diffDirectory: diffDirectory,
                    options: options
                )
            }
            html += "</section>"
        }

        if !report.failures.isEmpty {
            html += #"<section class="failures"><h2>Failed to render</h2>"#
            for failure in report.failures {
                html += #"""
                <div class="failure"><code>\#(escape(failure.previewID.rawValue))</code>\#
                <p>\#(escape(failure.message))</p></div>
                """#
            }
            html += "</section>"
        }

        html += footer()
        return html
    }

    // MARK: - Sections

    private static func summary(_ summary: DiffReport.Summary, tolerance: Double) -> String {
        var html = #"<div class="summary">"#
        html += tile("Changed", summary.changed, style: "changed")
        html += tile("New", summary.added, style: "added")
        html += tile("Removed", summary.removed, style: "removed")
        if summary.unchanged > 0 { html += tile("Unchanged", summary.unchanged, style: "unchanged") }
        if summary.failed > 0 { html += tile("Failed", summary.failed, style: "failed") }
        html += "</div>"

        if summary.suppressed > 0 {
            // Never let the threshold hide something without saying so.
            html += #"""
            <p class="note">\#(summary.suppressed) preview\#(summary.suppressed == 1 ? "" : "s") \#
            differed by less than the \#(format(tolerance))% tolerance and \#
            \#(summary.suppressed == 1 ? "was" : "were") filed as unchanged.</p>
            """#
        }
        return html
    }

    private static func tile(_ label: String, _ value: Int, style: String) -> String {
        #"""
        <div class="tile \#(style)"><span class="value">\#(value)</span><span class="label">\#(label)</span></div>
        """#
    }

    private static func card(
        _ preview: PreviewDiff,
        baseDirectory: URL?,
        headDirectory: URL?,
        diffDirectory: URL,
        options: Options
    ) -> String {
        let name = preview.displayName ?? preview.previewID.rawValue
        var html = #"<article class="preview">"#
        html += #"""
        <header><span class="badge \#(preview.change.rawValue)">\#(label(for: preview.change))</span>
        <h3>\#(escape(name))</h3><code>\#(escape(preview.previewID.rawValue))</code>
        """#
        if let percentage = preview.changedPixelPercentage, preview.change == .changed {
            html += #"<span class="pct">\#(format(percentage))% of pixels</span>"#
        }
        if preview.sizeChanged {
            html += #"<span class="pct">size changed</span>"#
        }
        html += "</header>"

        html += #"<div class="frames">"#
        // An added preview has no "before" and a removed one has no "after"; render only
        // the columns that exist rather than an empty placeholder.
        if let path = preview.basePNG, let directory = baseDirectory {
            html += frame("Before", url: directory.appendingPathComponent(path), options: options)
        }
        if let path = preview.headPNG, let directory = headDirectory {
            html += frame(preview.change == .added ? "New preview" : "After",
                          url: directory.appendingPathComponent(path),
                          options: options)
        }
        if let path = preview.diffPNG {
            html += frame("Diff", url: diffDirectory.appendingPathComponent(path), options: options)
        }
        html += "</div></article>"
        return html
    }

    private static func frame(_ caption: String, url: URL, options: Options) -> String {
        let source = options.inlineImages ? dataURI(for: url) : url.path
        guard let source else {
            return #"<figure class="missing"><div class="box">image unavailable</div><figcaption>\#(escape(caption))</figcaption></figure>"#
        }
        // Click to zoom via a checkbox rather than a link to the same image: an anchor
        // would embed a second copy of the data URI and double the file size.
        let toggle = "z\(nextFrameID())"
        return #"""
        <figure><input type="checkbox" id="\#(toggle)" class="zoom">\#
        <label for="\#(toggle)"><img loading="lazy" src="\#(escape(source))" alt="\#(escape(caption))"></label>\#
        <figcaption>\#(escape(caption))</figcaption></figure>
        """#
    }

    private static let frameCounter = FrameCounter()

    private static func nextFrameID() -> Int {
        frameCounter.next()
    }

    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    private static func dataURI(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    private static func label(for change: PreviewChange) -> String {
        switch change {
        case .added: "New"
        case .removed: "Removed"
        case .changed: "Changed"
        case .unchanged: "Unchanged"
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Escapes text for both element content and quoted attribute values.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    // MARK: - Chrome

    private static func header(title: String) -> String {
        #"""
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(escape(title))</title>
        <style>
        :root {
          color-scheme: light dark;
          --bg: #ffffff; --fg: #1c1c1e; --muted: #6b6b70; --line: #e3e3e6;
          --card: #fafafa; --checker: #f0f0f2;
          --changed: #b26a00; --added: #1a7f37; --removed: #c0392b; --failed: #c0392b;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #16161a; --fg: #ececf1; --muted: #9a9aa2; --line: #2e2e34;
            --card: #1e1e23; --checker: #26262c;
            --changed: #e8a33d; --added: #4ac26b; --removed: #f0685c; --failed: #f0685c;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 32px; background: var(--bg); color: var(--fg);
          font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        }
        h1 { font-size: 22px; margin: 0 0 20px; }
        h2 { font-size: 16px; margin: 32px 0 12px; display: flex; align-items: center; gap: 8px; }
        h3 { font-size: 15px; margin: 0; font-weight: 600; }
        code { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); }
        .count {
          font-size: 12px; font-weight: 500; color: var(--muted);
          border: 1px solid var(--line); border-radius: 99px; padding: 1px 8px;
        }
        .summary { display: flex; flex-wrap: wrap; gap: 12px; }
        .tile {
          display: flex; flex-direction: column; gap: 2px; min-width: 92px;
          padding: 12px 16px; border: 1px solid var(--line); border-radius: 10px; background: var(--card);
        }
        .tile .value { font-size: 24px; font-weight: 650; line-height: 1.1; }
        .tile .label { font-size: 12px; color: var(--muted); }
        .tile.changed .value { color: var(--changed); }
        .tile.added .value { color: var(--added); }
        .tile.removed .value, .tile.failed .value { color: var(--removed); }
        .note, .empty { color: var(--muted); font-size: 13px; }
        .preview {
          border: 1px solid var(--line); border-radius: 12px; background: var(--card);
          padding: 16px; margin-bottom: 12px;
        }
        .preview header { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
        .badge {
          font-size: 11px; font-weight: 650; letter-spacing: .03em; text-transform: uppercase;
          padding: 3px 8px; border-radius: 6px; border: 1px solid currentColor;
        }
        .badge.changed { color: var(--changed); }
        .badge.added { color: var(--added); }
        .badge.removed { color: var(--removed); }
        .badge.unchanged { color: var(--muted); }
        .pct { font-size: 12px; color: var(--muted); margin-left: auto; }
        .frames { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-start; }
        figure { margin: 0; display: flex; flex-direction: column; gap: 6px; }
        figure img {
          display: block; max-width: 320px; height: auto; border: 1px solid var(--line); border-radius: 8px;
          /* Checkerboard so transparent previews do not read as white ones. */
          background-image:
            linear-gradient(45deg, var(--checker) 25%, transparent 25%),
            linear-gradient(-45deg, var(--checker) 25%, transparent 25%),
            linear-gradient(45deg, transparent 75%, var(--checker) 75%),
            linear-gradient(-45deg, transparent 75%, var(--checker) 75%);
          background-size: 16px 16px;
          background-position: 0 0, 0 8px, 8px -8px, -8px 0;
        }
        figcaption { font-size: 12px; color: var(--muted); }
        .zoom { display: none; }
        figure label { cursor: zoom-in; display: block; }
        .zoom:checked + label { cursor: zoom-out; }
        .zoom:checked + label img { max-width: min(90vw, 1200px); }
        .missing .box {
          width: 200px; height: 120px; display: grid; place-items: center;
          border: 1px dashed var(--line); border-radius: 8px; color: var(--muted); font-size: 12px;
        }
        .failures .failure { border-left: 3px solid var(--failed); padding-left: 12px; margin-bottom: 12px; }
        .failures p { margin: 4px 0 0; font-size: 13px; color: var(--muted); }
        footer { margin-top: 40px; color: var(--muted); font-size: 12px; }
        </style></head><body>
        <h1>\#(escape(title))</h1>
        """#
    }

    private static func footer() -> String {
        "<footer>Generated by flexview.</footer></body></html>"
    }
}
