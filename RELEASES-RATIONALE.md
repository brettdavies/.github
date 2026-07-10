# Releases rationale

Companion to [`RELEASES.md`](./RELEASES.md). `RELEASES.md` is the runbook (commands, paths, decision tables). This file
holds the WHY behind those rules: branching model, PR conventions, prose-scrubbing
scope, self-applied reusable workflows, branch protection, and ref-pinning policy.

Read this when:

- A rule in `RELEASES.md` doesn't make sense and you're tempted to change it.
- A new contributor asks "why do we do X this way".
- You're adding a new release-flow rule and need to know where it fits the existing model.

## Branching model

### Trunk-based: main is the only live branch

Feature branches cut from `main` and merge back via squash PRs. Consumers pin `@main`, so `main` is production, and a
merged PR is immediately live fleet-wide. A separate integration branch adds a promotion hop between "reviewed and
merged" and "available to consumers"; for a repo whose entire product is the ref consumers resolve at run time, that
hop is pure latency and a staleness foot-gun (fixes sit merged-but-unshipped while every consumer keeps running without
them). The PR gate (lint, docs guard, review) provides the verification; the promotion ceremony provided none.

`dev` is retired, not deleted: it archives the historical engineering docs (`docs/plans/` and friends) that never ship
to `main`, pending review. Its ruleset stays applied so the archive cannot be deleted or rewritten. New planning docs
live in the solutions repo or in local-only checkouts.

Engineering docs (`docs/architecture/`, `docs/brainstorms/`, `docs/ideation/`, `docs/plans/`, `docs/research/`,
`docs/reviews/`, `docs/solutions/`) stay off `main`. The `self-guard-main-docs.yml` workflow (this repo's self-applied
caller of its own `guard-main-docs.yml` reusable) blocks them from reaching `main`. The other guard reusables shipped
from this repo (`guard-main-provenance.yml`, `guard-release-branch.yml`) are not self-applied here; consumers wire them
up themselves.

### No CHANGELOG, no version bump, no tag

Unlike the Rust CLI sibling repos, this repo has no `Cargo.toml`, no `CHANGELOG.md`, and no tag-driven release pipeline.
Steps you'd run in those repos (`cargo update`, `generate-completions.sh`, `generate-changelog.sh`, `git tag -a`) are
all no-ops here. Merging a feature PR to `main` is the release.

If a future change introduces a versioned ref (e.g., migrating consumers from `@main` to `@v1` per the trigger
documented in [`README.md`](README.md#ref-pinning)), reintroduce the tag step and revisit the runbook.

## PR body conventions

### No explainer prose in the body

Every section of a PR body is user-facing substance only: what is changing for the consumer that was not already there —
the **net diff**, not the commit history or intermediate state that produced it. Workflow mechanics and CI behavior
are documented in this file, in `RELEASES.md`, and in `.github/`, NOT in the PR body. Leak-check narration
("`guard-main-docs` runs clean", "no guarded paths leaked"), CI check status, exclusion rationale, and other
verification artifacts stay local; anomalies get fixed before push, not audit-trailed in the body.

The PR body is read by humans reviewing what shipped. Workflow mechanics and tool-fix provenance are noise from that
perspective; they belong in this file, the script outputs, and the commit history respectively.

## Prose scrubbing scope

Two release-flow artifacts live outside any automated prose check and need a manual scrub before they ship:

- **PR bodies on PRs to `main`.** `gh pr create` and `gh pr edit` send body text directly to GitHub; no local check
  sees it.
- **Workflow `description:` strings, comments, and any inline prose inside `.github/workflows/*.yml`.** YAML files are
  not covered by the same markdown-targeted prose checks, but the strings users see in the GitHub Actions UI come from
  here.

This repo does not vendor a Vale or LanguageTool configuration of its own. The canonical rule packs and orchestrator
behaviour live in the spec repo at
[`~/dev/agentnative-spec/docs/architecture/voice-enforcement.md`](../agentnative-spec/docs/architecture/voice-enforcement.md).
Until those packs are vendored into this repo, the scrub commands in `RELEASES.md` point at the spec checkout directly.

Scrub-before-submit (author in `/tmp/`, scrub there, submit via `--body-file`) avoids the round-trip of "submit, scrub,
edit, scrub again". Every fix lands locally and the public PR sees only clean text. The auto-format hook skips `/tmp/`
paths so the body keeps its authored shape and no soft-wrapping is injected.

## Self-applied reusable workflows

Some of the reusable workflows this repo ships have a thin self-applied caller. When a self-applied caller exists, a PR
to this repo exercises the PR's version of the reusable (via a `./...` local-path reference) rather than the
merged-to-`main` version, catching regressions on the PR that introduces them rather than after the workflow has shipped
to consumer repos. Currently only `guard-main-docs.yml` is wired this way (via `self-guard-main-docs.yml`); the
`guard-main-provenance.yml` and `guard-release-branch.yml` reusables are shipped but not self-applied here.

The self-applied caller filename always differs from the reusable to avoid a self-collision. Pattern for any future
guard reusable: add a thin self-applied caller (different filename, `./...` path reference, job-key matching the
standard convention so the status-check name is stable). The Rust-oriented reusables (`rust-ci.yml`, `rust-release.yml`,
`rust-finalize-release.yml`) are not self-applied because this repo is not a Rust crate.

## Branch protection

### Status-check context strings

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

## Consumer adoption and ref pinning

The "distribution channel" for this repo is the `uses:` line in a consumer repo's workflow. There is no registry, no
tag, no GitHub Release artifact. Merging a `release/* → main` PR makes the change available to every consumer that pins
`@main` on their next workflow run.

Ref pinning policy lives in [`README.md`](README.md#ref-pinning):

- **Today**: `@main`. Same owner controls all repos (no supply chain risk), `actionlint` CI plus branch protection
  catches errors before propagation, and rollback is one revert in this repo.
- **Trigger to migrate to `@v1` semver tags**: a third-party contributor or a third-plus consumer arrives.

When that trigger fires, reintroduce a tag step to the release flow and update consumer-repo `uses:` lines from `@main`
to `@v1`. Until then, merging to `main` IS the release.

`CI_RELEASE_TOKEN` is **a consumer-repo secret**, not a `.github` secret. Consumers passing it explicitly into
`rust-release.yml` (`secrets: CI_RELEASE_TOKEN: ${{ secrets.CI_RELEASE_TOKEN }}`) is what dispatches their own Homebrew
formula update. See [`README.md`](README.md#rust-releaseyml) for the caller example.

## Related docs

- [`RELEASES.md`](./RELEASES.md) (operational runbook: commands, paths, decision tables)
- [`README.md`](README.md) (reusable workflow catalog, ruleset templates, security posture, ref pinning policy)
- [`.github/pull_request_template.md`](.github/pull_request_template.md) (PR body structure, changelog convention
  preserved for parity with consumer repos)
- [`.github/workflows/guard-main-docs.yml`](.github/workflows/guard-main-docs.yml) (engineering-docs guard reusable)
- [`.github/workflows/guard-release-branch.yml`](.github/workflows/guard-release-branch.yml) (`release/*` head pattern
  enforcement)
- [`.github/workflows/guard-main-provenance.yml`](.github/workflows/guard-main-provenance.yml) (PR-reference provenance
  guard for commits to `main`)
