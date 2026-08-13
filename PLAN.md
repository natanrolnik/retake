# flexview — SwiftUI preview snapshots on pull requests

## Context

Reviewers approving UI changes on an iOS/macOS PR today have to trust the diff or build the branch locally. The goal is for a PR to show, inline, what its UI changes actually look like: the SwiftUI `#Preview`s affected by the change, rendered before and after.

The naive pipeline (changed files → owning targets → "affected" previews → snapshot) is rejected as the source of truth: file→target ownership misses previews in *downstream* targets that consume a changed leaf module, and target-level granularity over-includes badly. Instead **a preview is defined as affected iff its rendering changed**. We render previews on the merge base and on the head, and pixel-diff. The Tuist dependency graph survives only as a *cost optimization* to skip rendering previews that provably cannot be reached from the changed files.

Deliverable: a parameterized Swift CLI (`flexview`) usable locally, plus a thin GitHub Actions workflow that wraps it. Supports both iOS (simulator) and macOS (host) rendering.

## Constraints and decisions already made

- **Build system**: Tuist. The target graph comes from Tuist, not from parsing pbxproj.
- **Detection**: render base + head, pixel-diff. Must classify previews with no "before" (new previews) rather than dropping them.
- **Image hosting**: S3 / Cloudflare R2. GitHub's API cannot attach images to a comment, so inline images need real URLs; workflow artifacts can't be embedded.
- **Shape**: Swift CLI with parameters (scheme, simulator, layout/size), macOS supported.

## Two spikes to run before committing to the design

These are load-bearing and I have not verified them. Do these first; they can invalidate parts of Phase 2 and 3.

1. **Spike A — preview identity from EmergeTools/SnapshotPreviews.** Does its runtime renderer report a *source file path* per preview, or only module + display name? The whole diff hinges on a stable preview ID that matches across two commits. If we only get module + display name, unnamed previews and duplicate display names within a module are ambiguous, and we need a fallback ID (e.g. module + file + ordinal, recovered by cross-referencing a swift-syntax parse). Also confirm macOS rendering works on the host without a simulator, and whether previews can be filtered/allowlisted at runtime (needed for Phase 2 scoping to pay off at all).
2. **Spike B — Tuist graph extraction.** Confirm the exact command and JSON shape for dumping the target graph (`tuist graph` with a JSON format flag, or equivalent), including target→sources globs and target→dependencies. Verify we can map an arbitrary repo-relative file path to its owning target, which requires resolving each target's source globs.

If Spike A shows no usable per-preview file path, the fallback is Prefire (build-time codegen from previews, so identity is derived from source and inherently file-anchored) at the cost of a codegen step.

## Architecture

A single SPM executable `flexview` (swift-argument-parser), with the pipeline split into subcommands so each stage is runnable and testable alone.

```
flexview scope     --changed-files <file> [--graph <json>]   → affected-targets.json
flexview render    --scheme S --platform ios|macos [--simulator …] [--size WxH]
                                                  --out <dir>  → PNGs + manifest.json
flexview diff      --base <dir> --head <dir>       → report.json  (added/changed/removed/unchanged)
flexview publish   --report report.json --bucket … → report with URLs
flexview comment   --report report.json --pr N     → upserted PR comment
```

Rationale for subcommands over one monolith: the two render passes happen on different checkouts (and ideally the base pass is cache-hit and skipped entirely), so the orchestrator must be able to interleave them.

### Preview identity

Define `PreviewID = module + "/" + sourceFilePath + "#" + displayNameOrOrdinal`. Depends on Spike A. This ID is the join key for base↔head and the S3 object key prefix. Deliberately excludes line numbers so that moving a preview within a file doesn't read as remove+add.

## Phase 1 — Rendering (build this first, it's the risky half)

Package layout:

- `Sources/flexview/` — CLI entry, subcommand definitions.
- `Sources/FlexViewCore/Rendering/` — wraps SnapshotPreviews. Drives `xcodebuild test` against a generated snapshotting XCTest target for iOS; for macOS runs the equivalent host-side renderer without a simulator.
- `Sources/FlexViewCore/Manifest.swift` — `manifest.json`: array of `{ previewID, module, sourceFile, displayName, pngPath, sha256 }`.

Parameters exposed: `--scheme`, `--platform`, `--simulator` (device + OS), `--size`, `--derived-data`, `--timeout`. Render determinism matters more than anything here: pin the simulator device+OS, force light/dark explicitly rather than inheriting, and disable animations — otherwise the pixel diff produces noise on every run and the whole tool is worthless. Expect to iterate on this.

Ship Phase 1 as a usable local tool (`flexview render`) before touching CI.

## Phase 2 — Scoping (optional optimization, can be deferred)

- `Sources/FlexViewCore/Graph/` — parse the Tuist graph dump into targets + dependency edges; build the **reverse** dependency closure.
- `scope` takes the changed-file list, maps each file to its owning target via source globs, then computes that target plus all transitive dependents. Output is the set of targets whose previews could possibly be affected.
- Non-source changes (assets, resources, `Project.swift`, `Package.swift`, Tuist manifests) must **fall back to "everything in scope"** rather than being silently ignored.
- This only pays off if Spike A shows runtime filtering is possible; if not, we render everything and Phase 2 becomes a no-op we skip.

## Phase 3 — Diff and classification

`Sources/FlexViewCore/Diff/`:

- Join base and head manifests on `PreviewID`, producing four buckets:
  - **added** — in head only. This is the case you called out: there is no "before". Render a single image, label it *New preview*, no diff image. Always include these in the comment.
  - **removed** — in base only. Show the base image, label *Preview removed*. Cheap to report and catches accidental deletions.
  - **changed** — in both, PNG bytes differ.
  - **unchanged** — identical hash; excluded from the comment entirely.
- Fast path on sha256 equality before doing any per-pixel work.
- For **changed**, generate a third *diff* image (highlighted delta) alongside before/after, and record a changed-pixel percentage. Apply a small tolerance threshold to absorb residual renderer nondeterminism, configurable via `--tolerance`; log anything suppressed by the threshold so silent truncation is visible.

## Phase 4 — Publish and comment

- `Sources/FlexViewCore/Publish/` — upload PNGs to S3/R2 under `<repo>/<pr>/<sha>/<previewID-hash>.png`. Use presigned or public-read URLs per bucket policy. Set a lifecycle rule to expire old objects; note this in the README as required setup, since the bucket will otherwise grow forever.
- `Sources/FlexViewCore/Comment/` — render Markdown and upsert a **sticky comment** identified by an HTML marker comment (`<!-- flexview -->`), so pushes update one comment instead of spamming the thread. Prefer a comment over editing the PR description: the description is human-authored and clobbering it is hostile.
- Comment layout: a summary line (`3 changed · 1 new · 0 removed`), then a collapsed `<details>` per module, each preview as a three-column table (Before | After | Diff), with new previews as a single image.
- Cap the number of embedded images (e.g. 20) and link to the full set for the remainder — a 300-image comment is unusable. State the cap in the comment when it triggers.

## Phase 5 — GitHub Actions

`.github/workflows/preview-snapshots.yml`, plus a `action.yml` composite wrapper so other repos can `uses:` it.

- Trigger `pull_request`. Two jobs, or one job checking out both refs.
- **Base render caching is the main cost lever**: key a cache on the merge-base SHA + renderer version so the base pass is normally a cache hit and only head is rendered. Without this, every PR pays two full builds on expensive macOS runners.
- **Fork PRs**: `pull_request` from a fork has no access to secrets, so S3 credentials are unavailable. Handle explicitly — either the artifact + `workflow_run` pattern, or detect and post a comment saying snapshots are skipped for forks. Do not reach for `pull_request_target` casually; it runs untrusted code with secrets.
- Also cache DerivedData keyed on Tuist manifest + lockfile hashes.

## Files to be created

```
Package.swift
Sources/flexview/main.swift + <Subcommand>.swift per stage
Sources/FlexViewCore/Rendering/…      ← Phase 1
Sources/FlexViewCore/Graph/…          ← Phase 2
Sources/FlexViewCore/Diff/…           ← Phase 3
Sources/FlexViewCore/Publish/…        ← Phase 4
Sources/FlexViewCore/Comment/…        ← Phase 4
Tests/FlexViewCoreTests/…
action.yml
.github/workflows/preview-snapshots.yml
README.md
```

An example Tuist fixture app with a handful of previews across two targets (one leaf design-system module, one feature module consuming it) is needed to test any of this end to end.

## Verification

1. **Spikes first** — a throwaway Tuist fixture that renders one `#Preview` to PNG via SnapshotPreviews, and one Tuist graph dump inspected by hand. Report findings before proceeding.
2. **Unit tests** on the pure logic: reverse-dependency closure (including the non-source fallback-to-all case), manifest join producing correct added/removed/changed/unchanged buckets, Markdown rendering.
3. **Determinism check** — render the same commit twice, assert every PNG hash matches. If this fails, stop and fix rendering; nothing downstream is meaningful until it passes.
4. **Local end-to-end** on the fixture: render commit A, render commit B where only the design-system button changed, confirm the diff flags the feature-module previews that consume it (proving the downstream case the naive approach would miss), plus one newly-added preview classified as *added*.
5. **CI end-to-end** on a scratch PR in the fixture repo: verify the sticky comment appears, images load inline from the bucket, and a second push updates the same comment rather than adding one.

## Open items to decide later

- Multiple render variants per preview (light/dark, dynamic type sizes) multiply cost; start with one canonical variant and add axes only if wanted.
- Whether to fail the check on unreviewed visual changes, or keep it purely informational. Recommend informational to start.
