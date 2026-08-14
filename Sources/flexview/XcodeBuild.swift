//
//  XcodeBuild.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation

enum XcodeBuild {
    static let path = "/usr/bin/xcodebuild"

    /// Builds the invocation, piping through xcbeautify when it is installed.
    ///
    /// A raw xcodebuild log is thousands of lines of clang invocations, which buries the
    /// few that matter. Falls back to running xcodebuild directly rather than making the
    /// formatter a requirement.
    static func command(arguments: [String], pretty: Bool) -> (executable: String, arguments: [String]) {
        guard pretty, let formatter = formatterPath() else {
            return (path, arguments)
        }
        return piped(arguments: arguments, through: formatter)
    }

    /// Split out from `command` so the quoting can be tested without xcbeautify installed.
    static func piped(arguments: [String], through formatter: String) -> (executable: String, arguments: [String]) {
        // pipefail so a build failure is not masked by the formatter exiting cleanly.
        let script = "set -o pipefail; "
            + ([path] + arguments).map(escaped).joined(separator: " ")
            + " | " + escaped(formatter)
        return ("/bin/bash", ["-c", script])
    }

    private static func formatterPath() -> String? {
        guard
            let result = try? Shell.run("/usr/bin/env", ["which", "xcbeautify"]),
            result.succeeded
        else {
            return nil
        }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func escaped(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
