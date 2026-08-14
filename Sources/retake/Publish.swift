//
//  Publish.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import RetakeCore
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

    @Option(name: .long, help: "Key prefix for everything retake uploads.")
    var prefix: String = "retake"

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
        help: "How the uploaded objects are addressed: public (bucket URL), cdn (--public-base-url), or presigned (time-limited signed URLs, for a bucket that stays private)."
    )
    var urlMode: URLMode = .public

    @Option(
        name: .long,
        help: "Base URL objects are served from with --url-mode cdn."
    )
    var publicBaseURL: String?

    @Option(name: .long, help: "Lifetime of presigned URLs in seconds. AWS caps this at 7 days.")
    var presignExpires: Int = 86_400

    enum URLMode: String, ExpressibleByArgument, CaseIterable {
        /// Objects are world readable at the bucket URL.
        case `public`
        /// Objects are served through a CDN or custom domain in front of the bucket.
        case cdn
        /// The bucket stays private and each URL carries its own time-limited signature.
        case presigned
    }

    @Option(name: .long, help: "Also upload this HTML report.")
    var html: String?

    func validate() throws {
        if urlMode == .cdn, publicBaseURL?.isEmpty ?? true {
            throw ValidationError("--url-mode cdn needs --public-base-url.")
        }
        if urlMode == .presigned, !(1...604_800).contains(presignExpires) {
            throw ValidationError("--presign-expires must be between 1 second and 7 days, which is the SigV4 limit.")
        }
    }

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

        print("retake: uploading to s3://\(bucket)/\(naming.runPrefix)")
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
            diffReport.reportURL = self.url(for: naming.reportKey, uploaded: url, with: s3)
            uploaded += 1
        }

        try diffReport.write(to: jsonURL)
        print("retake: uploaded \(uploaded) object\(uploaded == 1 ? "" : "s")")
        if let url = diffReport.reportURL { print("retake: report at \(url)") }
    }

    private func upload(_ file: URL, key: String, with s3: S3) async throws -> String {
        let data = try Data(contentsOf: file)
        // Immutable: every run writes to a fresh, timestamped prefix, so nothing at a
        // given URL ever changes.
        let objectURL = try await s3.put(
            data,
            key: key,
            contentType: "image/png",
            cacheControl: "public, max-age=31536000, immutable"
        )
        return url(for: key, uploaded: objectURL, with: s3)
    }

    private func url(for key: String, uploaded: URL, with s3: S3) -> String {
        switch urlMode {
        case .public:
            uploaded.absoluteString
        case .cdn:
            (publicBaseURL ?? "").hasSuffix("/")
                ? (publicBaseURL ?? "") + key
                : (publicBaseURL ?? "") + "/" + key
        case .presigned:
            s3.presignedURL(for: key, expiresIn: presignExpires).absoluteString
        }
    }
}
