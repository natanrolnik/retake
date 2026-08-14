//
//  HTMLReport.swift
//  retake
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
        public var style: Style

        public init(
            title: String = "retake",
            inlineImages: Bool = true,
            includeUnchanged: Bool = false,
            style: Style = .comparison
        ) {
            self.title = title
            self.inlineImages = inlineImages
            self.includeUnchanged = includeUnchanged
            self.style = style
        }

        /// What the reader is here for.
        public enum Style: Sendable {
            /// Before, after and the delta, for reviewing a change.
            case comparison
            /// One image per preview in a grid, for seeing what exists.
            case catalogue
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
        if options.style == .comparison {
            html += summary(report.summary, tolerance: report.tolerance)
        } else {
            html += #"<p class="note">\#(shown.count) previews across \#(grouped.count) modules.</p>"#
        }

        if shown.isEmpty {
            html += #"<p class="empty">No visual changes.</p>"#
        }

        for (module, previews) in grouped {
            html += #"<section><h2>\#(escape(module)) <span class="count">\#(previews.count)</span></h2>"#
            if options.style == .catalogue { html += #"<div class="gallery">"# }
            for preview in previews.sorted(by: { $0.previewID < $1.previewID }) {
                html += card(
                    preview,
                    baseDirectory: baseDirectory,
                    headDirectory: headDirectory,
                    diffDirectory: diffDirectory,
                    options: options
                )
            }
            if options.style == .catalogue { html += "</div>" }
            if options.style == .catalogue { html += "</div>" }
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
            if options.style == .catalogue { html += "</div>" }
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
        if summary.unstable > 0 { html += tile("Unstable", summary.unstable, style: "unstable-tile") }
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
        if summary.unstable > 0 {
            html += #"""
            <p class="note">\#(summary.unstable) preview\#(summary.unstable == 1 ? "" : "s") \#
            render\#(summary.unstable == 1 ? "s" : "") differently on the same commit, so \#
            \#(summary.unstable == 1 ? "it was" : "they were") excluded from the comparison \#
            rather than reported as a change nobody made.</p>
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
        guard options.style == .comparison else {
            return catalogueCard(preview, headDirectory: headDirectory, options: options, name: name)
        }
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
            html += frame("Before", role: "before", url: directory.appendingPathComponent(path), options: options)
        }
        if let path = preview.headPNG, let directory = headDirectory {
            html += frame(preview.change == .added ? "New preview" : "After",
                          role: "after",
                          url: directory.appendingPathComponent(path),
                          options: options)
        }
        if let path = preview.diffPNG {
            html += frame("Diff", role: "diff", url: diffDirectory.appendingPathComponent(path), options: options)
        }
        html += "</div>"
        // Filled in by script, cloning the images above. Emitting fresh <img> tags here
        // would embed a second copy of both data URIs.
        if preview.basePNG != nil, preview.headPNG != nil {
            html += #"<div class="compare"></div>"#
        }
        html += "</article>"
        return html
    }

    /// One image with its name underneath, sized to sit in a grid.
    private static func catalogueCard(
        _ preview: PreviewDiff,
        headDirectory: URL?,
        options: Options,
        name: String
    ) -> String {
        guard let path = preview.headPNG, let directory = headDirectory else { return "" }
        let file = directory.appendingPathComponent(path)
        let source = options.inlineImages ? dataURI(for: file) : file.path
        guard let source else { return "" }
        return #"""
        <figure class="tile"><div class="shot">\#
        <img loading="lazy" src="\#(escape(source))" alt="\#(escape(name))"></div>\#
        <figcaption><b>\#(escape(name))</b><br><code>\#(escape(preview.previewID.rawValue))</code></figcaption>\#
        </figure>
        """#
    }

    private static func frame(_ caption: String, role: String, url: URL, options: Options) -> String {
        let source = options.inlineImages ? dataURI(for: url) : url.path
        guard let source else {
            return #"<figure class="missing" data-role="\#(role)"><div class="box">image unavailable</div><figcaption>\#(escape(caption))</figcaption></figure>"#
        }
        // Click to zoom via a checkbox rather than a link to the same image: an anchor
        // would embed a second copy of the data URI and double the file size.
        let toggle = "z\(nextFrameID())"
        return #"""
        <figure data-role="\#(role)"><input type="checkbox" id="\#(toggle)" class="zoom">\#
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
        case .unstable: "Unstable"
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
        .badge.unstable { color: var(--muted); }
        .tile.unstable-tile .value { color: var(--muted); }
        /* Before/after wipe. The two images are clones of the ones above, so the slider
           costs no extra bytes in a report with inlined images. */
        .compare { margin-top: 14px; max-width: 320px; }
        .compare .stage {
          position: relative; overflow: hidden; border: 1px solid var(--line); border-radius: 8px;
          line-height: 0; cursor: ew-resize; touch-action: none;
        }
        .compare .stage img { display: block; width: 100%; height: auto; max-width: none; }
        .compare .after {
          position: absolute; inset: 0 auto 0 0; width: var(--pos, 50%); overflow: hidden;
        }
        .compare .after img { position: absolute; top: 0; left: 0; height: 100%; width: auto; }
        .compare .handle {
          position: absolute; top: 0; bottom: 0; left: var(--pos, 50%); width: 2px;
          background: var(--fg); opacity: .85; pointer-events: none;
        }
        .compare .handle::after {
          content: ""; position: absolute; top: 50%; left: 50%; width: 26px; height: 26px;
          transform: translate(-50%, -50%); border-radius: 50%;
          background: var(--bg); border: 2px solid var(--fg);
        }
        .compare .legend {
          display: flex; justify-content: space-between; font-size: 12px; color: var(--muted);
          margin-top: 6px;
        }
        /* Catalogue: a wall of previews, each a readable thumbnail. */
        .gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 20px; }
        .tile { display: flex; flex-direction: column; gap: 8px; margin: 0; }
        .tile .shot {
          border: 1px solid var(--line); border-radius: 10px; background: var(--card);
          height: 300px; display: grid; place-items: center; overflow: hidden; padding: 8px;
        }
        .tile .shot img { max-width: 100%; max-height: 100%; width: auto; height: auto; border: 0; }
        .tile figcaption { font-size: 12px; line-height: 1.35; }
        .tile code { font-size: 11px; }
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
        #"""
        <footer>Generated by retake.</footer>
        <script>
        // Builds the before/after wipe by cloning the images already on the page. Cloning
        // matters: with inlined images, emitting fresh <img> tags would embed a second
        // copy of every data URI and double the file size.
        for (const card of document.querySelectorAll('.preview')) {
          const mount = card.querySelector('.compare');
          const before = card.querySelector('figure[data-role="before"] img');
          const after = card.querySelector('figure[data-role="after"] img');
          if (!mount || !before || !after) continue;

          const stage = document.createElement('div');
          stage.className = 'stage';
          // After fills the stage and Before is clipped over it from the left, so the
          // left of the handle reads as Before and the right as After, matching the
          // legend and the usual direction of a wipe.
          const baseImage = after.cloneNode();
          const overlay = document.createElement('div');
          overlay.className = 'after';
          const headImage = before.cloneNode();
          overlay.appendChild(headImage);
          const handle = document.createElement('div');
          handle.className = 'handle';
          stage.append(baseImage, overlay, handle);

          const legend = document.createElement('div');
          legend.className = 'legend';
          legend.innerHTML = '<span>Before</span><span>After</span>';
          mount.append(stage, legend);

          // The overlay is clipped to a width, so its image must keep the stage's full
          // width rather than being squeezed with it.
          const sizeOverlay = () => { headImage.style.width = stage.clientWidth + 'px'; };
          if (baseImage.complete) sizeOverlay(); else baseImage.addEventListener('load', sizeOverlay);
          window.addEventListener('resize', sizeOverlay);

          const moveTo = (clientX) => {
            const box = stage.getBoundingClientRect();
            const ratio = Math.min(Math.max((clientX - box.left) / box.width, 0), 1);
            stage.style.setProperty('--pos', (ratio * 100) + '%');
          };
          let dragging = false;
          stage.addEventListener('pointerdown', (event) => {
            dragging = true;
            stage.setPointerCapture(event.pointerId);
            moveTo(event.clientX);
          });
          stage.addEventListener('pointermove', (event) => { if (dragging) moveTo(event.clientX); });
          stage.addEventListener('pointerup', () => { dragging = false; });
          stage.addEventListener('pointercancel', () => { dragging = false; });
        }
        </script></body></html>
        """#
    }
}
