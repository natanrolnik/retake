# retake

Renders the SwiftUI `#Preview`s in a repo to PNGs so a pull request can show what its UI
changes actually look like.

A preview is treated as affected **iff its rendering changed**. retake renders on the
merge base and on the head and compares the images, rather than guessing which previews a
diff touches from file ownership. That is the only way to catch previews in *downstream*
modules: change a button in a design-system module and every screen that consumes it
changes too, without any of those files appearing in the diff.

**iOS needs no changes to your repository.** retake generates its own throwaway Tuist
project to host the previews, renders through it, and deletes it, so there is no snapshot
target to maintain and nothing added to your dependency graph. macOS still needs a small
runner target, described below.

## Requirements

- macOS 14+, Xcode 16+
- A Tuist project

## macOS

macOS renders on the host: no simulator, no XCTest. retake does not yet generate the
host project for macOS the way it does for iOS, so this is the one case where a
repository adds a target of its own. `Fixtures/SampleMac` is a complete working example.

```bash
xcodebuild -workspace SampleMac.xcworkspace -scheme PreviewRunner \
  -destination 'platform=macOS' -derivedDataPath .derived build
retake render --platform macos \
  --runner .derived/Build/Products/Debug/PreviewRunner.app/Contents/MacOS/PreviewRunner \
  --out ./snapshots
```

## How rendering works

Preview metadata only exists at runtime, inside a process that links your modules, so
something has to host them. On iOS retake writes a throwaway Tuist project into a
scratch directory, links your existing targets by path, renders through an XCTest bundle
in the simulator, and deletes the directory. Your manifests are never touched.

Which host it picks follows what previews need to be reachable:

- an app in scope hosts them itself, since one app cannot link another;
- frameworks only, and it synthesises an empty app linking just those frameworks, so a
  leaf change never builds the whole app.

```bash
retake review --repo . --base main --out ./out --simulator "iPhone 17"
```

That is the whole loop: render the merge base in a git worktree, render the working tree,
diff, and write the report. Individual stages are available as `scope`, `render`, `diff`,
`report`, `publish`, `comment` and `verify`.

Output is a directory of PNGs plus `manifest.json`, one entry per preview:

```json
{
  "previewID": "Feature/CheckoutScreen.swift#Checkout",
  "module": "Feature",
  "sourceFile": "Feature/CheckoutScreen.swift",
  "line": 28,
  "displayName": "Checkout",
  "pngPath": "Feature-CheckoutScreen.swift-Checkout.png",
  "sha256": "0222f6b1…",
  "width": 147,
  "height": 125
}
```

Useful options:

| Option | Meaning |
| --- | --- |
| `--appearance light\|dark` | Forced, never inherited from the host |
| `--modules A B C` | Render only these modules |
| `--timeout <seconds>` | Kill the runner if it hangs |
| `--settle` | Wait for asynchronously loaded content before capturing |
| `--out <dir>` | Where PNGs and `manifest.json` go |

Previews that fail to render are recorded in `manifest.json` under `failures` rather than
being dropped, so a render failure can never be mistaken for a deleted preview later.

## Diffing

```bash
retake diff --base ./snapshots-base --head ./snapshots-head --out ./report
```

Every preview lands in exactly one of four buckets:

| Bucket | Meaning | In the comment |
| --- | --- | --- |
| `added` | Head only. There is no "before". | One image, labelled *New preview* |
| `removed` | Base only. Catches accidental deletions. | The base image |
| `changed` | Both sides, pixels differ | Before, After, Diff |
| `unchanged` | Identical, or below the tolerance | Excluded |

Entries with matching SHA-256 settle without any per-pixel work; only the rest are
compared pixel by pixel. Changed previews get a third *diff* image, magenta over a washed
out copy of the head render, plus a changed-pixel percentage.

Two knobs absorb renderer nondeterminism:

- `--pixel-threshold <0-255>` — per-channel delta below which two pixels count as equal.
- `--tolerance <percent>` — changed-pixel percentage at or below which a preview is filed
  as unchanged.

Anything the tolerance suppresses is printed and flagged in `report.json` with
`suppressedByTolerance`, so threshold truncation is never silent. A preview whose
dimensions changed is never suppressed, however few pixels differ.

Previews that failed to render are reported in their own bucket rather than appearing as
removals.

## HTML report

```bash
retake diff --base ./base --head ./head --out ./report --html report.html
# or, from an existing report.json
retake report --report ./report/report.json --out report.html
```

One self-contained file: images are inlined as data URIs, so it works as a CI artifact, an
email attachment, or a local `open`, with no sibling PNG directory and no server. It groups
previews by module, shows Before / After / Diff side by side, renders new previews as a
single image, and follows the reader's light or dark mode.

`--no-inline-images` links to the PNGs on disk instead, for when file size matters more
than portability. `--include-unchanged` adds the previews that did not move.

## Preview identity

Comparing two renders needs an ID that survives unrelated edits. The runtime offers two
kinds of preview, and they need different treatment:

- **`#Preview` macro** — reported with a `#fileID` and a line number. The ID is
  `Module/File.swift#DisplayName`. Unnamed previews, and names repeated inside one file,
  fall back to an ordinal in source order (`#@0`).
- **`PreviewProvider`** — no file info, so the ID is the declared type name plus the index
  in `_allPreviews`, e.g. `Feature.Screen_Previews#0`.

The mangled runtime type name is deliberately **not** used. For macro previews it encodes
the source line, so adding a line above a preview would make it read as a removal plus an
addition.

### Known limitation: same-basename files

`#fileID` carries only a basename, so two files named `Widget.swift` in one module are
indistinguishable at runtime and share one ordinal space. Named previews are unaffected;
unnamed ones in those files can shift identity when the other file changes. SPM rejects
duplicate basenames outright, but Xcode and Tuist targets allow them.

This is undetectable from inside the runner. `SourceBasenameCollision` finds it from the
build graph's source list instead, and will be wired into `retake scope`.

## Determinism

The pixel diff is worthless if rendering is noisy, so the renderer pins what it can:
appearance is forced rather than inherited, and the runner has no Dock icon or menu bar to
steal focus.

That is not enough on its own. A view whose content arrives asynchronously — a RealityKit
scene, a `.task` load — renders two different pictures on the same commit, and then shows
up as a change nobody made. Measure it rather than assume it:

```bash
retake verify --graph graph.json --modules Toss --runs 3 --out ./verify
```

It exits non-zero when a preview is not reproducible, so CI can gate on it. `--settle`
fixes most cases by waiting for that content to arrive, at about two seconds per preview.
`retake diff --verify <second render of head>` files anything still unstable in its own
bucket instead of reporting it as a change.

## Continuous integration

`action.yml` is a composite action. The report is uploaded as an artifact and repeated in
the job summary; with `s3-bucket` set, images are uploaded and the comment shows them
inline. `s3-url-mode` chooses between `public`, `cdn` and `presigned`.

See `.github/workflows/preview-snapshots.yml` for a working example, including assuming an
AWS role by OIDC rather than storing a key.

## Development

```bash
swift build
swift test

# iOS fixture, end to end, without touching the fixture
cd Fixtures/SampleApp && tuist graph --format json --no-open --output-path /tmp/fx && cd ../..
swift run retake render --platform ios --graph /tmp/fx/graph.json \
  --simulator "iPhone 17" --out /tmp/snapshots
```

The SnapshotPreviews dependency is pinned to a `main` revision rather than a tag: the
newest release (v0.9.4, August 2024) predates the runtime module filtering that scoping
needs.
