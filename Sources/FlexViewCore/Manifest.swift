//
//  Manifest.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// Output of one render pass: what was rendered, where the PNGs are, and what failed.
public struct Manifest: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var configuration: RenderConfiguration
    public var entries: [ManifestEntry]
    /// Previews that were discovered but did not produce an image. Kept out of `entries`
    /// so a render failure never masquerades as a removed preview during the diff.
    public var failures: [ManifestFailure]

    public init(
        version: Int = Manifest.currentVersion,
        configuration: RenderConfiguration,
        entries: [ManifestEntry],
        failures: [ManifestFailure] = []
    ) {
        self.version = version
        self.configuration = configuration
        self.entries = entries.sorted { $0.previewID < $1.previewID }
        self.failures = failures.sorted { $0.previewID < $1.previewID }
    }
}

public struct RenderConfiguration: Codable, Sendable, Equatable {
    public var platform: RenderPlatform
    public var appearance: Appearance
    /// Device + OS for iOS runs; nil on macOS, which renders on the host.
    public var simulator: String?

    public init(platform: RenderPlatform, appearance: Appearance, simulator: String? = nil) {
        self.platform = platform
        self.appearance = appearance
        self.simulator = simulator
    }
}

public enum RenderPlatform: String, Codable, Sendable, CaseIterable {
    case ios
    case macos
}

public enum Appearance: String, Codable, Sendable, CaseIterable {
    case light
    case dark
}

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var previewID: PreviewID
    public var module: String
    public var sourceFile: String?
    public var line: Int?
    public var displayName: String?
    public var typeName: String
    /// PNG location, relative to the directory holding the manifest.
    public var pngPath: String
    public var sha256: String
    public var width: Double
    public var height: Double

    public init(
        previewID: PreviewID,
        module: String,
        sourceFile: String?,
        line: Int?,
        displayName: String?,
        typeName: String,
        pngPath: String,
        sha256: String,
        width: Double,
        height: Double
    ) {
        self.previewID = previewID
        self.module = module
        self.sourceFile = sourceFile
        self.line = line
        self.displayName = displayName
        self.typeName = typeName
        self.pngPath = pngPath
        self.sha256 = sha256
        self.width = width
        self.height = height
    }
}

public struct ManifestFailure: Codable, Sendable, Equatable {
    public var previewID: PreviewID
    public var module: String
    public var sourceFile: String?
    public var displayName: String?
    public var message: String

    public init(
        previewID: PreviewID,
        module: String,
        sourceFile: String?,
        displayName: String?,
        message: String
    ) {
        self.previewID = previewID
        self.module = module
        self.sourceFile = sourceFile
        self.displayName = displayName
        self.message = message
    }
}

public extension Manifest {
    static let fileName = "manifest.json"

    /// Every preview rendering to the same image means nothing was really rendered: the
    /// window was captured before any content reached it, or the host never handed the
    /// view over. It is worth its own check because the render otherwise reports
    /// complete success, and a diff of two such passes shows no changes at all.
    var rendersAreAllIdentical: Bool {
        entries.count > 1 && Set(entries.map(\.sha256)).count == 1
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    func write(to directory: URL) throws {
        let data = try Manifest.encoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Manifest.fileName))
    }

    static func read(from directory: URL) throws -> Manifest {
        let url = directory.appendingPathComponent(Manifest.fileName)
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
}
