---
title: "fix: Prevent brew pr-pull from creating duplicate GitHub Releases"
type: fix
status: completed
date: 2026-04-03
deepened: 2026-04-13
---

# fix: Prevent brew pr-pull from creating duplicate GitHub Releases

> **Note (2026-04-13):** This plan was updated to reflect what actually shipped. The implemented approach differs from
> the original plan: rather than creating a draft release and undrafting it before `brew pr-pull` (original Unit 1),
> `rust-release.yml` now creates the release as **non-draft with `make_latest: false`** from the start. `brew pr-pull`
> finds it by tag naturally, and `rust-finalize-release.yml` flips `make_latest: true` at the end. Unit 1 (undraft step
> in homebrew-tap's `publish.yml`) was **superseded and not implemented** — see "Approach evolution" below.

## Overview

Eliminate draft releases from the release pipeline. `rust-release.yml` creates a non-draft GitHub Release with
`make_latest: false`, so `brew pr-pull` finds the existing release by tag and uploads bottles to it instead of creating
a duplicate. `rust-finalize-release.yml` then flips `make_latest: true` after bottles are uploaded.

Two changes total, both in **this repo** (`brettdavies/.github`). `brew pr-pull` and homebrew-tap's `publish.yml` stay
untouched.

## Approach evolution

| Aspect | Original plan (2026-04-03) | Shipped approach |
|--------|----------------------------|------------------|
| Source release state at creation | Draft (`draft: true`) | Non-draft (`make_latest: false`) |
| How `brew pr-pull` finds the release | Undraft step in `publish.yml` flips draft just before `pr-pull` | Already non-draft — no extra step needed |
| `finalize-release` responsibility | Publish draft + set `make_latest=true` (idempotent fallback for already-published) | Flip `make_latest=true` (idempotent fallback for draft) |
| Files touched in `homebrew-tap` | `publish.yml` (new undraft step) | None |
| Files touched in `brettdavies/.github` | `rust-finalize-release.yml` | `rust-release.yml` **and** `rust-finalize-release.yml` |

Why the change: removing drafts entirely is simpler than coordinating an undraft step across repos and avoids the brief
"release visible without bottles" window discussed in the original Resolved Questions.

## Problem Frame

`brew pr-pull` uses `GET /repos/{owner}/{repo}/releases/tags/{tag}` to find an existing release for bottle uploads. This
GitHub API endpoint does not return draft releases (drafts have no published tag). So `brew pr-pull` gets a 404 and
creates a brand new non-draft release, resulting in two releases for the same tag.

Shipped fix: don't create drafts in the first place. `rust-release.yml` creates the release as non-draft with
`make_latest: false`, so it is findable by tag from the moment it exists. `brew pr-pull` finds it, uploads bottles to
it. `rust-finalize-release.yml` then flips `make_latest: true` once bottles are in place. No duplicate. One release per
tag at all times.

This hit during the xurl-rs v1.1.0 release and required manual intervention. It will recur on every release until fixed.

## Requirements Trace

- R1. `publish.yml` uploads bottles to the existing release, not a new one
- R2. No duplicate releases created during the release pipeline
- R3. Formula `root_url` points to the source repo release, not `homebrew-tap/releases/`
- R4. Pipeline works end-to-end without manual intervention
- R5. Retries are idempotent

## Scope Boundaries

- `.github/workflows/rust-release.yml` (this repo): create non-draft release with `make_latest: false`
- `.github/workflows/rust-finalize-release.yml` (this repo): make idempotent, flip `make_latest: true` at the end
- No changes to `update-formula.yml`, `tests.yml`, or homebrew-tap's `publish.yml`
- `brew pr-pull` invocation stays exactly as-is

### Deferred to Separate Tasks

- None. Original Unit 1 (undraft step in `brettdavies/homebrew-tap/.github/workflows/publish.yml`) was superseded by the
  shipped approach and is no longer needed.

## Context & Research

### Relevant Code and Patterns

- `brettdavies/homebrew-tap` `.github/workflows/publish.yml` — `brew pr-pull` invocation (unchanged by this fix)
- Homebrew `github_releases.rb` `GitHub.get_release` — uses `GET /releases/tags/{tag}`, returns 404 for drafts
- Homebrew `github_releases.rb` — on 404, falls back to `create_or_update_release` (the source of the duplicate)
- `.github/workflows/rust-release.yml` — source repo release creation (now non-draft with `make_latest: false`)
- `.github/workflows/rust-finalize-release.yml` — post-bottle finalization (now idempotent)

### Why `brew pr-pull` already works for non-draft releases

`brew pr-pull` is designed for homebrew-core where releases are always published. The `get_release` call succeeds for
any non-draft release, and `upload_bottles` uploads assets to the existing release. By creating releases as non-draft
from the start (with `make_latest: false`), we stay on that standard, well-tested code path and avoid the draft-vs-tag
visibility gap entirely.

### Institutional Learnings

- **`make_latest: false` keeps a non-draft release out of the "Latest" pointer** until something explicitly flips it.
  This gives us a published-but-not-latest state that is findable by tag without affecting user-facing "latest release"
  metadata until bottles are attached.
- **`CI_RELEASE_TOKEN` for cross-repo ops**: Has Contents R+W on all repos, covers `brew pr-pull`'s bottle uploads.
- **`setup-homebrew` destroys checkout state**: All steps in homebrew-tap's `publish.yml` must run after
  `setup-homebrew`.

## Key Technical Decisions

- **Create releases as non-draft with `make_latest: false`** rather than draft + undraft. Eliminates the coordination
  step between repos, keeps `brew pr-pull` on its standard code path, and removes the "published but bottle-less" window
  the original plan called out.
- **Keep `finalize-release` idempotent across both states**. Even though the shipped flow never produces a draft, the
  workflow still handles the draft case as a fallback (legacy releases, manual intervention, retries). Primary purpose
  now is flipping `make_latest=true` once bottles are attached.
- **Keep homebrew-tap's `publish.yml` untouched.** The original undraft step is unnecessary given non-draft creation.
  Fewer cross-repo coordination points.

## Open Questions

### Resolved During Planning

- **Does non-draft + `make_latest: false` make the release findable by tag?** Yes. Non-draft releases are always
  returned by `GET /releases/tags/{tag}`. `make_latest` only controls the "Latest" pointer, not tag visibility.
- **Does `brew pr-pull` upload to the right place?** Yes. `pr-upload.rb` extracts `user/repo/tag` from the `root_url` in
  the bottle JSON (set by `--root-url`). `get_release` finds the non-draft release at that tag and uploads bottles to
  it.
- **Is there a window where users see a "latest" release without bottles?** No. `make_latest: false` at creation keeps
  the release out of the "Latest" pointer until `rust-finalize-release.yml` flips it after bottles are attached. A
  direct `brew install` between release creation and bottle upload would still source-compile, which is the normal
  fallback for any un-bottled formula.
- **Is `finalize-release` safe to re-run?** Yes. Setting `make_latest=true` on an already-latest release is a no-op; the
  draft-fallback branch handles the legacy case without erroring.

### Deferred to Implementation

- None. Both changes shipped.

## Implementation Units

- [~] **Unit 1 (SUPERSEDED): Add undraft step to homebrew-tap's `publish.yml`**

  **Status:** Not implemented. The shipped approach creates the source release as non-draft (see Unit 3), so no undraft
  step in `brettdavies/homebrew-tap/.github/workflows/publish.yml` is needed. `brew pr-pull` finds the release by tag
  without any intermediate step.

  **Original intent (retained for context):** Publish the source repo's draft release via `gh release edit
  --draft=false` immediately before `brew pr-pull`. See "Approach evolution" for why this was dropped.

- [x] **Unit 2: Make `rust-finalize-release.yml` idempotent** *(shipped — commit `07f71bf`)*

  **Goal:** `finalize-release` succeeds whether the release is still a draft or already published, and ensures
  `make_latest=true` in all cases.

  **Requirements:** R4, R5

  **Dependencies:** None

  **Files:**
- Modify: `.github/workflows/rust-finalize-release.yml`

  **Approach (as shipped):**
  Two-phase check inside the single `Finalize release` step:

1. Query releases for the tag where `draft == true`. If found, PATCH the release with `draft=false` and
   `make_latest=true` (legacy path).
2. Otherwise, query for `draft == false`. If found, PATCH with `make_latest=true` (primary path under the shipped flow).
3. Otherwise, error out (`No release found for tag ${TAG}`).

  Tag format validation (`^v[0-9]+\.[0-9]+\.[0-9]+$`) and payload-presence checks remain as before. Header comments on
  the workflow were updated to reflect that it now handles both states idempotently.

  **Patterns followed:**

- Existing `rust-finalize-release.yml` structure (tag validation, `gh api` calls via `GITHUB_TOKEN`)

  **Test scenarios:**
- Happy path (shipped flow): release is already non-draft when finalize runs — finalize sets `make_latest=true`, exits
  0.
- Legacy path: release is still a draft — finalize publishes it with `draft=false` + `make_latest=true`.
- Error: no release exists for the tag — finalize errors and the workflow fails.
- Retry: re-running after success is a no-op (idempotent PATCH).

  **Verification:**
- Finalize step succeeds whether it receives a draft or non-draft release for the tag.
- Release has `make_latest: true` on GitHub after the step completes.
- Release assets are unchanged (binaries + bottles intact).

- [~] **Unit 3 (shipped, uncommitted): Create non-draft release in `rust-release.yml`**

  **Status:** Implemented in working tree; not yet committed at time of plan update. This unit replaces Unit 1 in the
  shipped design.

  **Goal:** Create the GitHub Release as non-draft with `make_latest: false` so `brew pr-pull` finds it by tag without
  any cross-repo coordination step.

  **Requirements:** R1, R2, R3, R4, R5

  **Dependencies:** Pairs with Unit 2. Ordering does not matter — finalize's two-phase lookup handles both release
  states.

  **Files:**
- Modify: `.github/workflows/rust-release.yml`

  **Approach (as shipped):**
  In the `Create GitHub Release` step (using `softprops/action-gh-release@v2.6.1`):

- Remove `draft: true`.
- Add `make_latest: false`.
- Rename the step from `Create GitHub Release (draft)` to `Create GitHub Release`.
- Update the header comment block to drop the "draft" wording.

  The release is visible by tag immediately but not promoted to the "Latest" pointer until
  `rust-finalize-release.yml` flips `make_latest=true` after bottles land.

  **Patterns followed:**
- Existing `action-gh-release` step structure and `GITHUB_TOKEN` env.

  **Test scenarios:**
- Happy path: release is created non-draft, `make_latest: false` — GitHub shows the release by tag, "Latest" pointer
  unchanged. `brew pr-pull` in homebrew-tap finds it and uploads bottles. Finalize flips `make_latest=true`.
- Duplicate-prevention: only one release exists for the tag after the end-to-end pipeline completes.
- Retry: re-running the release workflow against an existing tag fails cleanly at the `action-gh-release` step (existing
  behavior — tag uniqueness enforced upstream by tagging logic).

  **Verification:**
- After the release job completes, GitHub shows one non-draft release for the tag with `make_latest: false`.
- After the homebrew-tap `publish.yml` run, the same release has bottles attached and no duplicate exists.
- After `rust-finalize-release.yml` dispatches and runs, the release has `make_latest: true`.

## System-Wide Impact

- **Interaction graph:** `rust-release.yml` → homebrew-tap `publish.yml` (via `repository_dispatch`) → `brew pr-pull`
  uploads bottles to the existing non-draft release → `rust-finalize-release.yml` (via `repository_dispatch`) flips
  `make_latest=true`. Dispatch payloads unchanged.
- **Error propagation:** If `action-gh-release` fails, no release is created and downstream steps don't run. If `brew
  pr-pull` fails, a non-draft release exists with `make_latest: false` and no bottles — safe state; retry uploads
  bottles without duplication. If `rust-finalize-release.yml` fails, the release stays non-latest — visible but not
  promoted; retry is a no-op PATCH.
- **Unchanged invariants:** `brew pr-pull` invocation, `update-formula.yml`, `tests.yml`, bottle artifact format, and
  the `repository_dispatch` payload shape are all unchanged. `root_url` continues to point at
  `brettdavies/<formula>/releases/download/<version>`.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Release visible by tag before bottles are attached | `make_latest: false` keeps it out of the "Latest" pointer; `brew install` fallback to source compilation matches any un-bottled formula. Window closes when finalize runs. |
| Finalize runs against an already-latest release (retry) | Workflow is idempotent; PATCH with `make_latest=true` is a no-op. |
| Legacy draft release from pre-shipped flow | Finalize's draft-branch fallback publishes it correctly. |
| Future change to `action-gh-release` defaults or `make_latest` semantics | Pinned by SHA (`153bb8e04406b158c6c84fc1615b65b24149a1fe`). Review on upgrade. |

## Sources & References

- Related todo: `.context/compound-engineering/todos/002-ready-p1-fix-brew-pr-pull-creates-duplicate-release.md`
- Homebrew internals: `github_releases.rb` `GitHub.get_release` + `create_or_update_release` fallback
- v1.1.0 incident:
  [brettdavies/homebrew-tap runs 23924412490, 23924562904, 23924741117](https://github.com/brettdavies/homebrew-tap/actions)
- Manual fix commit: [cebf9d2](https://github.com/brettdavies/homebrew-tap/commit/cebf9d2) — corrected `root_url`
- **Shipped commit (Unit 2):** `07f71bf` — `fix(ci): set make_latest=true when publishing draft release`
- **Shipped (Unit 3, uncommitted at plan-update time):** working-tree changes to `.github/workflows/rust-release.yml`
  removing `draft: true` and adding `make_latest: false`, plus header-comment updates to
  `.github/workflows/rust-finalize-release.yml` describing the non-draft primary path.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Voice | `/codex review` | Independent 2nd opinion | 1 | ISSUES (claude) | Led to this simpler approach |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |

- **VERDICT:** SHIPPED — Unit 2 landed in `07f71bf`; Unit 3 implemented in working tree (uncommitted); Unit 1 superseded
  and not needed.
