//
//  FlexView.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import ArgumentParser

@main
struct FlexView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flexview",
        abstract: "Render SwiftUI previews and diff them across commits.",
        subcommands: [
            Review.self, ScopeCommand.self, Render.self, Diff.self,
            Report.self, Publish.self, Comment.self, Verify.self,
        ]
    )
}
