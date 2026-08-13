//
//  S3.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import CryptoKit
import Foundation

/// Uploads objects to S3, signing requests with Signature Version 4.
///
/// Hand rolled rather than pulling in an SDK: flexview needs exactly one operation, and
/// the SDK would drag SwiftNIO into a build that runs on every pull request.
struct S3 {
    var bucket: String
    var region: String
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    /// Overrides the endpoint for S3-compatible services. Nil uses AWS.
    var endpoint: URL?

    enum Error: Swift.Error, CustomStringConvertible {
        case missingCredentials
        case badResponse(key: String, status: Int, body: String)

        var description: String {
            switch self {
            case .missingCredentials:
                """
                No credentials. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY \
                (and AWS_SESSION_TOKEN if you use temporary credentials).
                """
            case .badResponse(let key, let status, let body):
                "Uploading \(key) failed with HTTP \(status): \(body.prefix(400))"
            }
        }
    }

    static func fromEnvironment(
        bucket: String,
        region: String,
        endpoint: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> S3 {
        guard
            let accessKeyID = environment["AWS_ACCESS_KEY_ID"],
            let secretAccessKey = environment["AWS_SECRET_ACCESS_KEY"],
            !accessKeyID.isEmpty, !secretAccessKey.isEmpty
        else {
            throw Error.missingCredentials
        }
        return S3(
            bucket: bucket,
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: environment["AWS_SESSION_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
            endpoint: endpoint
        )
    }

    /// Returns the public URL of the uploaded object.
    @discardableResult
    func put(_ data: Data, key: String, contentType: String, cacheControl: String? = nil) async throws -> URL {
        let url = objectURL(for: key)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let cacheControl { request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control") }
        sign(&request, payload: data)

        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Error.badResponse(key: key, status: status, body: String(decoding: body, as: UTF8.self))
        }
        return url
    }

    func objectURL(for key: String) -> URL {
        let encoded = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.encode(String($0)) }
            .joined(separator: "/")
        if let endpoint {
            return endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
        }
        return URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(encoded)")!
    }

    // MARK: - Signing

    private func sign(_ request: inout URLRequest, payload: Data) {
        let now = Date()
        let timestamp = Self.timestampFormatter.string(from: now)
        let day = String(timestamp.prefix(8))
        let host = request.url!.host!
        let payloadHash = Self.hex(SHA256.hash(data: payload))

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }

        // Signed headers must be sorted by lowercased name, and their values trimmed.
        var headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", timestamp),
        ]
        if let sessionToken { headers.append(("x-amz-security-token", sessionToken)) }
        if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
            headers.append(("content-type", contentType))
        }
        headers.sort { $0.0 < $1.0 }

        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let canonicalRequest = [
            "PUT",
            request.url!.path.split(separator: "/", omittingEmptySubsequences: false)
                .map { Self.encode(String($0)) }
                .joined(separator: "/"),
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for component in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(component.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// RFC 3986 encoding, which is stricter than `addingPercentEncoding` defaults.
    private static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
