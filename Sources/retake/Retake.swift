//
//  Retake.swift
//  retake
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser

@main
struct Retake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retake",
        abstract: "Render SwiftUI previews and diff them across commits.",
        subcommands: [
            Review.self, Snapshot.self, ScopeCommand.self, Render.self, Diff.self,
            Report.self, Publish.self, Comment.self, Verify.self,
        ]
    )
}
