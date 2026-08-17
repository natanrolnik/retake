//
//  DiffReport.swift
//  retake
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
    /// Renders differently on the same commit, so it cannot be compared at all. Kept
    /// out of `changed` rather than reported as a change nobody made.
    case unstable
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

    /// Public URLs, once the images have been published. Without these a comment can
    /// only link to a downloadable report.
    public var baseURL: String?
    public var headURL: String?
    public var diffURL: String?

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
    /// Absolute directories the PNG paths resolve against, so a report is enough on its
    /// own to locate every image.
    public var baseDirectory: String?
    public var headDirectory: String?
    /// Public URL of the published HTML report, when there is one.
    public var reportURL: String?
    public var previews: [PreviewDiff]
    /// Previews that failed to render on either side. Surfaced separately so a broken
    /// preview is never reported as removed.
    public var failures: [ManifestFailure]

    public init(
        version: Int = DiffReport.currentVersion,
        tolerance: Double,
        baseDirectory: String? = nil,
        headDirectory: String? = nil,
        reportURL: String? = nil,
        previews: [PreviewDiff],
        failures: [ManifestFailure] = []
    ) {
        self.version = version
        self.tolerance = tolerance
        self.baseDirectory = baseDirectory
        self.headDirectory = headDirectory
        self.reportURL = reportURL
        self.previews = previews.sorted { $0.previewID < $1.previewID }
        self.failures = failures.sorted { $0.previewID < $1.previewID }
    }

    public var summary: Summary {
        Summary(
            added: previews.count { $0.change == .added },
            removed: previews.count { $0.change == .removed },
            changed: previews.count { $0.change == .changed },
            unchanged: previews.count { $0.change == .unchanged },
            unstable: previews.count { $0.change == .unstable },
            suppressed: previews.count(where: \.suppressedByTolerance),
            failed: failures.count
        )
    }

    public struct Summary: Sendable, Equatable {
        public var added: Int
        public var removed: Int
        public var changed: Int
        public var unchanged: Int
        public var unstable: Int
        public var suppressed: Int
        public var failed: Int

        /// The line that heads the PR comment.
        public var headline: String {
            var parts = ["\(changed) changed", "\(added) new", "\(removed) removed"]
            if unstable > 0 { parts.append("\(unstable) unstable") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.joined(separator: " · ")
        }
    }
}

public extension DiffReport {
    /// Nothing on the base to compare against: every preview shown is new.
    ///
    /// The before/after layout has nothing to put in the before column here, so it draws
    /// an empty half for every preview. A grid of what was added says the same thing in a
    /// fraction of the space.
    var hasNothingToCompare: Bool {
        let shown = previews.filter { $0.change != .unchanged }
        return !shown.isEmpty && shown.allSatisfy { $0.change == .added }
    }

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
