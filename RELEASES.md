# Releasing `brettdavies/.github`

Operational runbook. Rationale lives in [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md).

This repo doesn't ship a binary or a crate. It ships **reusable GitHub Actions workflows and ruleset templates** that
consumer repos reference at runtime. A "release" here is the moment a feature PR merges to `main` and becomes available
to every consumer that pins `@main`. There is no tag, no registry publish, no GitHub Release artifact, no Homebrew
bottle.

```text
feature branch (feat/*, fix/*, chore/*, docs/*) → PR to main (squash merge)
                                                → consumer repos pinning @main pick it up on next workflow run
```

Direct commits to `main` are not permitted: every change has a PR number in its squash commit message.

## Branches

| Branch                                 | Role                                                                                                                    | Lifetime                               | Protection                                                |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------- | --------------------------------------------------------- |
| `main`                                 | Production. Consumer repos pin here.                                                                                    | Forever.                               | `.github/rulesets/protect-main.json`                      |
| `dev`                                  | Retired archive. Holds the historical engineering docs (`docs/plans/` and friends) pending review; receives no new PRs. | Forever. Never delete.                 | `.github/rulesets/protect-dev.json` (freezes the archive) |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Feature work.                                                                                                           | One PR's worth. Auto-deleted on merge. | None. Squash into `main` via PR.                          |

→ Rationale: [`RELEASES-RATIONALE.md` § Branching model](./RELEASES-RATIONALE.md#branching-model).

## Daily development (feature → main)

```bash
git checkout main && git pull
git checkout -b feat/short-description
# ... work ...
git push -u origin feat/short-description
gh pr create --base main --title "feat(scope): what changed"
# CI passes → squash-merge (PR_BODY becomes the main commit message)
```

- **Commit style**: [Conventional Commits](https://www.conventionalcommits.org/). Use `feat`, `fix`, `docs`, `chore`,
  `ci`, `refactor`, etc. for feature-branch PRs.
- **PR body**: follow [`.github/pull_request_template.md`](.github/pull_request_template.md). See [§ PR body](#pr-body).
- **PR body prose scrub**: see [§ Prose scrubbing](#prose-scrubbing).

## PR body

Every PR (feature, fix, docs, release) uses `.github/pull_request_template.md` verbatim.

- **No explainer prose anywhere in the body.** User-facing substance only.
- **Summary describes the net diff only** — what merged `main` looks like vs the base branch. Not commit history,
  intermediate state, or cherry-pick mechanics.
- **Zero verification artifacts in the body.** No triple-diff stats, leak-check output ("`guard-main-docs` runs clean"),
  patch-id cherry-check counts, pre-push gate results, CI status, or prose-scrub findings. Anomalies get fixed before
  push, not audit-trailed.
- **Changelog** subsections (`### Added` / `### Changed` / `### Fixed` / `### Documentation`): 1-5 bullets each, delete
  empty subsections, each bullet starts with a verb.
- A PR with no user-facing impact (pure refactor, test-only, CI-only) leaves `## Changelog` empty or omits it.
- The `## Changelog` section is reserved for future changelog automation. This repo does not currently generate a
  `CHANGELOG.md`, but consumer repos do, so the convention is preserved.

→ Rationale: [`RELEASES-RATIONALE.md` § PR body conventions](./RELEASES-RATIONALE.md#pr-body-conventions).

## Releasing

Merging a feature PR to `main` IS the release: consumer repos pinning `@main` pick the change up on their next workflow
run. There is no promotion hop, no `release/*` branch, no cherry-pick, and no `vX.Y.Z` to encode.

Engineering docs (`docs/architecture/`, `docs/brainstorms/`, `docs/ideation/`, `docs/plans/`, `docs/research/`,
`docs/reviews/`, `docs/solutions/`) stay off `main`: `self-guard-main-docs.yml` blocks any `added` or `modified` files
under those paths. New planning docs live in the solutions repo or local-only checkouts; the historical ones sit on the
retired `dev` branch.

## Prose scrubbing

Three release-flow artifacts live outside any automated prose check and need a manual scrub before they ship:

- PR bodies on PRs to `main`.
- `description:` strings, comments, and any inline prose inside `.github/workflows/*.yml`.

```bash
# 1. Save the artifact to /tmp/. The auto-format hook skips /tmp paths, so the
#    body keeps its authored shape and no soft-wrapping is injected.
gh pr view <num> --json body --jq .body > /tmp/body.md         # for PR body edits

# 2. Vale (against the spec's rule packs — until vendored locally, point at the spec checkout).
vale --no-global --config ~/dev/agentnative-spec/.vale.ini --output=line --minAlertLevel=error /tmp/body.md

# 3. LanguageTool (blocking categories: TYPOS|GRAMMAR|CONFUSED_WORDS, mirrors the orchestrator's whitelist).
curl -sS -X POST "${LANGUAGETOOL_URL:-http://pool.tail42ba87.ts.net:8081}/v2/check" \
  --data-urlencode "language=en-US" --data-urlencode "text@/tmp/body.md" \
  | jaq '.matches[] | select(.rule.category.id | test("^(TYPOS|GRAMMAR|CONFUSED_WORDS)$"))'

# 4. unslop (em-dash density and AI-unique structural patterns Vale + LT do not catch).
~/.claude/skills/unslop/scripts/score.py /tmp/body.md

# 5. Apply fixes per finding. Re-run until 0 blocking and unslop score is 0.

# 6. Apply the cleaned version.
gh pr edit <num> --body-file /tmp/body.md     # for PR body edits
```

For workflow YAML prose, copy the relevant `description:` strings or comment blocks into `/tmp/body.md`, run the same
checks, then paste the cleaned text back into the YAML file.

→ Rationale (which artifacts need this, why scrub-before-submit, where the rule packs live):
[`RELEASES-RATIONALE.md` § Prose scrubbing scope](./RELEASES-RATIONALE.md#prose-scrubbing-scope).

## Self-applied reusable workflows

| Self-applied workflow      | Calls reusable                            | Why local-path reference                                                                                                                                                  |
| -------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `self-guard-main-docs.yml` | `./.github/workflows/guard-main-docs.yml` | Filename differs from the reusable to avoid a self-collision; uses `./...` so the caller exercises the PR's version, catching regressions on the PR that introduces them. |
| `lint.yml`                 | (inline) `reviewdog/action-actionlint`    | Repo-internal; runs `actionlint` on every workflow file in the repo on every PR.                                                                                          |

When adding a new reusable workflow, also add a thin self-applied caller (different filename, `./...` path reference,
job-key matching the standard convention so the status-check name is stable).

→ Rationale (why self-apply, where this catches regressions):
[`RELEASES-RATIONALE.md` § Self-applied reusable workflows](./RELEASES-RATIONALE.md#self-applied-reusable-workflows).

## Branch protection

Two rulesets are committed under `.github/rulesets/` and applied to the repo via the GitHub API:

- **`protect-main.json`**: required signatures, linear history, squash-only merges via PR, required status checks,
  creation/deletion blocked, non-fast-forward blocked.
- **`protect-dev.json`**: required signatures, deletion blocked, non-fast-forward blocked. It now freezes the retired
  `dev` archive against accidental deletion or rewrites.

```bash
gh api -X POST repos/brettdavies/.github/rulesets --input .github/rulesets/protect-dev.json
gh api -X PUT  repos/brettdavies/.github/rulesets/<id> --input .github/rulesets/protect-main.json
```

### Status-check contexts

For this repo, the relevant published contexts include `actionlint` (from `lint.yml`) and `guard-docs /
check-forbidden-docs` (from `self-guard-main-docs.yml`). Add new ones to `protect-main.json` whenever a new self-applied
workflow ships.

→ Rationale (inline vs reusable context-string pitfall):
[`RELEASES-RATIONALE.md` § Branch protection](./RELEASES-RATIONALE.md#branch-protection).

## Required secrets

This repo itself needs **no release-time secrets**. `GITHUB_TOKEN` is automatic and the only token any workflow in this
repo uses (and only with `pull-requests: read` or `contents: read`).

## Consumer adoption

Consumers reference these workflows like this:

```yaml
jobs:
  ci:
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
```

Pinning is currently `@main`. Merging to `main` IS the release.

→ Rationale (pinning policy, trigger to migrate to `@v1`, `CI_RELEASE_TOKEN` as a consumer-repo secret):
[`RELEASES-RATIONALE.md` § Consumer adoption and ref pinning](./RELEASES-RATIONALE.md#consumer-adoption-and-ref-pinning).

## Related docs

- [`RELEASES-RATIONALE.md`](./RELEASES-RATIONALE.md) (release flow rationale, branching model, branch-protection
  pitfalls, ref-pinning policy)
- [`README.md`](README.md) (reusable workflow catalog, ruleset templates, security posture, ref pinning policy)
- [`.github/pull_request_template.md`](.github/pull_request_template.md) (PR body structure, changelog convention
  preserved for parity with consumer repos)
- [`.github/workflows/guard-main-docs.yml`](.github/workflows/guard-main-docs.yml) (engineering-docs guard reusable)
- [`.github/workflows/guard-release-branch.yml`](.github/workflows/guard-release-branch.yml) (`release/*` head pattern
  enforcement)
- [`.github/workflows/guard-main-provenance.yml`](.github/workflows/guard-main-provenance.yml) (PR-reference provenance
  guard for commits to `main`)
