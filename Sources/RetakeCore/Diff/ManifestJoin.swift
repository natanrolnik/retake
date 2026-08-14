//
//  ManifestJoin.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Joins two manifests on `PreviewID` into the four buckets, without touching pixels.
///
/// Entries present on both sides with an equal hash are settled here; only the rest need
/// a per-pixel comparison, which is the expensive part.
public enum ManifestJoin {
    public struct Outcome: Sendable {
        /// Fully resolved by hash equality or by presence alone.
        public var settled: [PreviewDiff]
        /// Present on both sides with differing hashes: needs a pixel comparison to tell
        /// a real change from renderer noise below the tolerance.
        public var candidates: [Candidate]
    }

    public struct Candidate: Sendable {
        public var previewID: PreviewID
        public var base: ManifestEntry
        public var head: ManifestEntry
    }

    public static func join(base: Manifest, head: Manifest) -> Outcome {
        let baseByID = Dictionary(base.entries.map { ($0.previewID, $0) }, uniquingKeysWith: { first, _ in first })
        let headByID = Dictionary(head.entries.map { ($0.previewID, $0) }, uniquingKeysWith: { first, _ in first })

        var settled: [PreviewDiff] = []
        var candidates: [Candidate] = []

        for id in Set(baseByID.keys).union(headByID.keys).sorted() {
            switch (baseByID[id], headByID[id]) {
            case let (baseEntry?, headEntry?):
                guard baseEntry.sha256 != headEntry.sha256 else {
                    settled.append(PreviewDiff(
                        previewID: id,
                        module: headEntry.module,
                        sourceFile: headEntry.sourceFile,
                        displayName: headEntry.displayName,
                        change: .unchanged,
                        basePNG: baseEntry.pngPath,
                        headPNG: headEntry.pngPath,
                        changedPixelPercentage: 0
                    ))
                    continue
                }
                candidates.append(Candidate(previewID: id, base: baseEntry, head: headEntry))

            case let (nil, headEntry?):
                settled.append(PreviewDiff(
                    previewID: id,
                    module: headEntry.module,
                    sourceFile: headEntry.sourceFile,
                    displayName: headEntry.displayName,
                    change: .added,
                    headPNG: headEntry.pngPath
                ))

            case let (baseEntry?, nil):
                settled.append(PreviewDiff(
                    previewID: id,
                    module: baseEntry.module,
                    sourceFile: baseEntry.sourceFile,
                    displayName: baseEntry.displayName,
                    change: .removed,
                    basePNG: baseEntry.pngPath
                ))

            case (nil, nil):
                continue
            }
        }

        return Outcome(settled: settled, candidates: candidates)
    }

    /// Turns a pixel comparison into a verdict, applying the tolerance.
    ///
    /// - Parameter tolerance: percentage of changed pixels at or below which a difference
    ///   is treated as renderer noise. Suppression is recorded, never silent.
    public static func resolve(
        candidate: Candidate,
        comparison: ImageComparison,
        tolerance: Double,
        diffPNG: String?
    ) -> PreviewDiff {
        let suppressed = comparison.changedPercentage <= tolerance && !comparison.sizeChanged
        return PreviewDiff(
            previewID: candidate.previewID,
            module: candidate.head.module,
            sourceFile: candidate.head.sourceFile,
            displayName: candidate.head.displayName,
            change: suppressed ? .unchanged : .changed,
            basePNG: candidate.base.pngPath,
            headPNG: candidate.head.pngPath,
            diffPNG: suppressed ? nil : diffPNG,
            changedPixelPercentage: comparison.changedPercentage,
            suppressedByTolerance: suppressed,
            sizeChanged: comparison.sizeChanged
        )
    }
}
