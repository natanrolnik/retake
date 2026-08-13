# flexview

Renders the SwiftUI `#Preview`s in a repo to PNGs so a pull request can show what its UI
changes actually look like.

A preview is treated as affected **iff its rendering changed**. flexview renders on the
merge base and on the head and compares the images, rather than guessing which previews a
diff touches from file ownership. That is the only way to catch previews in *downstream*
modules: change a button in a design-system module and every screen that consumes it
changes too, without any of those files appearing in the diff.

Status: Phase 1 (rendering) is usable locally on macOS. Diffing, publishing, PR comments
and CI are not built yet.

## Requirements

- macOS 14+, Xcode 16+
- A **runner target** in the host repo (see below)

## Adding a runner target

flexview cannot render your previews from the outside: preview metadata only exists at
runtime, inside a binary that links your modules. So the host repo needs one small target
that links the modules you want rendered plus `FlexViewRuntime`.

On macOS the runner is a plain app, with no simulator and no XCTest involved. Its entire
source is:

```swift
import DesignSystem
import Feature
import FlexViewRuntime

// Keeps the linker from stripping modules whose symbols are unused here; their previews
// are only reachable through runtime metadata.
_ = PrimaryButton.self
_ = CheckoutScreen.self

MacRunner.main()
```

Make it an **app**, not a command line tool. Xcode then embeds and re-signs the
SnapshotPreviews framework with an identity matching the host, which a loose ad-hoc signed
binary does not get; macOS library validation rejects that combination at launch.

`Fixtures/SampleApp` is a complete working example, wired up with Tuist.

## Rendering

```bash
# Against a runner you already built
flexview render --runner path/to/PreviewRunner.app/Contents/MacOS/PreviewRunner --out ./snapshots

# Or let flexview build it
flexview render --scheme PreviewRunner --workspace App.xcworkspace --out ./snapshots
```

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
| `--timeout <seconds>` | Kill the runner if it hangs (default 600) |
| `--out <dir>` | Where PNGs and `manifest.json` go |

Previews that fail to render are recorded in `manifest.json` under `failures` rather than
being dropped, so a render failure can never be mistaken for a deleted preview later.

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
build graph's source list instead, and will be wired into `flexview scope`.

## Determinism

The pixel diff is worthless if rendering is noisy, so the renderer pins what it can:
appearance is forced rather than inherited, and the runner is an accessory app with no
Dock icon or menu bar to steal focus. Repeated renders of the same commit on one machine
produce byte-identical PNGs; this is verified in the fixture, and cross-machine
reproducibility is not yet established.

## Development

```bash
swift build
swift test

# Fixture end to end
cd Fixtures/SampleApp
tuist install && tuist generate --no-open
xcodebuild -workspace SampleApp.xcworkspace -scheme PreviewRunner \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath .derived build
cd ../..
swift run flexview render \
  --runner Fixtures/SampleApp/.derived/Build/Products/Debug/PreviewRunner.app/Contents/MacOS/PreviewRunner \
  --out /tmp/snapshots
```

The SnapshotPreviews dependency is pinned to a `main` revision rather than a tag: the
newest release (v0.9.4, August 2024) predates the runtime module filtering that scoping
needs.
