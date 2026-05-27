---
title: "feat: centralize actionlint as a reusable workflow and fan out to four consumer repos"
type: feat
status: active
date: 2026-05-27
---

# feat: centralize actionlint as a reusable workflow and fan out to four consumer repos

## Summary

Convert `brettdavies/.github/.github/workflows/lint.yml` from a standalone workflow into a `workflow_call:`-only
reusable, add a `self-lint.yml` self-wrapper alongside it so `dot-github` keeps linting its own workflows, and create a
thin caller wrapper in each of the four consumer repos (`agentnative-spec`, `agentnative-cli`, `agentnative-site`,
`agentnative-skill`) so every repo runs the same actionlint check from one centrally-maintained source. Each consumer
wrapper triggers on push and pull_request against the repo's existing CI branches, and branch-protection rulesets gain
the new check context only after the first CI run reveals the exact context string GitHub publishes.

---

## Problem Frame

Today `lint.yml` runs actionlint only against the `dot-github` repo itself. None of the four consumer repos run
actionlint anywhere — `agentnative-skill` even documents `actionlint .github/workflows/*.yml` as a required local lint
in CONTRIBUTING.md and AGENTS.md, but no CI workflow enforces it. The actionlint pre-flight audit
(`agentnative-skill/.context/audits/2026-05-27-001-actionlint-preflight.md`) confirmed all five repos pass actionlint
clean today; wiring it in catches future regressions for zero current cost.

The pattern for solving this is established in the same `dot-github` repo: `guard-main-docs.yml` (the
`workflow_call:`-only reusable) plus `self-guard-main-docs.yml` (the local self-wrapper that triggers on push/PR and
calls the reusable via the local `./.github/workflows/guard-main-docs.yml` path). Every consumer repo has a thin
`guard-main-docs.yml` caller that invokes the centralized reusable via `uses:
brettdavies/.github/.github/workflows/guard-main-docs.yml@main`. This plan mirrors that pattern for actionlint.

---

## Requirements

- R1. `dot-github`'s `lint.yml` becomes a `workflow_call:`-only reusable with a `fail_level` input parameter (default
  `error`).
- R2. `dot-github` keeps linting its own workflow files via a new `self-lint.yml` self-wrapper that calls
  `./.github/workflows/lint.yml` locally (mirrors the `self-guard-main-docs.yml` precedent).
- R3. Each of the four consumer repos gets a new `.github/workflows/lint.yml` wrapper that triggers on push and
  pull_request against the repo's existing CI branches and calls `brettdavies/.github/.github/workflows/lint.yml@main`.
- R4. Caller `jobs.<id>:` key is standardized as `lint` across all four consumer wrappers AND the dot-github
  self-wrapper, so the published check context is uniformly `Lint / lint / actionlint`.
- R5. Branch-protection rulesets (`protect-main.json`) in `dot-github` and each consumer repo get the new actionlint
  check context as a required status check — **only after** the first CI run on each repo reveals the exact context
  string via `gh api repos/<owner>/<repo>/commits/<sha>/check-runs --jq '.check_runs[].name'`.
- R6. `permissions: contents: read` is set at workflow level on the reusable, the self-wrapper, and every consumer
  wrapper.
- R7. The `agentnative-skill` `CONTRIBUTING.md:73` and `AGENTS.md:40` line that documents `actionlint
  .github/workflows/*.yml` as a required local lint becomes honest CI enforcement (no doc edit needed in skill; flag
  whether spec/cli/site need parallel doc additions).

---

## Scope Boundaries

**In scope:**

- The `dot-github` reusable conversion + self-wrapper (U1, U2).
- The four consumer wrapper workflows (U4, U5, U6, U7).
- The five branch-protection ruleset updates (U3 for dot-github, folded into U4–U7 for each consumer).

**Out of scope:**

### Deferred to Follow-Up Work

- **`paths:` filter / short-circuit for the lint wrapper.** Research confirmed the native `paths:` filter is
  incompatible with required-status-check protection: a workflow skipped by `paths:` reports no check at all, leaving
  PRs stuck on "Expected — Waiting" forever. The cleanest alternatives (always-run with internal `dorny/paths-filter`
  skip step; the ci-stub mirror pattern in `agentnative-site/.github/workflows/ci.yml` + `ci-stub.yml`) trade complexity
  for ~5 sec of savings per PR. actionlint runs in ~5 sec; the cost of always-running is below the noise floor. Deferred
  unless the per-PR overhead becomes load-bearing.
- **Adding actionlint to the global `pin-actions.sh` allowlist.**
  `~/.claude/skills/github-repo-setup/scripts/pin-actions.sh` audits SHA-pinned actions across brettdavies repos. Since
  the consumer wrappers reference `brettdavies/.github/...@main` (not a SHA), there's nothing to allowlist today. If KD1
  is later reversed and SHA-pinning is adopted, this becomes required.
- **Extending `repo-settings.sh report` to verify actionlint wrapper presence.** The existing audit script already
  verifies `rust-ci.yml@main` callers; an analogous `lint.yml@main` check would catch consumer drift back to inline
  lint. Deferred until the rollout is complete and the pattern is stable.
- **Capturing the self-wrapper pattern as a `docs/solutions/` entry.** The CE learnings researcher flagged that no
  solutions doc captures the `self-<name>.yml` pattern — the precedent exists only in workflow files. Worth a
  `/ce-compound` after rollout.
- **Capturing the `paths:` filter + required-check interaction as a `docs/solutions/` entry.** Same — no existing entry.
  Capture after the plan lands.
- **Migrating other lints (markdownlint, shellcheck) to centralized reusables.** Each consumer currently runs these as
  inline jobs in its own `ci.yml`. Centralizing them is a separate, larger refactor outside this plan's scope.

**Outside this product's identity:**

- Pyflakes integration on workflow `run:` blocks. No workflow currently embeds Python.
- The `reviewdog/action-actionlint` action's `filter_mode` (PR-diff vs. full-repo) — sticking with the action's default.
  Exposing it as a `workflow_call` input is unnecessary today.

---

## Context & Research

### Relevant Code and Patterns

The `dot-github/.github/workflows/guard-main-docs.yml` + `dot-github/.github/workflows/self-guard-main-docs.yml` pair is
the canonical template. Specifically:

- `guard-main-docs.yml`: `on: workflow_call:`, `permissions: pull-requests: read`, single job (`check-forbidden-docs`),
  runs on `ubuntu-22.04`.
- `self-guard-main-docs.yml`: `on: pull_request: branches: [main]`, `permissions: pull-requests: read`, single job named
  `guard-docs` (deliberately different from the reusable's job key to produce a stable check context `guard-docs /
  check-forbidden-docs`), uses `./.github/workflows/guard-main-docs.yml` (local path, no `@ref`) so the self-wrapper
  exercises the PR's version of the reusable.

Existing consumer wrappers (e.g., `agentnative-skill/.github/workflows/guard-main-docs.yml`) use `uses:
brettdavies/.github/.github/workflows/guard-main-docs.yml@main` — `@main` ref, not SHA. This is the ecosystem
convention.

Current `lint.yml` (the file being converted):

- `on: push: branches: [main, dev]` + `on: pull_request: branches: [main, dev]`
- `runs-on: ubuntu-22.04`
- `env: FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`
- Single job `actionlint` using `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2` and
  `reviewdog/action-actionlint@0d952c597ef8459f634d7145b0b044a9699e5e43 # v1.71.0` with `fail_level: error`.
- Published check context: bare `actionlint` (per `dot-github/.github/rulesets/protect-main.json`).

Consumer repos' existing CI shapes (from the repo-research agent):

- `agentnative-spec/.github/workflows/`: thin wrappers for `guard-main-docs`, `guard-main-provenance`,
  `guard-release-branch`; one repo-local `publish.yml`. No `ci.yml`.
- `agentnative-cli/.github/workflows/`: `ci.yml` is itself a thin wrapper to
  `brettdavies/.github/.github/workflows/rust-ci.yml@main`. Other thin wrappers + repo-local `skill-fixture-drift.yml`.
- `agentnative-site/.github/workflows/`: repo-local `ci.yml` (Bun-based) + `ci-stub.yml` (mirror pattern for
  paths-filter + required-status-check), `deploy.yml`, `deep-check.yml`, `skill-availability.yml`. Thin wrappers for
  `guard-main-docs`, `guard-release-branch`.
- `agentnative-skill/.github/workflows/`: repo-local `ci.yml` (markdownlint + shellcheck inline jobs). Thin wrapper for
  `guard-main-docs`.

### Institutional Learnings

- **`solutions-docs/integration-issues/github-status-check-context-inline-vs-reusable-2026-04-14.md`**: Published
  context for reusable callers is `<caller-workflow-name> / <caller-job-id> / <reusable-job-name-or-id>`. Mismatched
  ruleset entries leave PRs in `BLOCKED` state forever. Resolve actual context strings via `gh api
  repos/<owner>/<repo>/commits/<sha>/check-runs` AFTER first run, BEFORE editing rulesets.
- **`solutions-docs/workflow-issues/cherry-pick-standalone-to-reusable-workflow-transition-20260413.md`**: Direct prior
  art for this exact migration shape. Cherry-pick conflicts on `release/*` — take cherry-pick side wholesale, audit
  ruleset JSON for old hardcoded check names in the same PR.
- **`solutions-docs/architecture-patterns/release-pipeline-reusable-workflows-20260320.md`**: Establishes the `@main`
  ref convention across brettdavies-ecosystem consumers (bird, xurl-rs, agentnative repos). Rationale: same owner
  controls all repos; rollback = one revert in dot-github; Dependabot can't bump org-owned reusable-workflow refs.
  Directly informs KD1.
- **`solutions-docs/best-practices/ci-hardening-defaults-permissions-read-failfast-false-2026-04-20.md`**: `permissions:
  contents: read` at workflow level is the default. actionlint needs no write scopes. Informs R6.
- **`solutions-docs/best-practices/calver-pin-for-per-repo-config-drift-detection-20260415.md`**: Generalizes to GitHub
  Actions SHA pins. Less applicable here since KD1 picks `@main`; revisit if KD1 reverses.

### External References

-
  [GitHub Docs: Troubleshooting required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)
  — confirms a workflow skipped by `paths:` reports no check, blocking required-check PRs forever.
- [GitHub Docs: Reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows) —
  confirms local-path `uses: ./.github/workflows/<file>.yml` syntax for self-wrappers.
-
  [GitHub Changelog 2022-01-25: Reusable workflows can be referenced locally](https://github.blog/changelog/2022-01-25-github-actions-reusable-workflows-can-be-referenced-locally/)
  — feature confirmation.
- [Community discussion #8512](https://github.com/orgs/community/discussions/8512) — exact published check context
  format for reusable callers.
- [Community discussion #44490](https://github.com/orgs/community/discussions/44490) — open community request for
  "required-but-skippable" path-filtered checks. Confirms no first-class fix exists.
- [`reviewdog/action-actionlint` README](https://github.com/reviewdog/action-actionlint) — inputs reference,
  `fail_level` enum (`none|any|info|warning|error`).

---

## Key Technical Decisions

### KD1. Ref-pinning for consumer wrappers: `@main`, not SHA

Decision: consumer wrappers reference `uses: brettdavies/.github/.github/workflows/lint.yml@main`, not a SHA pin.

Rationale: the established ecosystem convention is `@main` for org-owned reusables — every existing thin wrapper in the
four consumers (`guard-main-docs.yml`, `rust-ci.yml`, etc.) uses `@main`. The rationale documented in
`release-pipeline-reusable-workflows-20260320.md` is that the same owner controls all repos, rollback is one revert in
`dot-github`, and SHA-pinning org-owned reusable refs creates drift that Dependabot can't auto-bump.

This diverges from the global supply-chain SHA-pin rule, which targets third-party actions. The threat model differs: a
compromised `brettdavies/.github` means everything is already compromised, so SHA-pinning the cross-call adds no
security and adds maintenance cost.

The `workflow_call:` interface (inputs, secrets, job ids) is treated as a public API contract — never breaking-change
without coordinated rollout across all four consumers.

### KD2. No short-circuit; run actionlint unconditionally

Decision: each consumer wrapper triggers on push and pull_request against existing CI branches with no `paths:` filter.
The actionlint job runs on every PR regardless of whether workflow files changed.

Rationale: research established that the native `paths:` filter is incompatible with required-status-check enforcement —
a path-skipped workflow reports no check, blocking PRs forever. The cleanest alternatives (`dorny/paths-filter`
job-level skip; `ci-stub` mirror) trade complexity for ~5 sec of savings per PR. actionlint completes in ~5 sec on a
clean repo; the cost of unconditional run is below the noise floor.

Trade-off accepted: ~5 sec per PR run × 4 consumers × N PRs/week ≈ negligible. Trade-off avoided: dual-file maintenance,
paths-filter / required-check incompatibility, drift hazard between mirror files.

If a future case makes per-PR overhead load-bearing, the ci-stub mirror pattern (precedent:
`agentnative-site/.github/workflows/ci.yml` + `ci-stub.yml`) is the documented path forward — listed in Deferred to
Follow-Up Work.

### KD3. Standardize caller `jobs.<id>:` key as `lint` across all wrappers

Decision: every consumer wrapper AND the dot-github self-wrapper use `jobs.lint:` as the caller key. Published check
context is uniformly `Lint / lint / actionlint`.

Rationale: published status-check context is `<caller-workflow-name> / <caller-job-id> / <reusable-job-name-or-id>`.
Standardizing the middle segment gives uniform ruleset entries across all five repos and a single mental model. The
reusable's job is named `actionlint`; the caller workflow's top-level `name:` is `Lint`; the caller job is `lint:`.

Document this convention in the reusable's header comments as part of its public contract.

### KD4. `fail_level` as a `workflow_call` input with default `error`

Decision: expose `fail_level` as a `workflow_call.inputs.fail_level` of type `string` with default `error`. Consumers
can override (e.g., `fail_level: none` for advisory rollouts in a noisy repo).

Rationale: hardcoding `error` works for the org default but forecloses two legitimate consumer needs: advisory rollouts
when onboarding a noisy repo, stricter gates (`fail_level: any`) when warnings should fail. Cost of exposing the input
is one parameter declaration in the reusable; benefit is consumer flexibility without forking.

The four valid values (per the reviewdog action's contract): `none|any|info|warning|error`. Document in the input
description so callers don't have to read reviewdog source.

### KD5. `permissions: contents: read` at workflow level

Decision: set `permissions: contents: read` at workflow level on the reusable, the self-wrapper, and every consumer
wrapper.

Rationale: actionlint needs no write scopes. Granting only `contents: read` follows the least-privilege CI-hardening
default documented in `ci-hardening-defaults-permissions-read-failfast-false-2026-04-20.md`.

### KD6. Consumer wrapper trigger branches mirror existing CI shape

Decision: each consumer wrapper's `on: push:` and `on: pull_request:` branch list matches the repo's existing `ci.yml`
(or guard-workflows where no `ci.yml` exists). Per-consumer:

- `agentnative-spec`: `[main, dev]` (matches existing thin wrappers).
- `agentnative-cli`: `[main, dev]` plus `feat/**`, `fix/**`, etc. (matches `ci.yml`).
- `agentnative-site`: `[main, dev]` (matches existing `ci.yml`).
- `agentnative-skill`: `[main, dev]` plus `feat/**`, `fix/**`, `chore/**`, `release/**` (matches existing `ci.yml`).

Rationale: each repo has already settled on what counts as a CI-worthy push event. The lint wrapper inherits the same
answer rather than re-litigating it.

---

## Open Questions

### Resolved During Planning

- **Q: SHA pin or `@main` for the cross-repo `uses:` reference?** A: `@main` per ecosystem precedent (KD1).
- **Q: Short-circuit mechanism — native `paths:`, `dorny/paths-filter`, or ci-stub mirror?** A: No short-circuit; run
  unconditionally (KD2).
- **Q: `fail_level` hardcoded or exposed as input?** A: Exposed as `workflow_call` input with default `error` (KD4).
- **Q: Caller job-id naming?** A: Standardized as `lint` (KD3).
- **Q: Consumer wrapper filename?** A: `.github/workflows/lint.yml` in each consumer (matches the reusable's filename;
  differentiation comes from the cross-repo `uses:` path).

### Deferred to Implementation

- **The exact ruleset check-context string after the first CI run.** Research established the format is
  `<caller-workflow-name> / <caller-job-id> / <reusable-job-name>`, but the published string can only be confirmed
  empirically. Implementation step in each consumer unit: after the wrapper PR's first CI run, run `gh api
  repos/brettdavies/<repo>/commits/<sha>/check-runs --jq '.check_runs[].name'` and use the actual string in the ruleset
  PATCH.
- **Whether spec/cli/site need a CONTRIBUTING.md or AGENTS.md addition documenting `actionlint` as a local lint
  command.** Only `agentnative-skill` currently mentions it. Per-consumer decision during the wrapper PR.

---

## Implementation Units

### U1. Convert `dot-github/.github/workflows/lint.yml` to `workflow_call:`-only reusable

**Goal:** Strip the standalone `push`/`pull_request` triggers from `lint.yml` and replace with `workflow_call:` + a
`fail_level` input. Preserve all other behavior (runner OS, env vars, action SHAs, `fail_level: error` as the default).

**Requirements:** R1, R4, R6.

**Dependencies:** None.

**Files:**

- `dot-github/.github/workflows/lint.yml` — modify

**Approach:** Replace `on: push: ... pull_request: ...` with `on: workflow_call: inputs: fail_level: { type: string,
required: false, default: error, description: "..." }`. Move the literal `fail_level: error` to `${{ inputs.fail_level
}}`. Add `permissions: contents: read` at workflow level. Update the file header comment block to follow the same shape
as `guard-main-docs.yml` (purpose, caller example, required permissions). Reusable's job stays named `actionlint`
(matters for the published context).

**Patterns to follow:** `dot-github/.github/workflows/guard-main-docs.yml` (the canonical reusable shape — header block,
`workflow_call:`, `permissions:`, single job).

**Test scenarios:**

- Reusable can be called from a sibling workflow in the same repo via `uses: ./.github/workflows/lint.yml` (self-wrapper
  exercises this — U2).
- Reusable can be called from another repo via `uses: brettdavies/.github/.github/workflows/lint.yml@main` (consumer
  wrappers exercise this — U4–U7).
- Default `fail_level` is `error` when caller doesn't pass the input.
- Override works: caller passes `with: { fail_level: warning }` and reusable surfaces warning-level findings as
  failures.

**Verification:** `actionlint -no-color dot-github/.github/workflows/lint.yml` passes locally before the PR opens. After
the dot-github PR merges to `main`, the `self-lint.yml` self-wrapper (U2) produces a green `Lint / lint / actionlint`
check on subsequent dot-github PRs.

### U2. Add `dot-github/.github/workflows/self-lint.yml` self-wrapper

**Goal:** Replace the self-trigger behavior that was on the old `lint.yml` with a new dedicated self-wrapper file,
mirroring the `self-guard-main-docs.yml` precedent.

**Requirements:** R2, R3, R4, R5, R6.

**Dependencies:** U1 (the reusable must exist for the self-wrapper to call it).

**Files:**

- `dot-github/.github/workflows/self-lint.yml` — create

**Approach:** New workflow file. `name: "Self-lint workflows"`. Triggers: `on: push: branches: [main, dev]` + `on:
pull_request: branches: [main, dev]`. `permissions: contents: read`. Single job `jobs.lint: uses:
./.github/workflows/lint.yml` — local path reference (no `@ref`) so the self-wrapper exercises the PR's version of the
reusable. Header comment explains: filename differs from the reusable to avoid self-collision; uses `./...` to exercise
the PR's version; job key `lint` matches the standardized convention so the status-check name is stable as `Self-lint
workflows / lint / actionlint`.

**Patterns to follow:** `dot-github/.github/workflows/self-guard-main-docs.yml` (canonical self-wrapper shape).

**Test scenarios:**

- On a PR that modifies `dot-github/.github/workflows/lint.yml`, the self-wrapper runs the modified reusable (local-path
  semantics) and reports a check.
- On a clean PR (no workflow changes), the self-wrapper runs against the current `lint.yml` and reports green.
- Published check context observed via `gh api repos/brettdavies/.github/commits/<sha>/check-runs --jq
  '.check_runs[].name'` matches the expected `Self-lint workflows / lint / actionlint` shape (verifies the standardized
  job-id convention).

**Verification:** Self-wrapper run completes successfully on its own PR; the `gh api` check-run name lookup returns the
expected context string.

### U3. Update `dot-github/.github/rulesets/protect-main.json` for the new check context

**Goal:** Replace the existing required-status-check entry `actionlint` (from the old standalone `lint.yml`) with the
new context string published by the self-wrapper.

**Requirements:** R5.

**Dependencies:** U2 (the self-wrapper must have run at least once on a PR so the new context string is empirically
observable).

**Files:**

- `dot-github/.github/rulesets/protect-main.json` — modify
- `dot-github/README.md` — modify (line 184: update the `actionlint` reference to the new context name)

**Approach:** On the U2 PR, after the self-wrapper's first run, query `gh api
repos/brettdavies/.github/commits/<sha>/check-runs --jq '.check_runs[].name'` to confirm the published context string.
Update `required_status_checks` in `protect-main.json`: replace `"actionlint"` with the observed string (expected:
`"Self-lint workflows / lint / actionlint"`, but verify before editing). Update the README's documentation of published
contexts in the same PR.

Apply the updated ruleset to GitHub via `gh api -X PUT repos/brettdavies/.github/rulesets/<id> --input
.github/rulesets/protect-main.json` per the procedure documented in `dot-github/RELEASES.md`.

**Patterns to follow:** ruleset-update procedure in `dot-github/RELEASES.md` "Branch protection" section. The `gh api
.../check-runs` recipe is the canonical pattern from
`solutions-docs/integration-issues/github-status-check-context-inline-vs-reusable-2026-04-14.md`.

**Test scenarios:**

- After the ruleset update applies, opening a follow-up PR on `dot-github` shows the new context as a required check.
- The check transitions to "Required — Passing" rather than staying on "Expected — Waiting" (the failure mode that
  signals a context-string mismatch).

**Verification:** A new test PR against `dot-github main` shows the new context as required and reports passing.

### U4. Add `agentnative-spec/.github/workflows/lint.yml` consumer wrapper

**Goal:** Wire `agentnative-spec` to the centralized actionlint reusable; update `protect-main.json` after first CI run.

**Requirements:** R3, R4, R5, R6, R7.

**Dependencies:** U1, U2, U3 (the reusable must be live on `dot-github main` before consumers can call it via `@main`).

**Files:**

- `agentnative-spec/.github/workflows/lint.yml` — create
- `agentnative-spec/.github/rulesets/protect-main.json` — modify (add new required-check entry after first run)

**Approach:** New consumer wrapper file. `name: "Lint"`. Triggers: `on: push: branches: [main, dev]` + `on:
pull_request: branches: [main, dev]` (mirrors existing thin wrapper trigger shape — KD6). `permissions: contents: read`.
Single job `jobs.lint: uses: brettdavies/.github/.github/workflows/lint.yml@main`. No `with:` block (uses default
`fail_level: error`). Header comment block follows the existing thin-wrapper convention (e.g.,
`agentnative-spec/.github/workflows/guard-main-docs.yml`).

After the wrapper PR's first CI run, query `gh api repos/brettdavies/agentnative-spec/commits/<sha>/check-runs --jq
'.check_runs[].name'` to confirm the published context string. Update `required_status_checks` in `protect-main.json` to
add the observed string. Apply via `gh api -X PUT repos/brettdavies/agentnative-spec/rulesets/<id> --input ...`.

**Patterns to follow:** `agentnative-spec/.github/workflows/guard-main-docs.yml` (existing thin-wrapper shape). Ruleset
application procedure: `agentnative-spec/RELEASES.md`.

**Test scenarios:**

- Wrapper runs successfully on its own PR (which has no workflow file changes besides itself).
- Wrapper runs successfully on a follow-up PR that touches no workflow files.
- Published context string confirmed via `gh api` matches `Lint / lint / actionlint`.
- After ruleset update, the new context appears as required on a fresh PR.

**Verification:** PR for the wrapper merges green; ruleset PATCH succeeds; follow-up PR shows the new required check.

### U5. Add `agentnative-cli/.github/workflows/lint.yml` consumer wrapper

**Goal:** Wire `agentnative-cli` to the centralized actionlint reusable; update `protect-main.json` after first CI run.

**Requirements:** R3, R4, R5, R6, R7.

**Dependencies:** U1, U2, U3.

**Files:**

- `agentnative-cli/.github/workflows/lint.yml` — create
- `agentnative-cli/.github/rulesets/protect-main.json` — modify

**Approach:** Same shape as U4. Trigger branches mirror the existing `agentnative-cli/.github/workflows/ci.yml` shape
(`[main, dev]`). Ruleset update procedure identical.

The cli repo is the biggest beneficiary — most workflows and the most embedded shell. The reusable's bundled
shellcheck-on-`run:` integration closes the gap that the existing inline `shellcheck` job (which only scans
`./scripts/`) doesn't cover.

**Patterns to follow:** `agentnative-cli/.github/workflows/guard-main-docs.yml`.

**Test scenarios:**

- Wrapper runs successfully on the PR that introduces it.
- shellcheck-on-`run:` integration surfaces no findings on existing workflows (pre-flight confirmed clean — actionlint
  with shellcheck integration passes today).
- Published context string confirmed via `gh api`.

**Verification:** Wrapper PR merges green; ruleset PATCH succeeds.

### U6. Add `agentnative-site/.github/workflows/lint.yml` consumer wrapper

**Goal:** Wire `agentnative-site` to the centralized actionlint reusable; update `protect-main.json` after first CI run.

**Requirements:** R3, R4, R5, R6, R7.

**Dependencies:** U1, U2, U3.

**Files:**

- `agentnative-site/.github/workflows/lint.yml` — create
- `agentnative-site/.github/rulesets/protect-main.json` — modify

**Approach:** Same shape as U4. Trigger branches `[main, dev]`. Ruleset update procedure identical.

Note: `agentnative-site/.github/rulesets/protect-dev.json` ALSO has `required_status_checks` (the only consumer with
this on `dev`). Evaluate whether to add the new actionlint check to `protect-dev.json` as well — likely yes, for
consistency with the existing `lint · build · test · wrangler` enforcement on dev.

**Patterns to follow:** `agentnative-site/.github/workflows/guard-main-docs.yml`.

**Test scenarios:**

- Wrapper runs successfully on the PR.
- `deploy.yml`'s embedded shell `run:` blocks (the highest-stakes workflow in this repo) pass actionlint+shellcheck —
  pre-flight confirmed clean.
- Published context string confirmed via `gh api`.
- If protect-dev.json is updated, a follow-up `dev`-targeting PR shows the new required check.

**Verification:** Wrapper PR merges green; protect-main.json (and optionally protect-dev.json) PATCH succeeds.

### U7. Add `agentnative-skill/.github/workflows/lint.yml` consumer wrapper

**Goal:** Wire `agentnative-skill` to the centralized actionlint reusable; update `protect-main.json` after first CI
run. Stop the docs/CI drift documented in this repo's CONTRIBUTING.md and AGENTS.md.

**Requirements:** R3, R4, R5, R6, R7.

**Dependencies:** U1, U2, U3.

**Files:**

- `agentnative-skill/.github/workflows/lint.yml` — create
- `agentnative-skill/.github/rulesets/protect-main.json` — modify

**Approach:** Same shape as U4. Trigger branches mirror existing `agentnative-skill/.github/workflows/ci.yml` (`[main,
dev, feat/**, fix/**, chore/**, release/**]` for `push:`; `[main, dev]` for `pull_request:`). Ruleset update procedure
identical.

No CONTRIBUTING.md or AGENTS.md edit needed — both already document `actionlint .github/workflows/*.yml` as a required
local lint. After this unit lands, that documentation becomes honest CI enforcement.

**Patterns to follow:** `agentnative-skill/.github/workflows/guard-main-docs.yml`.
`agentnative-skill/.github/workflows/ci.yml` (for trigger-branch shape).

**Test scenarios:**

- Wrapper runs successfully on the PR.
- Published context string confirmed via `gh api`.
- After ruleset update, a fresh PR on `agentnative-skill` shows the new required check alongside existing
  `markdownlint`, `shellcheck`, `guard-docs / check-forbidden-docs`.

**Verification:** Wrapper PR merges green; ruleset PATCH succeeds; follow-up PR confirms the new required check.

---

## System-Wide Impact

**Five repos touched, eleven files changed:**

- `dot-github`: 1 modified (`lint.yml`), 1 created (`self-lint.yml`), 1 modified (`protect-main.json`), 1 modified
  (`README.md`).
- Four consumers: each 1 created (`lint.yml`) + 1 modified (`protect-main.json`). `agentnative-site` may additionally
  modify `protect-dev.json`.

**Cross-cutting concerns:**

- **Required-status-check ordering.** The ruleset PATCH on each repo must happen AFTER the wrapper PR's first CI run
  produces an observable check context. PATCH-before-run blocks PRs indefinitely.
- **`@main` reference contract.** Once consumers point at `brettdavies/.github/.../lint.yml@main`, the reusable's
  `workflow_call` interface becomes a public API. Adding required inputs or renaming the job is a breaking change for
  all four consumers.
- **Cherry-pick to `release/*`.** The wrapper-add PRs land on each consumer's `dev`, then cherry-pick to `release/*` for
  the next release. Per `cherry-pick-standalone-to-reusable-workflow-transition-20260413.md`, cherry-pick conflicts on
  the workflow file should take the cherry-pick side wholesale.
- **`dot-github` ruleset on `dev`.** `protect-dev.json` for `dot-github` has no required-status-checks today. The new
  self-lint context is added only to `protect-main.json`.

---

## Risks & Dependencies

**Risk: PR-blocking ruleset misfire.** If a consumer's `protect-main.json` gets the new context string added BEFORE the
wrapper PR lands, OR with a wrong string (e.g., `actionlint` instead of `Lint / lint / actionlint`), all subsequent PRs
on that repo block forever on "Expected — Waiting." Mitigation: every consumer unit (U4–U7) explicitly sequences ruleset
PATCH AFTER first CI run AND AFTER `gh api .../check-runs` confirmation. Recovery: revert the ruleset PATCH via `gh api
-X PUT ... --input <prior-version>`.

**Risk: Cherry-pick conflicts on `release/*`.** Each consumer's next release will need to cherry-pick the wrapper-add
commit from `dev` to `release/*`. The new wrapper file is greenfield (no conflict expected), but `protect-main.json` may
have other in-flight changes. Mitigation: standard release procedure handles this; take cherry-pick side wholesale per
the prior-art doc.

**Risk: `@main` reference drifts under feet.** If a future PR on `dot-github` changes the `lint.yml` reusable's input
contract or renames the job, all four consumers break on next workflow run. Mitigation: treat the `workflow_call`
interface as a public API; never make breaking changes without a coordinated PR across all five repos.

**Risk: Pre-flight false negative.** The actionlint pre-flight (audit doc) confirmed all five repos pass clean today. If
actionlint emits NEW findings between pre-flight and rollout (e.g., a workflow change lands during this plan's
execution), the wrapper PR will fail. Mitigation: re-run pre-flight (`actionlint .github/workflows/*.yml` in each repo)
right before opening each consumer's wrapper PR.

**Dependencies:**

- The `dot-github` work (U1, U2, U3) must complete and reach `main` before any consumer wrapper PR opens. Consumers
  reference `@main`.
- Each consumer's ruleset PATCH (within U4–U7) depends on first CI run completing — verifies the empirical check-context
  string.

---

## Phased Delivery

**Phase 1 — `dot-github` foundation (U1, U2, U3):**

One PR against `dot-github dev`, then standard `release/*` flow to `main`. After merge, `lint.yml` and `self-lint.yml`
are live on `main`, ruleset reflects the new context, and the `@main` reference is ready for consumers. The dot-github
self-wrapper validates the local-path pattern works as expected.

**Phase 2 — Consumer fan-out (U4, U5, U6, U7):**

Four independent PRs, one per consumer repo, all targetable in parallel after Phase 1 lands. Each PR follows the same
pattern: add wrapper, observe first CI run, query check context, PATCH ruleset. PR titles follow each consumer's
existing conventional-commits convention (e.g., `feat(ci): add centralized actionlint wrapper`).

Phase 2 order doesn't matter — consumers don't depend on each other. Recommended order if value-driven:
`agentnative-cli` first (biggest beneficiary), then `agentnative-site` (deploy.yml safety), then `agentnative-spec` and
`agentnative-skill` (smaller wins).

---

## Documentation / Operational Notes

- **`dot-github/README.md`**: line 184 ("the relevant published contexts include `actionlint`...") needs updating in U3
  to reflect the new context string.
- **`dot-github/RELEASES.md` § Self-applied reusable workflows**: the existing table calls out `guard-main-docs` +
  `self-guard-main-docs`; consider adding a row for `lint` + `self-lint` in U2 for documentation completeness.
- **Each consumer's `RELEASES.md` Branch protection section**: if any consumer documents the current
  required-status-checks list inline, update in the same PR as the ruleset PATCH.
- **`agentnative-skill/CONTRIBUTING.md:73` and `agentnative-skill/AGENTS.md:40`**: no edit needed. Both already document
  `actionlint` as a required local lint; this rollout makes the documentation honest. Leave as-is.
- **`agentnative-spec`, `agentnative-cli`, `agentnative-site` AGENTS.md / CONTRIBUTING.md**: optional addition
  documenting `actionlint .github/workflows/*.yml` as a local lint command. Per-consumer call during the wrapper PR.

After rollout completes, capture two follow-up solutions docs (per the institutional-learnings researcher's flagged
absences):

1. The `self-<name>.yml` self-wrapper pattern (`dot-github` precedent — currently exists only in workflow files, no
   doc).
2. The `paths:` filter / required-status-check interaction (no current solutions-doc entry; KD2's avoidance is the
   takeaway).

---

## Sources & References

- Pre-flight audit: `agentnative-skill/.context/audits/2026-05-27-001-actionlint-preflight.md`
- Existing reusable+self-wrapper precedent: `dot-github/.github/workflows/guard-main-docs.yml` +
  `dot-github/.github/workflows/self-guard-main-docs.yml`
- Existing thin-wrapper precedent: `agentnative-skill/.github/workflows/guard-main-docs.yml` (and equivalent in each
  consumer)
- Existing ci-stub mirror precedent (deferred option): `agentnative-site/.github/workflows/ci.yml` +
  `agentnative-site/.github/workflows/ci-stub.yml`
- `dot-github/RELEASES.md` (release procedure + ruleset application)
- `dot-github/RELEASES-RATIONALE.md` (branch-protection rationale, inline vs reusable context-string pitfall)
- Solutions: `integration-issues/github-status-check-context-inline-vs-reusable-2026-04-14.md`
- Solutions: `workflow-issues/cherry-pick-standalone-to-reusable-workflow-transition-20260413.md`
- Solutions: `architecture-patterns/release-pipeline-reusable-workflows-20260320.md`
- Solutions: `best-practices/ci-hardening-defaults-permissions-read-failfast-false-2026-04-20.md`
- GitHub Docs:
  [Troubleshooting required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)
- GitHub Docs: [Reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- GitHub Changelog:
  [Reusable workflows can be referenced locally (2022-01-25)](https://github.blog/changelog/2022-01-25-github-actions-reusable-workflows-can-be-referenced-locally/)
- Community discussion #8512: published context format for reusable callers
- Community discussion #44490: required-but-skippable path-filtered checks (still open)
- `reviewdog/action-actionlint` README (input contract, `fail_level` values)
