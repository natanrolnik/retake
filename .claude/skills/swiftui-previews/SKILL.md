---
name: swiftui-previews
description: Renders SwiftUI #Previews to PNGs so you can see what a view actually looks like, and what a change did to it, instead of inferring it from code. Use when editing SwiftUI views, when asked whether a change looks right, when a design tweak needs checking against the previous rendering, or when reviewing a pull request that touches UI.
---

# See what SwiftUI previews actually render

Reading SwiftUI code tells you what it should draw. `retake` renders it and hands you a
PNG, which is the only way to know. Use it whenever a claim about appearance would
otherwise be a guess.

## Install

```bash
mise use -g github:natanrolnik/retake@0.7.7
```

Or per project, pinned in `mise.toml`:

```bash
mise use github:natanrolnik/retake@0.7.7
```

Check it and the machine's simulators:

```bash
retake --help
retake simulator          # prints the simulator it would pick
```

Requires macOS with Xcode, and Tuist on PATH. **The repository does not have to use
Tuist** — retake needs it to generate a throwaway host project, and works from either a
Tuist graph or local Swift packages. Nothing is added to the repository under review.

## The loop while editing a view

After changing a SwiftUI file, render exactly its previews:

```bash
retake snapshot --repo . --files Sources/Feature/CheckoutScreen.swift --out /tmp/previews
```

Then **read the PNGs** in `/tmp/previews/snapshots/` — actually look at them, do not
assume the change landed. `--files` works out which module owns the file, so this builds
one module rather than the world. Pass several files if a change spans them.

Iterate: edit, re-render, look again.

For a repository with no Tuist project, point at its packages instead:

```bash
retake snapshot --repo . --packages Packages/DesignSystem --out /tmp/previews
```

## Seeing what a change did

To compare against another commit, rather than just look at the current state:

```bash
retake review --repo . --base main --out /tmp/review
open /tmp/review/report.html
```

This renders the merge base and the working tree, then reports each preview as changed,
new or removed. It catches previews the diff never mentions: change a button in a design
system module and every screen consuming it is rendered and compared, without any of
those files appearing in the change.

Locally it includes uncommitted work, which is the point of running it before committing.

## Reading the output like a machine

Everything is JSON beside the images:

- `<out>/snapshots/manifest.json` — one entry per preview: id, module, source file, line,
  display name, PNG path, sha256, dimensions
- `<out>/report.json` — the same in report form, with a `change` per preview
- `<out>/snapshots/*.png` — the images, named after the preview

```jsonc
{
  "previewID": "Feature/CheckoutScreen.swift#Checkout",
  "module": "Feature",
  "sourceFile": "Feature/CheckoutScreen.swift",
  "pngPath": "Feature-CheckoutScreen.swift-Checkout.png",
  "sha256": "0222f6b1…", "width": 402, "height": 874
}
```

## What to check before trusting a render

- **`failures` is never empty for free.** A preview that failed to render is listed there,
  not dropped, so a broken preview cannot be mistaken for a missing one. Read it.
- **"every preview rendered to an identical image" means nothing drew.** retake says so
  loudly. A comparison of two such passes would report no changes at all.
- **Unstable previews are excluded, and can hide a real change.** With `--verify`, a
  preview that renders differently twice on the same commit is reported as `unstable`
  rather than compared. A view loading images or drawing a map or the current time lands
  there. `--settle` fixes most of it; content built from `Date()` needs a fixed date.
- **Previews inside an app extension, app clip or watch app are unreachable.** An embedded
  bundle runs as its own process, so its previews never appear. retake warns and skips.

## Flags worth knowing

| Flag | When |
| --- | --- |
| `--files` | The tight loop: only the previews in these files |
| `--modules` | Whole modules, when a file list is awkward |
| `--hosts` | Which app targets may host previews, when the repository has several apps |
| `--settle` | Content that arrives after the first frame: async loads, remote images |
| `--verify` | Render twice and exclude previews that do not reproduce |
| `--simulator` | Pin the device; omitted, retake picks the newest available iPhone and prints it |

## Do not

- Do not claim a view looks a certain way without rendering it and reading the PNG.
- Do not report a preview as unchanged when it is in the `unstable` bucket — it was
  excluded from the comparison, not compared and found equal.
- Do not add a snapshot target, scheme or dependency to the repository to make this work.
  It generates its own throwaway host and deletes it.
