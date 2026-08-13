//
//  Diff.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import FlexViewCore
import Foundation

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two render passes and classify every preview."
    )

    @Option(name: .long, help: "Directory holding the base render's manifest.json and PNGs.")
    var base: String

    @Option(name: .long, help: "Directory holding the head render's manifest.json and PNGs.")
    var head: String

    @Option(name: .shortAndLong, help: "Directory for report.json and the generated diff images.")
    var out: String

    @Option(
        name: .long,
        help: "Percentage of changed pixels at or below which a preview counts as unchanged."
    )
    var tolerance: Double = 0

    @Option(
        name: .long,
        help: "Per-channel delta (0-255) below which two pixels count as equal."
    )
    var pixelThreshold: Int = 0

    @Option(name: .long, help: "Also write a self-contained HTML report to this path.")
    var html: String?

    func validate() throws {
        guard (0...100).contains(tolerance) else {
            throw ValidationError("--tolerance must be a percentage between 0 and 100.")
        }
        guard (0...255).contains(pixelThreshold) else {
            throw ValidationError("--pixel-threshold must be between 0 and 255.")
        }
    }

    func run() async throws {
        let baseDirectory = URL(fileURLWithPath: base)
        let headDirectory = URL(fileURLWithPath: head)
        let outputDirectory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let baseManifest = try Manifest.read(from: baseDirectory)
        let headManifest = try Manifest.read(from: headDirectory)

        if baseManifest.configuration != headManifest.configuration {
            print(
                "flexview: warning: base and head were rendered with different settings "
                    + "(\(baseManifest.configuration) vs \(headManifest.configuration)); "
                    + "differences below may be configuration, not code."
            )
        }

        let outcome = ManifestJoin.join(base: baseManifest, head: headManifest)
        var previews = outcome.settled

        for candidate in outcome.candidates {
            let diffName = "\(candidate.previewID.slug).diff.png"
            let comparison = try ImageComparator.compare(
                base: baseDirectory.appendingPathComponent(candidate.base.pngPath),
                head: headDirectory.appendingPathComponent(candidate.head.pngPath),
                pixelThreshold: UInt8(pixelThreshold),
                writingDiffTo: outputDirectory.appendingPathComponent(diffName)
            )
            let diff = ManifestJoin.resolve(
                candidate: candidate,
                comparison: comparison,
                tolerance: tolerance,
                diffPNG: diffName
            )
            // A suppressed candidate keeps no diff image; drop the one just written.
            if diff.diffPNG == nil {
                try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(diffName))
            }
            previews.append(diff)
        }

        let report = DiffReport(
            tolerance: tolerance,
            baseDirectory: baseDirectory.standardizedFileURL.path,
            headDirectory: headDirectory.standardizedFileURL.path,
            previews: previews,
            failures: baseManifest.failures + headManifest.failures
        )
        try report.write(to: outputDirectory.appendingPathComponent(DiffReport.fileName))

        if let html {
            let htmlURL = URL(fileURLWithPath: html)
            let rendered = HTMLReport.render(
                report: report,
                diffDirectory: outputDirectory,
                options: HTMLReport.Options(inlineImages: true)
            )
            try Data(rendered.utf8).write(to: htmlURL)
            print("flexview: wrote \(htmlURL.path)")
        }

        print("flexview: \(report.summary.headline)")
        for diff in report.previews where diff.change != .unchanged {
            let percentage = diff.changedPixelPercentage.map { String(format: " (%.2f%% pixels)", $0) } ?? ""
            print("  \(diff.change.rawValue): \(diff.previewID)\(percentage)")
        }
        // Never let the threshold hide something silently.
        for diff in report.previews where diff.suppressedByTolerance {
            let percentage = diff.changedPixelPercentage ?? 0
            print(String(
                format: "  suppressed by --tolerance %.2f%%: %@ differs by %.2f%% of pixels",
                tolerance,
                diff.previewID.rawValue,
                percentage
            ))
        }
        for failure in report.failures {
            print("  failed to render: \(failure.previewID) — \(failure.message)")
        }
    }
}
