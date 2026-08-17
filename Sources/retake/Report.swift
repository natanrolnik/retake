//
//  Report.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import RetakeCore
import Foundation

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render a diff report as a single self-contained HTML file."
    )

    @Option(name: .long, help: "Path to report.json, or the directory holding it.")
    var report: String

    @Option(name: .shortAndLong, help: "Where to write the HTML file.")
    var out: String

    @Option(name: .long, help: "Title shown at the top of the report.")
    var title: String = "retake"

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Embed images as data URIs so the file stands alone. Off links to them on disk."
    )
    var inlineImages: Bool = true

    @Flag(name: .long, help: "Include previews that did not change.")
    var includeUnchanged: Bool = false

    func run() async throws {
        let reportURL = URL(fileURLWithPath: report)
        let isDirectory = (try? reportURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let jsonURL = isDirectory ? reportURL.appendingPathComponent(DiffReport.fileName) : reportURL

        let diffReport = try DiffReport.read(from: jsonURL)
        let html = HTMLReport.render(
            report: diffReport,
            diffDirectory: jsonURL.deletingLastPathComponent(),
            options: HTMLReport.Options(
                title: title,
                inlineImages: inlineImages,
                includeUnchanged: includeUnchanged,
                // With nothing on the base to compare against, the before/after layout
                // draws an empty half for every preview. A grid says the same thing in a
                // fraction of the space.
                style: diffReport.hasNothingToCompare ? .catalogue : .comparison
            )
        )

        let outputURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(html.utf8).write(to: outputURL)

        let summary = diffReport.summary
        print("retake: wrote \(outputURL.path) (\(summary.headline))")
        if inlineImages {
            let size = (try? Data(contentsOf: outputURL).count) ?? 0
            print("retake: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), self-contained")
        }
    }
}
