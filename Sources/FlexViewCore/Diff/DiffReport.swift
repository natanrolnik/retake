//
//  DiffReport.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

public enum PreviewChange: String, Codable, Sendable {
    /// In head only. There is no "before"; render one image and label it as new.
    case added
    /// In base only. Catches accidental deletions cheaply.
    case removed
    /// In both, and the pixels differ by more than the tolerance.
    case changed
    /// In both and visually identical, or different by less than the tolerance.
    case unchanged
}

public struct PreviewDiff: Codable, Sendable, Equatable {
    public var previewID: PreviewID
    public var module: String
    public var sourceFile: String?
    public var displayName: String?
    public var change: PreviewChange

    /// PNG paths, relative to the base and head directories respectively.
    public var basePNG: String?
    public var headPNG: String?
    /// Path of the generated delta image, relative to the report's output directory.
    public var diffPNG: String?

    public var changedPixelPercentage: Double?
    /// True when the images differ but by less than `--tolerance`, so the preview was
    /// filed as unchanged. Recorded so threshold suppression is never silent.
    public var suppressedByTolerance: Bool
    /// True when base and head rendered at different sizes.
    public var sizeChanged: Bool

    public init(
        previewID: PreviewID,
        module: String,
        sourceFile: String?,
        displayName: String?,
        change: PreviewChange,
        basePNG: String? = nil,
        headPNG: String? = nil,
        diffPNG: String? = nil,
        changedPixelPercentage: Double? = nil,
        suppressedByTolerance: Bool = false,
        sizeChanged: Bool = false
    ) {
        self.previewID = previewID
        self.module = module
        self.sourceFile = sourceFile
        self.displayName = displayName
        self.change = change
        self.basePNG = basePNG
        self.headPNG = headPNG
        self.diffPNG = diffPNG
        self.changedPixelPercentage = changedPixelPercentage
        self.suppressedByTolerance = suppressedByTolerance
        self.sizeChanged = sizeChanged
    }
}

public struct DiffReport: Codable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "report.json"

    public var version: Int
    public var tolerance: Double
    public var previews: [PreviewDiff]
    /// Previews that failed to render on either side. Surfaced separately so a broken
    /// preview is never reported as removed.
    public var failures: [ManifestFailure]

    public init(
        version: Int = DiffReport.currentVersion,
        tolerance: Double,
        previews: [PreviewDiff],
        failures: [ManifestFailure] = []
    ) {
        self.version = version
        self.tolerance = tolerance
        self.previews = previews.sorted { $0.previewID < $1.previewID }
        self.failures = failures.sorted { $0.previewID < $1.previewID }
    }

    public var summary: Summary {
        Summary(
            added: previews.count { $0.change == .added },
            removed: previews.count { $0.change == .removed },
            changed: previews.count { $0.change == .changed },
            unchanged: previews.count { $0.change == .unchanged },
            suppressed: previews.count(where: \.suppressedByTolerance),
            failed: failures.count
        )
    }

    public struct Summary: Sendable, Equatable {
        public var added: Int
        public var removed: Int
        public var changed: Int
        public var unchanged: Int
        public var suppressed: Int
        public var failed: Int

        /// The line that heads the PR comment.
        public var headline: String {
            var parts = ["\(changed) changed", "\(added) new", "\(removed) removed"]
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.joined(separator: " · ")
        }
    }
}

public extension DiffReport {
    func write(to url: URL) throws {
        try Manifest.encoder().encode(self).write(to: url)
    }

    static func read(from url: URL) throws -> DiffReport {
        try JSONDecoder().decode(DiffReport.self, from: Data(contentsOf: url))
    }
}

private extension Array {
    func count(_ isIncluded: (Element) -> Bool) -> Int {
        reduce(0) { isIncluded($1) ? $0 + 1 : $0 }
    }
}
