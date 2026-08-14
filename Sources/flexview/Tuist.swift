//
//  Tuist.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

/// How to invoke Tuist, and from where.
///
/// Two things make this less obvious than it looks. `tuist` on PATH is often a version
/// manager shim that resolves its version from the current directory, and flexview has
/// to operate on a git worktree that has no such config in it. So every command runs
/// from a directory where the version does resolve, and targets the other directory
/// with `--path` instead of changing into it.
struct Tuist {
    /// The command as written, for example `tuist` or `mise exec -- tuist`.
    var command: String
    /// Directory the command is launched from, chosen so a version manager can resolve.
    var workingDirectory: URL

    init(command: String, workingDirectory: URL) {
        self.command = command
        self.workingDirectory = workingDirectory
    }

    @discardableResult
    func run(_ arguments: [String], at path: URL? = nil, streamOutput: Bool = false) throws -> Shell.Result {
        var parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { throw Error.emptyCommand }

        // A bare name goes through env so PATH applies; a path is launched directly.
        let executable = parts.removeFirst()
        let launch = executable.contains("/") ? executable : "/usr/bin/env"
        let prefix = executable.contains("/") ? parts : [executable] + parts

        var allArguments = prefix + arguments
        if let path { allArguments += ["--path", path.path] }

        return try Shell.runChecked(
            launch,
            allArguments,
            currentDirectory: workingDirectory,
            streamOutput: streamOutput
        )
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case emptyCommand

        var description: String {
            "--tuist was empty; it must name an executable, for example 'tuist' or 'mise exec -- tuist'."
        }
    }
}
