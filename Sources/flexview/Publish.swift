//
//  Publish.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import FlexViewCore
import Foundation

struct Publish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload the report's images to S3 and record their URLs, so a comment can show them inline."
    )

    @Option(name: .long, help: "Path to report.json, or the directory holding it.")
    var report: String

    @Option(name: .long, help: "Bucket to upload to.")
    var bucket: String

    @Option(name: .long, help: "Bucket region.")
    var region: String = "us-east-1"

    @Option(name: .long, help: "Key prefix for everything flexview uploads.")
    var prefix: String = "flexview"

    @Option(name: .long, help: "Repository name, used in the object key.")
    var repository: String

    @Option(name: .long, help: "Pull request number, used in the object key.")
    var pr: Int?

    @Option(name: .long, help: "Head commit, used in the object key.")
    var commit: String?

    @Option(name: .long, help: "Endpoint for an S3-compatible service. Omit for AWS.")
    var endpoint: String?

    @Option(
        name: .long,
        help: "Base URL objects are served from, when that differs from the bucket URL (a CDN or custom domain)."
    )
    var publicBaseURL: String?

    @Option(name: .long, help: "Also upload this HTML report.")
    var html: String?

    func run() async throws {
        let reportURL = URL(fileURLWithPath: report)
        let isDirectory = (try? reportURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let jsonURL = isDirectory ? reportURL.appendingPathComponent(DiffReport.fileName) : reportURL
        let diffDirectory = jsonURL.deletingLastPathComponent()

        var diffReport = try DiffReport.read(from: jsonURL)
        let s3 = try S3.fromEnvironment(
            bucket: bucket,
            region: region,
            endpoint: endpoint.flatMap(URL.init(string:))
        )
        let naming = ObjectNaming(
            prefix: prefix,
            repository: repository,
            pullRequest: pr,
            commit: commit,
            timestamp: Date()
        )

        let baseDirectory = diffReport.baseDirectory.map { URL(fileURLWithPath: $0) }
        let headDirectory = diffReport.headDirectory.map { URL(fileURLWithPath: $0) }

        print("flexview: uploading to s3://\(bucket)/\(naming.runPrefix)")
        var uploaded = 0

        for index in diffReport.previews.indices {
            let preview = diffReport.previews[index]
            // Unchanged previews are not shown, so uploading them is pure cost.
            guard preview.change != .unchanged else { continue }

            if let path = preview.basePNG, let directory = baseDirectory {
                diffReport.previews[index].baseURL = try await upload(
                    directory.appendingPathComponent(path),
                    key: naming.imageKey(previewID: preview.previewID, module: preview.module, side: .before),
                    with: s3
                )
                uploaded += 1
            }
            if let path = preview.headPNG, let directory = headDirectory {
                diffReport.previews[index].headURL = try await upload(
                    directory.appendingPathComponent(path),
                    key: naming.imageKey(previewID: preview.previewID, module: preview.module, side: .after),
                    with: s3
                )
                uploaded += 1
            }
            if let path = preview.diffPNG {
                diffReport.previews[index].diffURL = try await upload(
                    diffDirectory.appendingPathComponent(path),
                    key: naming.imageKey(previewID: preview.previewID, module: preview.module, side: .diff),
                    with: s3
                )
                uploaded += 1
            }
        }

        if let html {
            let data = try Data(contentsOf: URL(fileURLWithPath: html))
            let url = try await s3.put(
                data,
                key: naming.reportKey,
                contentType: "text/html; charset=utf-8",
                cacheControl: "public, max-age=31536000, immutable"
            )
            diffReport.reportURL = publicURL(for: naming.reportKey, uploaded: url)
            uploaded += 1
        }

        try diffReport.write(to: jsonURL)
        print("flexview: uploaded \(uploaded) object\(uploaded == 1 ? "" : "s")")
        if let url = diffReport.reportURL { print("flexview: report at \(url)") }
    }

    private func upload(_ file: URL, key: String, with s3: S3) async throws -> String {
        let data = try Data(contentsOf: file)
        // Immutable: every run writes to a fresh, timestamped prefix, so nothing at a
        // given URL ever changes.
        let url = try await s3.put(
            data,
            key: key,
            contentType: "image/png",
            cacheControl: "public, max-age=31536000, immutable"
        )
        return publicURL(for: key, uploaded: url)
    }

    private func publicURL(for key: String, uploaded: URL) -> String {
        guard let publicBaseURL, !publicBaseURL.isEmpty else { return uploaded.absoluteString }
        return publicBaseURL.hasSuffix("/") ? publicBaseURL + key : publicBaseURL + "/" + key
    }
}
