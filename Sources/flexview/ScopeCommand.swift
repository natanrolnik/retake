//
//  ScopeCommand.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser
import FlexViewCore
import Foundation

struct ScopeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scope",
        abstract: "Work out which modules a set of changed files could affect."
    )

    @Option(name: .long, help: "File listing changed paths, one per line. Use '-' for stdin.")
    var changedFiles: String

    @Option(name: .long, help: "Path to a `tuist graph --format json` dump.")
    var graph: String

    @Option(name: .long, help: "Repository root, used to resolve relative changed paths.")
    var root: String = FileManager.default.currentDirectoryPath

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Paths that provably cannot affect rendering. Each one is reported."
    )
    var ignore: [String] = []

    @Option(name: .shortAndLong, help: "Where to write affected-targets.json. Defaults to stdout only.")
    var out: String?

    func run() async throws {
        let targetGraph = try TuistGraphParser.parse(contentsOf: URL(fileURLWithPath: graph))
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL

        let paths = try readChangedFiles().map { absolute($0, relativeTo: rootURL) }
        let ignored = Set(ignore.map { absolute($0, relativeTo: rootURL) })

        let scope = ScopeResolver.resolve(
            graph: targetGraph,
            changedFiles: paths,
            ignored: ignored
        )

        for warning in scope.warnings {
            print("flexview: warning: \(warning)")
        }
        for path in paths where ignored.contains(path) {
            print("flexview: ignoring \(path)")
        }
        for reason in scope.reasons {
            print("flexview: \(reason)")
        }
        if scope.isEverything {
            print("flexview: rendering everything (\(targetGraph.targets.count) targets)")
        } else {
            print("flexview: \(scope.modules.count) modules in scope: \(scope.modules.joined(separator: ", "))")
        }

        if let out {
            let url = URL(fileURLWithPath: out)
            let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = url.hasDirectoryPath ? url.appendingPathComponent(Scope.fileName) : url
            try Manifest.encoder().encode(scope).write(to: destination)
        }
    }

    private func readChangedFiles() throws -> [String] {
        let contents = if changedFiles == "-" {
            String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else {
            try String(contentsOfFile: changedFiles, encoding: .utf8)
        }
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func absolute(_ path: String, relativeTo root: URL) -> String {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL.path
            : root.appendingPathComponent(path).standardizedFileURL.path
    }
}
