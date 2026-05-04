# Releasing `brettdavies/.github`

This repo doesn't ship a binary or a crate — it ships **reusable GitHub Actions workflows and ruleset templates** that
consumer repos reference at runtime. A "release" here is the moment a change on `dev` lands on `main` and becomes
available to every consumer that pins `@main`. There is no tag, no registry publish, no GitHub Release artifact, no
Homebrew bottle.

Every change reaches `main` via this pipeline. Direct commits to `dev` or `main` are not permitted — every change has a
PR number in its squash commit message, which keeps the history scannable, attributable, and auditable.

```text
feature branch → PR to dev (squash merge)
              → cherry-pick to release/* branch
              → PR to main (squash merge)
              → consumer repos pinning @main pick it up on next workflow run
```

## Branches

| Branch                                 | Role                                    | Lifetime                                    | Protection                           |
| -------------------------------------- | --------------------------------------- | ------------------------------------------- | ------------------------------------ |
| `main`                                 | Production. Consumer repos pin here.    | Forever.                                    | `.github/rulesets/protect-main.json` |
| `dev`                                  | Integration. All feature PRs land here. | Forever. Never delete.                      | `.github/rulesets/protect-dev.json`  |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Feature work.                           | One PR's worth. Auto-deleted on merge.      | None — squash into dev freely.       |
| `release/*`                            | Head of a dev → main PR.                | One release's worth. Auto-deleted on merge. | None.                                |

`dev` is a **forever branch**. Never delete it locally or remotely, even after a `release/* → main` merge. The next
release cycle reuses the same `dev`. The repo's `deleteBranchOnMerge: true` setting doesn't touch `dev` as long as `dev`
is never the head of a PR — using a short-lived `release/*` head is what keeps the setting compatible with a forever
integration branch. The `guard-release-branch.yml` workflow (self-applied to this repo) enforces the `release/*` head
pattern at the PR level.

## Daily development (feature → dev)

```bash
git checkout dev && git pull
git checkout -b feat/short-description
# ... work ...
git push -u origin feat/short-description
gh pr create --base dev --title "feat(scope): what changed"
# CI passes → squash-merge (PR_BODY becomes the dev commit message)
```

- **Commit style**: [Conventional Commits](https://www.conventionalcommits.org/). Use `feat`, `fix`, `docs`, `chore`,
  `ci`, `refactor`, etc. for feature-branch PRs.
- **PR body**: follow [`.github/pull_request_template.md`](.github/pull_request_template.md). The `## Changelog` section
  is reserved for any future changelog automation; this repo does not currently generate a `CHANGELOG.md`, but consumer
  repos do, so the convention is preserved.

## Releasing dev to main

Engineering docs (`docs/brainstorms/`, `docs/ideation/`, `docs/plans/`, `docs/research/`, `docs/reviews/`,
`docs/solutions/`) live on `dev` only. The `self-guard-main-docs.yml` workflow (this repo's self-applied caller of its
own `guard-main-docs.yml` reusable) blocks them from reaching `main`. Use the release-branch cherry-pick pattern:

**Branch naming**: `release/<slug>` (e.g. `release/guard-release-branch`, `release/bootstrap-essentials`). Unlike the
sibling Rust CLI repos, there is no `vX.Y.Z` version to encode in the branch name — there is no `Cargo.toml` to bump and
no tag to push. A short slug describing the release contents is sufficient.

**Squash-merge title prefix**: this repo uses `release: <description>` as the squash-merge title for `release/* → main`
PRs (see commits [#5][pr-5], [#7][pr-7], [#11][pr-11], [#13][pr-13]). `release:` is not a Conventional Commits type, but
it's the established convention here — it visually distinguishes the dev-to-main consolidations from the underlying
`feat`/`fix`/`ci`/`docs` PRs that fed `dev`. Keep using it.

[pr-5]: https://github.com/brettdavies/.github/pull/5
[pr-7]: https://github.com/brettdavies/.github/pull/7
[pr-11]: https://github.com/brettdavies/.github/pull/11
[pr-13]: https://github.com/brettdavies/.github/pull/13

```bash
# 1. Branch from main, NOT dev. Branching from dev causes add/add conflicts
#    when dev and main have divergent histories (the post-squash-merge norm).
git fetch origin
git checkout -b release/<slug> origin/main

# 2. List the dev commits not yet on main:
git log --oneline dev --not origin/main

# 3. Cherry-pick the ones you want to ship. Docs commits stay on dev.
git cherry-pick <sha1> <sha2> ...

# 4. Triple-diff verification — belt-and-suspenders sweep that catches both
#    directions of drift before the release PR opens:
#
#    A. main → release  (what consumers will see; the intended ship surface)
#    B. release → dev   (should be empty for non-doc paths — anything else is
#                        a missed cherry-pick)
#    C. dev → main      (sanity: phantom commits dev "appears ahead" on
#                        because cherry-pick rewrites SHAs post-squash)
git diff origin/main..HEAD --stat                                                # A
git diff HEAD..origin/dev --name-only | grep -v '^docs/' || echo "(none)"        # B
git diff origin/dev..origin/main --stat | tail -5                                # C
#
# Re-confirm no guarded paths leaked:
git diff origin/main..HEAD --name-only \
  | grep -E '^(docs/plans|docs/brainstorms|docs/ideation|docs/research|docs/reviews|docs/solutions|\.context)' \
  && echo "LEAKED — reset and redo" || echo "(clean — no guarded paths)"
#
# Patch-id cherry check — catches commits on dev that have NO patch-id
# equivalent on release. The file-level diff in B misses this class when
# the same content happens to land via a different commit.
#
# IMPORTANT: in a squash-merge workflow this output is noisy. Every '+'
# line needs human triage — it does NOT auto-block the release. Expected
# sources of '+' lines that are NOT real misses:
#
#   1. Historical commits squash-merged in prior releases. The squash
#      commit on main has a different patch-id than the dev commits it
#      consolidates, so old commits show as '+' forever. Anything older
#      than the previous release is almost always this.
#   2. Cherry-picks where conflict resolution stripped guarded paths
#      (docs/plans, docs/brainstorms, etc.) or otherwise altered the
#      tree. Same source-code intent, different patch-id.
#   3. Intentionally skipped commits — docs-only commits, release-prep
#      backports, revert-and-redo prep steps.
#
# A real miss looks like: a recent feat/fix/ci commit on dev whose
# *file content* is not yet on main. To triage a '+' line:
#
#   git show <sha> --stat                       # what did it touch?
#   git diff origin/main..HEAD -- <those-files> # already on release?
#
# If every touched file is guarded (docs/plans/, docs/brainstorms/, etc.)
# OR the content is already on main via a prior squash, it's a false
# positive — no action. Otherwise cherry-pick the commit and re-run the
# triple-diff.
git cherry HEAD origin/dev | grep '^+' || echo "(none — release is patch-equivalent through dev)"

# 5. Push and open the PR:
git push -u origin release/<slug>
gh pr create --base main --head release/<slug> --title "release: <description>"
```

When the PR merges, consumer repos pinning `@main` will pick up the change on their next workflow run. Auto-delete
removes the release branch from the remote on merge. `dev` is untouched.

### Why branch from main, not dev

Branching from `dev` and then deleting the guarded paths seems simpler but produces `add/add` merge conflicts whenever
`dev` and `main` have diverged (which they always do after the first squash merge). The file appears as "added" on both
sides with different content. Always branch from `origin/main` and cherry-pick onto it.

### No CHANGELOG, no version bump, no tag

Unlike the Rust CLI sibling repos, this repo has no `Cargo.toml`, no `CHANGELOG.md`, and no tag-driven release pipeline.
Steps you'd run in those repos — `cargo update`, `generate-completions.sh`, `generate-changelog.sh`, `git tag -a` — are
all no-ops here. The release PR is just the cherry-picked commits; merging it is the release.

If a future change introduces a versioned ref (e.g. migrating consumers from `@main` to `@v1` per the trigger documented
in [`README.md`](README.md#ref-pinning)), reintroduce the tag step and revisit this section.

## Self-applied reusable workflows

This repo is unusual: the reusable workflows it ships are also self-applied to itself, so a PR exercises the PR's own
version of each workflow rather than the merged-to-`main` version.

| Self-applied workflow      | Calls reusable                            | Why local-path reference                                                                                                                                                  |
| -------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `self-guard-main-docs.yml` | `./.github/workflows/guard-main-docs.yml` | Filename differs from the reusable to avoid a self-collision; uses `./...` so the caller exercises the PR's version, catching regressions on the PR that introduces them. |
| `lint.yml`                 | (inline) `reviewdog/action-actionlint`    | Repo-internal; runs `actionlint` on every workflow file in the repo on every PR.                                                                                          |

When adding a new reusable workflow, also add a thin self-applied caller (different filename, `./...` path reference,
job-key matching the standard convention so the status-check name is stable). This lets the workflow's own behavior gate
its own changes.

## Branch protection

Two rulesets are committed under `.github/rulesets/` and applied to the repo via the GitHub API:

- `protect-main.json` — required signatures, linear history, squash-only merges via PR, required status checks,
  creation/deletion blocked, non-fast-forward blocked.
- `protect-dev.json` — required signatures, deletion blocked, non-fast-forward blocked. The PR-only norm is enforced by
  convention plus the `guard-release-branch` self-applied workflow on the main side.

Apply with `gh api`:

```bash
gh api -X POST repos/brettdavies/.github/rulesets --input .github/rulesets/protect-dev.json
gh api -X PUT  repos/brettdavies/.github/rulesets/<id> --input .github/rulesets/protect-main.json
```

### Status-check context pitfall

The `required_status_checks[].context` strings in `protect-main.json` must match exactly what GitHub publishes for each
check:

- **Inline job** (with `name:` field): published as just `<job-name>` (no workflow-name prefix).
- **Reusable-workflow caller** (`uses: .../foo.yml@ref`): published as `<caller-job-id> / <reusable-job-id-or-name>`.

Mixing these produces a stuck-but-green PR: all actual checks report green, but the ruleset waits forever on a context
that will never appear. Confirm the real contexts after a first CI run with:

```bash
gh api repos/brettdavies/.github/commits/<sha>/check-runs --jq '.check_runs[].name'
```

For this repo, the relevant published contexts include `actionlint` (from `lint.yml`) and `guard-docs /
check-forbidden-docs` (from `self-guard-main-docs.yml`). Add new ones to `protect-main.json` whenever a new self-applied
workflow ships.

## Required secrets

This repo itself needs **no release-time secrets**. `GITHUB_TOKEN` is automatic and the only token any workflow in this
repo uses (and only with `pull-requests: read` or `contents: read`).

`CI_RELEASE_TOKEN` is **a consumer-repo secret**, not a `.github` secret — consumers passing it explicitly into
`rust-release.yml` (`secrets: CI_RELEASE_TOKEN: ${{ secrets.CI_RELEASE_TOKEN }}`) is what dispatches their own Homebrew
formula update. See [`README.md`](README.md#rust-releaseyml) for the caller example.

## Consumer adoption

The "distribution channel" for this repo is the `uses:` line in a consumer repo's workflow. Consumers reference these
workflows like this:

```yaml
jobs:
  ci:
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
```

Ref pinning policy lives in [`README.md`](README.md#ref-pinning):

- **Today**: `@main`. Same owner controls all repos (no supply chain risk), `actionlint` CI plus branch protection
  catches errors before propagation, and rollback is one revert in this repo.
- **Trigger to migrate to `@v1` semver tags**: a third-party contributor or a third-plus consumer arrives.

When that trigger fires, reintroduce a tag step to the release flow above and update consumer-repo `uses:` lines from
`@main` to `@v1`. Until then, merging to `main` IS the release.

## Related docs

- [`README.md`](README.md) — reusable workflow catalog, ruleset templates, security posture, ref pinning policy
- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR body structure (changelog convention
  preserved for parity with consumer repos)
- [`.github/workflows/guard-main-docs.yml`](.github/workflows/guard-main-docs.yml) — engineering-docs guard reusable
- [`.github/workflows/guard-release-branch.yml`](.github/workflows/guard-release-branch.yml) — `release/*` head pattern
  enforcement
- [`.github/workflows/guard-main-provenance.yml`](.github/workflows/guard-main-provenance.yml) — PR-reference provenance
  guard for commits to `main`
