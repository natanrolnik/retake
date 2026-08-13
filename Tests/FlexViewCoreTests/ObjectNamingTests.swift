//
//  ObjectNamingTests.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import Foundation
import Testing
@testable import FlexViewCore

private let moment = Date(timeIntervalSince1970: 1_786_650_900)  // 2026-08-13 19:55:00 UTC

private func naming(pr: Int? = 42, commit: String? = "a1b2c3d4e5f6") -> ObjectNaming {
    ObjectNaming(
        prefix: "flexview",
        repository: "natanrolnik/PocketUmpire",
        pullRequest: pr,
        commit: commit,
        timestamp: moment
    )
}

@Suite("Object naming")
struct ObjectNamingTests {
    @Test("A run has a readable, sortable, unique prefix")
    func runPrefix() {
        // Date and commit are both in the path: a re-run must not overwrite images that
        // an earlier comment still links to.
        #expect(naming().runPrefix == "flexview/pocketumpire/pr-42/20260813-195500-a1b2c3d")
    }

    @Test("Images are grouped by module and named after the preview")
    func imageKeys() {
        let id = PreviewID(rawValue: "Toss/TossView.swift#Toss - doubles")
        let key = naming().imageKey(previewID: id, module: "Toss", side: .after)

        #expect(key == "flexview/pocketumpire/pr-42/20260813-195500-a1b2c3d/toss/tossview-toss-doubles.after.png")
    }

    @Test("Each side of a comparison gets its own object")
    func sidesAreDistinct() {
        let id = PreviewID(rawValue: "Toss/TossView.swift#Toss")
        let keys = Set([ObjectNaming.Side.before, .after, .diff].map {
            naming().imageKey(previewID: id, module: "Toss", side: $0)
        })

        #expect(keys.count == 3)
    }

    @Test("Two runs of the same commit do not collide")
    func runsDoNotCollide() {
        let later = ObjectNaming(
            repository: "natanrolnik/PocketUmpire",
            pullRequest: 42,
            commit: "a1b2c3d4e5f6",
            timestamp: moment.addingTimeInterval(60)
        )

        #expect(naming().runPrefix != later.runPrefix)
    }

    @Test("A preview provider id, which has no file, still yields a usable name")
    func typeAnchoredID() {
        let id = PreviewID(rawValue: "Feature.Screen_Previews#0")
        let key = naming().imageKey(previewID: id, module: "Feature", side: .before)

        #expect(key.hasSuffix("/feature/feature-screen-previews-0.before.png"))
    }

    @Test("Keys are URL safe")
    func urlSafety() {
        let id = PreviewID(rawValue: "UI/Odd Name.swift#Spaces, commas & symbols!")
        let key = naming().imageKey(previewID: id, module: "Design System", side: .diff)

        #expect(key.allSatisfy { $0.isLowercase || $0.isNumber || "-/.".contains($0) })
    }

    @Test("Without a pull request the key still identifies the run")
    func noPullRequest() {
        #expect(naming(pr: nil).runPrefix == "flexview/pocketumpire/20260813-195500-a1b2c3d")
    }
}
