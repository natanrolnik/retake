//
//  ObjectNaming.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Builds object keys for a published report.
///
/// Three things the naming has to get right:
///
/// - **Unique per push.** A re-run must not overwrite images that an earlier comment
///   still links to, so the timestamp and commit are part of the path.
/// - **Readable.** Someone looking at the bucket should be able to tell which repository,
///   pull request and preview an object belongs to, without opening it.
/// - **Prunable.** Everything for one run shares a prefix, so a lifecycle rule or a
///   manual clean-up can remove a whole run at once.
///
/// ```
/// retake/PocketUmpire/pr-42/20260813-211500-a1b2c3d/report.html
/// retake/PocketUmpire/pr-42/20260813-211500-a1b2c3d/Toss/toss-doubles.after.png
/// ```
public struct ObjectNaming: Sendable {
    public var prefix: String
    public var repository: String
    public var pullRequest: Int?
    public var commit: String?
    public var timestamp: Date

    public init(
        prefix: String = "retake",
        repository: String,
        pullRequest: Int? = nil,
        commit: String? = nil,
        timestamp: Date
    ) {
        self.prefix = prefix
        self.repository = repository
        self.pullRequest = pullRequest
        self.commit = commit
        self.timestamp = timestamp
    }

    public enum Side: String, Sendable {
        case before
        case after
        case diff
    }

    /// Prefix shared by every object of one run.
    public var runPrefix: String {
        var components = [slug(prefix), slug(lastPathComponent(of: repository))]
        if let pullRequest { components.append("pr-\(pullRequest)") }
        var run = Self.timestampFormatter.string(from: timestamp)
        if let commit, !commit.isEmpty { run += "-\(commit.prefix(7))" }
        components.append(run)
        return components.filter { !$0.isEmpty }.joined(separator: "/")
    }

    public var reportKey: String {
        "\(runPrefix)/report.html"
    }

    /// Grouped by module, and named after the preview rather than a hash, so the bucket
    /// stays legible.
    public func imageKey(previewID: PreviewID, module: String, side: Side) -> String {
        "\(runPrefix)/\(slug(module))/\(slug(previewName(from: previewID))).\(side.rawValue).png"
    }

    /// Drops the module prefix and file extension already implied by the grouping.
    private func previewName(from id: PreviewID) -> String {
        var name = id.rawValue
        if let hash = name.firstIndex(of: "#") {
            let file = name[name.startIndex..<hash]
            let label = name[name.index(after: hash)...]
            let fileName = file.split(separator: "/").last.map(String.init) ?? String(file)
            let stem = fileName.hasSuffix(".swift") ? String(fileName.dropLast(6)) : fileName
            name = label.isEmpty ? stem : "\(stem)-\(label)"
        }
        return name
    }

    private func lastPathComponent(of value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? value
    }

    /// Lowercase, alphanumerics and dashes only: safe in a URL without escaping, and
    /// readable in a bucket listing.
    private func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for character in value.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    public static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
