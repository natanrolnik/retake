# retake

Renders the SwiftUI `#Preview`s in a repository to PNGs, so you can see what a change
actually looks like instead of imagining it from a diff.

A preview is treated as affected **iff its rendering changed**. retake renders the merge
base and the head and compares the images, rather than guessing which previews a diff
touches from file ownership. That is the only way to catch previews in *downstream*
modules: change a button in a design system module and every screen that consumes it
changes too, without any of those files appearing in the diff.

**Nothing is added to the repository under review.** On iOS, retake generates a throwaway
Tuist project to host the previews, renders through it, and deletes it. No snapshot target
to maintain, nothing added to your dependency graph.

## Requirements

- macOS 14+, Xcode 16+
- Tuist installed. Your repository does not have to *use* Tuist: retake needs it to
  generate the throwaway host project, and works from either a Tuist graph or local
  Swift packages
- Previews written with the `#Preview` macro. `PreviewProvider` works too, with the
  caveats under [Preview identity](#preview-identity).

## Install

```bash
mise use -g github:natanrolnik/retake@0.7.7
```

Or build it:

```bash
git clone https://github.com/natanrolnik/retake && cd retake
swift build -c release --product retake
```

The release tarball carries more than the binary: retake compiles its runtime, and
SnapshotPreviews, into the project it generates, so those sources ship beside the
executable and are found relative to it.

## Quick start

See what a file draws:

```bash
retake snapshot --repo . --files Sources/DesignSystem/Button.swift --out ./out
open ./out/report.html
```

See what a change did:

```bash
retake review --repo . --base main --out ./out
open ./out/report.html
```

Neither needs a simulator named, a module list, or a scheme.

---

## Commands

### `snapshot` — what is there

Renders the current state and writes a catalogue: one image per preview, grouped by
module. No comparison, no base commit.

```bash
retake snapshot --repo . --out ./out                          # everything
retake snapshot --repo . --modules DesignSystem --out ./out   # one module
retake snapshot --repo . --files A.swift B.swift --out ./out  # specific files
```

`--files` works out which modules own those files, so checking one file builds one module
rather than the world.

#### Repositories that do not use Tuist

Point it at local Swift packages instead of a graph. The generated host then stands on its
own, declaring those packages as dependencies, so a plain Xcode project with packages
beside it works without changing anything:

```bash
retake snapshot --repo . --packages Packages/DesignSystem Packages/StatusKit --out ./out
```

Previews living in the Xcode app target itself are out of reach this way, since only the
packages are linked.

### `review` — what changed

The whole loop in one command: render the merge base from a detached git worktree, render
the working tree, diff, and write the report.

```bash
retake review --repo . --base main --out ./out
```

With a clean tree the base is checked out in place, so both renders share one
DerivedData: it is keyed by project path, so a worktree somewhere else reuses nothing and
compiles the world twice. With uncommitted changes the base goes to a worktree instead and
your checkout is left alone, because reviewing work you have not committed yet is the
point of running it locally.

Useful flags: `--modules`, `--hosts`, `--settle`, `--verify`, `--tolerance`,
`--reuse-base`, `--ignore`.

### `verify` — is rendering trustworthy here

Renders the same commit several times and reports previews whose pixels move. Exits
non-zero when any do, so CI can gate on it.

```bash
retake verify --graph graph.json --modules Toss --runs 3 --out ./verify
```

Worth running once per module before trusting a report. A view whose content arrives
asynchronously renders two different pictures on the same commit and then shows up as a
change nobody made. `--settle` fixes most of those, at about two seconds per preview.

### The individual stages

`review` is these, in order. Use them directly when you need to interleave the passes,
such as caching the base render in CI.

| Command | Does |
| --- | --- |
| `scope` | Maps changed files to the modules whose previews could be affected |
| `render` | Renders previews to PNGs plus `manifest.json` |
| `diff` | Joins two render passes into added / removed / changed / unchanged |
| `report` | Renders a diff report as one self-contained HTML file |
| `publish` | Uploads the images to S3 and records their URLs |
| `comment` | Renders the report as Markdown, and upserts a pull request comment |
| `simulator` | Prints the simulator retake would use |

---

## For agents

`snapshot --files` is the tight loop: edit a view, render exactly its previews, look at
the result. It needs no scheme, no simulator and no base revision, and builds only the
module that owns the file.

A Claude Code skill ships this as a workflow, in
[`.claude/skills/swiftui-previews`](.claude/skills/swiftui-previews/SKILL.md). Copy that
directory into a repository to give an agent working there the install step, the loop, and
the failure modes worth checking before believing a render.

```bash
retake snapshot --repo . --files Sources/Feature/CheckoutScreen.swift --out /tmp/out
```

Everything is machine readable:

- `/tmp/out/snapshots/manifest.json` — one entry per preview: id, module, source file,
  line, display name, PNG path, sha256, dimensions
- `/tmp/out/report.json` — the same in report form
- `/tmp/out/snapshots/*.png` — the images, named after the preview

```jsonc
{
  "previewID": "Feature/CheckoutScreen.swift#Checkout",
  "module": "Feature",
  "sourceFile": "Feature/CheckoutScreen.swift",
  "line": 28,
  "pngPath": "Feature-CheckoutScreen.swift-Checkout.png",
  "sha256": "0222f6b1…",
  "width": 402, "height": 874
}
```

Three things worth knowing before trusting the output:

- **Previews that fail to render are listed under `failures`**, never dropped, so a broken
  preview cannot be mistaken for a missing one.
- **If every preview renders to an identical image, retake says so loudly.** That means
  nothing actually drew, and a diff of two such passes would report no changes at all.
- **A preview that crashes the process costs one preview, not the run.** retake records
  what was in flight, restarts past it, and names it in `failures`.

---

## GitHub Actions

The simplest useful setup: render, upload the report as an artifact, and comment.

```yaml
name: Preview Snapshots
on:
  pull_request:
    branches: [main]

concurrency:
  group: preview-snapshots-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write

jobs:
  snapshots:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # the merge base has to be reachable

      - uses: jdx/mise-action@v2  # retake requires Tuist, and does not install it
      - run: tuist install

      - uses: natanrolnik/retake@0.7.7
        with:
          hosts: MyApp
```

That produces a `retake-report` artifact and a sticky pull request comment linking to it.

### Showing the images in the comment

A workflow artifact is a zip behind an authenticated endpoint, so nothing inside it can be
an image source in a comment. Inline images need a bucket.

```yaml
    permissions:
      contents: read
      pull-requests: write
      id-token: write             # to mint the OIDC token

    steps:
      # …checkout, mise, tuist install…

      - uses: aws-actions/configure-aws-credentials@v4
        if: github.event.pull_request.head.repo.full_name == github.repository
        with:
          role-to-assume: arn:aws:iam::<account>:role/retake-ci
          aws-region: us-east-1

      - uses: natanrolnik/retake@0.7.7
        with:
          hosts: MyApp
          s3-bucket: my-preview-snapshots
          s3-region: us-east-1
          s3-url-mode: presigned  # public | cdn | presigned
          s3-presign-expires: '86400'
```

`s3-url-mode` is a decision about who can see unreleased UI:

| Mode | Bucket | Trade-off |
| --- | --- | --- |
| `public` | World readable | Simplest; anyone with the URL sees the images |
| `cdn` | Behind `s3-public-base-url` | A custom domain or CDN in front |
| `presigned` | Fully private | URLs expire, capped at 7 days by SigV4 |

Set a **lifecycle rule** expiring the prefix. Every push writes a fresh timestamped
prefix, so the bucket grows forever without one.

Pull requests from forks get no OIDC token and no secrets, so publishing and commenting
are skipped there. The artifact and the job summary are still produced.

### Inputs worth setting

| Input | Why |
| --- | --- |
| `hosts` | Which app targets may host previews. Without it every app in scope becomes its own render pass, which matters if you have per-module preview apps |
| `settle` | Waits for asynchronously loaded content. Needed for RealityKit scenes, `.task` loads, decoded images |
| `verify` | Renders head twice and excludes previews that do not reproduce. A third more macOS minutes |
| `ignore` | Globs for files that cannot affect rendering. Defaults cover `.github`, markdown and docs; without them a single unowned file widens the scope to everything |
| `cache-profile` | Tuist binary cache profile, so dependencies come from prebuilt binaries |
| `simulator` | Pins the device. Omitted, retake picks the runner's newest available iPhone and prints it |

### Running it only when you ask

Rendering twice is expensive, and most pull requests do not touch the UI. Gate it on a
label so it is opt-in, and allow a manual run for anything else:

```yaml
on:
  pull_request:
    # labeled, so adding the label starts a run on a pull request already open.
    types: [opened, synchronize, reopened, labeled]
  workflow_dispatch:
    inputs:
      pr:
        description: Pull request number to render
        required: true

jobs:
  snapshots:
    # On a pull request, only with the label. A manual run is the ask.
    if: >
      github.event_name == 'workflow_dispatch' ||
      contains(github.event.pull_request.labels.*.name, 'Preview Snapshots')
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          # A dispatched run has no pull request context, so the merge ref is fetched by
          # number. retake reads the base from the merge commit's first parent, which is
          # how it works on a pull_request event too.
          ref: ${{ github.event_name == 'workflow_dispatch' && format('refs/pull/{0}/merge', inputs.pr) || '' }}

      # …mise, tuist install…

      - uses: natanrolnik/retake@0.7.7
        with:
          hosts: MyApp
          # Empty on a dispatched run unless passed, and without it there is no pull
          # request to comment on.
          pr-number: ${{ github.event.pull_request.number || inputs.pr }}
```

### Outputs

The action reports what it found, so later steps do not have to re-read the report.

| Output | Example | Meaning |
| --- | --- | --- |
| `has-changes` | `true` | Anything changed, added or removed. The one most workflows want |
| `summary` | `1 changed · 1 new · 0 removed · 8 unstable` | The same line the comment leads with |
| `changed` / `new` / `removed` | `1` / `1` / `0` | Counts per bucket |
| `unchanged` / `total` | `44` / `54` | Everything compared |
| `unstable` | `8` | Previews excluded for not reproducing. Only ever non-zero with `verify` |
| `failures` | `0` | Previews that failed to render at all |
| `report` / `report-json` | `/Users/runner/work/_temp/retake/report.html` | Paths on the runner |
| `report-url` | `https://…` | Published URL, empty unless `s3-bucket` is set |

Give the step an `id` and read them:

```yaml
      - uses: natanrolnik/retake@0.7.7
        id: previews
        with:
          hosts: MyApp

      - name: Label the pull request when the UI moved
        if: steps.previews.outputs.has-changes == 'true'
        run: gh pr edit "$PR" --add-label ui-changed
        env:
          PR: ${{ github.event.pull_request.number }}
          GH_TOKEN: ${{ github.token }}

      - name: Tell the team
        if: steps.previews.outputs.has-changes == 'true'
        run: |
          curl -sS -X POST "$SLACK_WEBHOOK" -d @- <<JSON
          {"text": "${{ steps.previews.outputs.summary }} — ${{ steps.previews.outputs.report-url }}"}
          JSON
```

`unstable` is worth watching rather than ignoring. A preview that does not reproduce is
excluded from the comparison, so a real change can hide inside that count — a view whose
content arrives asynchronously, or one drawing a map, will sit there indefinitely. Failing
a job on it is usually too strict; surfacing it is not:

```yaml
      - name: Warn about previews that cannot be compared
        if: steps.previews.outputs.unstable != '0'
        run: echo "::warning::${{ steps.previews.outputs.unstable }} previews did not reproduce and were excluded. Try settle, or check for a map or an async load."
```

Counts come from `report.json` and are never fatal: if it cannot be parsed the outputs are
empty and the job still keeps its render.

### What it costs

The dominant cost is the simulator: booting one on a cold runner takes minutes, and the
job renders twice. Two levers matter, and the action applies both.

- The **base render is cached on the merge base**, so a typical push renders only head.
- The **binary is installed, not built**, and cached by mise.

---

## How rendering works

Preview metadata only exists at runtime, inside a process that links your modules, so
something has to host them. retake writes a throwaway Tuist project into a scratch
directory, links your existing targets by path, renders through an XCTest bundle in the
simulator, and deletes the directory.

An app hosts only the previews declared in the app target itself, since one app cannot
link another. Every other module renders in a synthesised app that links it directly.

That holds even when an app in scope already links the module, and the reason is the
linker: a static framework contributes only the object files something references. A
preview in a file the host app never touches is dropped, and then it does not exist at
runtime to be found — a silent false negative, with nothing in the report to suggest
anything is missing. The synthesised host passes `-all_load`, so every object file
survives. It is also the cheaper build for a leaf change.

Modules are partitioned across hosts, so a module shared by several apps renders exactly
once, in the first of them by name. That assignment is stable between the base and head
passes; an unstable one would make every preview in a moved module look changed.

### macOS

macOS renders on the host: no simulator, no XCTest. retake does not generate the host
project for macOS yet, so this is the one case where a repository adds a target of its
own. `Fixtures/SampleMac` is a complete working example.

```bash
retake render --platform macos \
  --runner .derived/Build/Products/Debug/PreviewRunner.app/Contents/MacOS/PreviewRunner \
  --out ./snapshots
```

---

## Preview identity

Comparing two renders needs an id that survives unrelated edits. The runtime reports two
kinds of preview, and they need different treatment:

- **`#Preview` macro** — reported with a `#fileID` and a line number. The id is
  `Module/File.swift#DisplayName`. Unnamed previews, and names repeated inside one file,
  fall back to an ordinal in source order (`#@0`).
- **`PreviewProvider`** — no file information, so the id is the declared type name plus
  the index in `_allPreviews`, e.g. `Feature.Screen_Previews#0`.

The mangled runtime type name is deliberately **not** used. For macro previews it encodes
the source line, so adding a line above a preview would read as a removal plus an
addition.

Two consequences for `PreviewProvider`: it cannot be filtered with `--files`, and it is
not anchored to a file.

### Known limitation: same-basename files

`#fileID` carries only a basename, so two files named `Widget.swift` in one module are
indistinguishable at runtime and share one ordinal space. Named previews are unaffected;
unnamed ones in those files can shift identity when the other file changes. SPM rejects
duplicate basenames, but Xcode and Tuist targets allow them. retake detects this from the
build graph and warns.

---

## Determinism

The pixel diff is worthless if rendering is noisy, so the renderer pins what it can:
appearance is forced rather than inherited, and the runner has no Dock icon or menu bar to
steal focus.

That is not enough on its own, and the failure is quiet: a view whose content arrives
asynchronously renders two different pictures on the same commit. Measure it rather than
assume it — `retake verify` exists for exactly this, and `--settle` fixes most cases.

Two knobs absorb what is left: `--pixel-threshold` for per-channel jitter, and
`--tolerance` for the changed-pixel percentage. Anything either suppresses is printed and
flagged in `report.json`, so threshold truncation is never silent.

---

## Development

```bash
swift build
swift test

# The iOS fixture, end to end, without touching the fixture
swift run retake snapshot --repo Fixtures/SampleApp --out /tmp/out
```
