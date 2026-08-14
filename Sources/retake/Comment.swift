//
//  Comment.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import RetakeCore
import Foundation

struct Comment: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the report as Markdown, and optionally upsert it as a pull request comment."
    )

    @Option(name: .long, help: "Path to report.json, or the directory holding it.")
    var report: String

    @Option(name: .shortAndLong, help: "Write the Markdown here. Prints to stdout when omitted.")
    var out: String?

    @Option(name: .long, help: "Pull request number. With this, the comment is upserted via gh.")
    var pr: Int?

    @Option(name: .long, help: "Repository as owner/name, for --pr. Inferred by gh when omitted.")
    var repo: String?

    @Option(name: .long, help: "URL where the full report can be downloaded.")
    var artifactURL: String?

    @Option(name: .long, help: "Name of the uploaded artifact.")
    var artifactName: String = "retake-report"

    @Option(name: .long, help: "Previews listed per module before the rest are summarised.")
    var previewLimit: Int = 20

    func run() async throws {
        let reportURL = URL(fileURLWithPath: report)
        let isDirectory = (try? reportURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let jsonURL = isDirectory ? reportURL.appendingPathComponent(DiffReport.fileName) : reportURL

        let markdown = MarkdownReport.render(
            report: try DiffReport.read(from: jsonURL),
            options: MarkdownReport.Options(
                artifactURL: artifactURL,
                artifactName: artifactName,
                previewLimit: previewLimit
            )
        )

        if let out {
            try Data(markdown.utf8).write(to: URL(fileURLWithPath: out))
            print("retake: wrote \(out)")
        } else if pr == nil {
            print(markdown)
        }

        guard let pr else { return }
        try upsert(markdown: markdown, pullRequest: pr)
    }

    /// Updates the existing retake comment when there is one, so pushes replace a
    /// single comment instead of appending to the thread.
    private func upsert(markdown: String, pullRequest: Int) throws {
        var listArguments = ["gh", "api", "repos/{owner}/{repo}/issues/\(pullRequest)/comments", "--paginate"]
        if let repo { listArguments += ["-H", "X-Repo: \(repo)"] }

        let existing = try? Shell.runChecked("/usr/bin/env", listArguments)
        let identifier = existing
            .flatMap { findExistingComment(in: $0.standardOutput) }

        let body = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retake-comment-\(pullRequest).md")
        try Data(markdown.utf8).write(to: body)

        if let identifier {
            _ = try Shell.runChecked("/usr/bin/env", [
                "gh", "api", "--method", "PATCH",
                "repos/{owner}/{repo}/issues/comments/\(identifier)",
                "-F", "body=@\(body.path)",
            ])
            print("retake: updated comment \(identifier) on #\(pullRequest)")
        } else {
            _ = try Shell.runChecked("/usr/bin/env", [
                "gh", "api", "--method", "POST",
                "repos/{owner}/{repo}/issues/\(pullRequest)/comments",
                "-F", "body=@\(body.path)",
            ])
            print("retake: posted a comment on #\(pullRequest)")
        }
    }

    /// Finds the previous comment by its marker, without pulling in a JSON dependency
    /// for a single field.
    private func findExistingComment(in json: String) -> Int? {
        guard
            let data = json.data(using: .utf8),
            let comments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        return comments
            .last { ($0["body"] as? String)?.contains(MarkdownReport.marker) == true }
            .flatMap { $0["id"] as? Int }
    }
}
