---
title: Concurrency Namespacing in the Rust CI Reusable - Plan
type: fix
date: 2026-09-14
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
artifact_readiness: implementation-ready
execution: code
---

# Concurrency Namespacing in the Rust CI Reusable - Plan

## Goal Capsule

- **Objective:** A repository that calls a reusable workflow from here gets a run whose result reflects its code. The
  reusable never cancels the run that invoked it, and a consumer that follows the house rule about concurrency groups
  does not lose half its CI by doing so.
- **Means:** `rust-ci.yml` keys its concurrency group on a literal token that identifies it, the way `rust-release.yml`
  already does, so a caller's own group and this one cannot resolve to the same string (KTD1).
- **Authority:** Requirements win on behavior. Key Technical Decisions win on mechanism. Units override neither.
- **Execution profile:** Configuration work whose failure mode is invisible locally. The proof is a consumer run that
  lists every job, observed on a real PR in a consumer repository.
- **Stop conditions:** Stop and ask if a consumer run still loses jobs after the change, which would mean the group key
  is not the cause. Stop and ask before changing any reusable other than `rust-ci.yml`.
- **Tail ownership:** Brett reviews and merges. The implementer opens the PR and stops.

---

## Product Contract

### Summary

`rust-ci.yml` declares `concurrency.group` as `${{ github.workflow }}-${{ github.ref }}`. Inside a called workflow,
`github.workflow` is the **caller's** workflow name, so that key is built entirely from values the caller can produce
itself. A caller that declares a group of the same shape lands in the same group, and because this workflow sets
`cancel-in-progress: true`, its queue cancels the run that called it.

`rust-release.yml`, in this same directory, already avoids the problem by keying on a literal token (`release-${{
github.repository }}`). This unit gives `rust-ci.yml` the same property and adds a check so a future reusable cannot
ship the hazardous shape.

### Problem Frame

On 2026-09-14 the `xurl-rs` consumer added a workflow-level concurrency group to its `ci.yml`, using the shape the house
standard documents. Its next run reported **failure with six green jobs and no `ci / *` job at all**. Nothing failed;
the seven jobs this reusable contributes never started, and no log or annotation said why. The consumer diagnosed it by
elimination and worked around it locally by adding a `-caller-` suffix to its own key, which restored the run to
thirteen jobs.

The reason the consumer hit it and `agentnative-cli` has not is that `agentnative-cli`'s `ci.yml` contains only the call
to this reusable. With no other job in the workflow, nothing holds the group before the reusable queues into it.
`xurl-rs` has five jobs of its own alongside the call, and those jobs take the group first. Any consumer that grows a
second job in a workflow that calls this one inherits the failure.

The standard's own guidance says a group named once inside a reusable "behaves correctly per-caller without each caller
redeclaring it," which is true and is the reason the key uses caller context. What it does not account for is a caller
that has its own jobs to protect and therefore must declare a group as well.

### Requirements

- **R1.** A reusable workflow here keys its concurrency group on a literal token identifying that workflow, so no caller
  can produce the same key from context.
- **R2.** `rust-ci.yml` keeps per-caller and per-ref separation, so two consumers, or two branches of one consumer, do
  not cancel each other.
- **R3.** `rust-ci.yml` states the caller-side rule where a consumer author will see it: a caller declares its own group
  only for jobs it defines, keyed on its own literal token.
- **R4.** A reusable added later with a context-only group key fails a check in this repository before it ships.
- **R5.** No change to which jobs run, their order, their inputs, or their permissions.

### Scope Boundaries

In scope: `rust-ci.yml`'s concurrency block, its caller-facing documentation, and a repository check covering every
workflow here.

Out of scope: `rust-release.yml`, which is already conformant and is a release path where a wrong edit costs a publish.
Also out of scope: updating the `bird` and `agentnative-cli` consumers. They are unaffected today because neither
declares a colliding group; if one breaks later it is fixed then, which is the owner's explicit call.

### Dependencies

None inbound. This PR merges **before** the companion `xurl-rs` PR, which removes its local workaround and relies on
this namespace being in place.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. A literal token leads the group key.** `rust-ci.yml` becomes `group: rust-ci-${{ github.workflow }}-${{
  github.ref }}`. The caller-context portion stays, which is what preserves R2: two consumers, and two branches of one
  consumer, still separate. The literal prefix is the part a caller cannot reproduce by accident, because it names this
  file rather than the run.

  Rejected: dropping the `concurrency:` block and letting each caller own cancellation. It reads clean and it silently
  removes cancellation from every consumer that does not declare a group, which is most of them. A fleet change that
  quietly stops cancelling superseded runs is a billing regression, and the standard's own rationale for these groups
  is billing.

  Rejected: exposing the group as a `workflow_call` input with a default. It moves a decision to every consumer that
  none of them has a reason to make differently, and a consumer that sets it wrong reintroduces the collision. An
  input is the right shape for something consumers genuinely vary; this is not that.

  Rejected: keying on `${{ github.repository }}` alone, as `rust-release.yml` does. Correct for a release, where
  concurrent publishes of one repository must serialize regardless of branch. Wrong for CI, where two branches of one
  repository must run at once.

- **KTD2. The caller-side rule is a comment in `rust-ci.yml`, not only in the standard's reference.** A consumer author
  reads the reusable when wiring it up. The rule belongs where the mistake is made: the file whose behavior surprises
  them. The comment states what a caller should declare and what happens if it mirrors this key.

- **KTD3. The check greps for the shape rather than parsing YAML.** The rule is that the value after `group:` does not
  begin with `$`. `actionlint`, which this repository already runs, models syntax rather than concurrency semantics and
  will not grow this check. A small script in the existing lint workflow and the existing hook pair is proportionate.

### Assumptions

- Concurrency groups are scoped per repository, so a literal token needs to be unique only among the workflows a single
  consumer runs. `rust-ci-` and `release-` do not collide with each other or with any caller token in use.
- Consumers pin these reusables at `@main`, so the fix reaches every consumer on merge with no consumer-side action.
  That is also why R5 matters: this lands in every consumer's next run without review by them.

---

## Implementation Units

### U1. Namespace the Rust CI group and state the caller rule

- **Goal:** A caller's group and this workflow's group cannot resolve to one string.
- **Requirements:** R1, R2, R3, R5.
- **Dependencies:** None.
- **Files:** `.github/workflows/rust-ci.yml`.
- **Approach:**
  1. The group becomes `rust-ci-${{ github.workflow }}-${{ github.ref }}`; `cancel-in-progress: true` is unchanged.
  2. A comment above the block records why the literal token is there: `github.workflow` resolves to the caller inside a
     called workflow, so a key built only from context is a key the caller also produces. It names the consequence in
     one line, that the reusable's queue cancels its own caller's run, because that consequence is what nothing in the
     logs will tell the next person.
  3. A line in the caller-facing header block states what a caller does: declare a group only for jobs the caller
     defines, keyed on its own literal token, and never mirror this one.
- **Patterns to follow:** `rust-release.yml`'s `group: release-${{ github.repository }}` and the caller-example comment
  block already at the top of `lint-basics.yml`.
- **Test scenarios:**
  - Test expectation: none here. This repository has no runner for a reusable in isolation; the behavior is proven by a
    consumer run, below.
- **Verification:** `actionlint` clean. Then, from the `xurl-rs` consumer with its own group restored to the
  non-suffixed shape, a PR run lists all thirteen checks including all seven `ci / *` jobs. That is the direct
  reproduction of the original failure, so it is the only verification that proves the fix rather than describing it.

### U2. A check that rejects a context-only group key

- **Goal:** R1 holds for reusables added later, without anyone remembering it.
- **Requirements:** R4.
- **Dependencies:** U1 lands first, so the check starts green.
- **Files:** `scripts/check-workflow-concurrency.sh` (create), `.github/workflows/lint.yml`, `scripts/hooks/pre-commit`,
  `scripts/hooks/pre-push`.
- **Approach:**
  1. The script scans `.github/workflows/*.yml` for a `group:` line inside a `concurrency:` block and fails when its
     value starts with `$`. The message names the file, states the rule, and gives the fix, because whoever trips it
     will not know the history.
  2. A job or step in `lint.yml` runs it beside `actionlint`.
  3. The existing hooks call it when a workflow file is staged or pushed, matching how they already gate `actionlint`.
- **Patterns to follow:** the existing `actionlint` step in `lint.yml`; the tool-presence and skip-notice shape in
  `scripts/hooks/pre-push`.
- **Test scenarios:**
  - A workflow whose group is `${{ github.workflow }}-${{ github.ref }}`: non-zero exit naming the file.
  - `rust-ci.yml` after U1 and `rust-release.yml` as they stand: zero exit.
  - A workflow with no `concurrency:` block: zero exit.
  - The script observed failing against `rust-ci.yml` as it is **before** U1, which is what proves it detects the real
    case rather than a constructed one.
- **Verification:** `shellcheck --severity=warning` clean. `lint.yml` passes on the PR.

---

## Verification Contract

| Gate              | Command                                                               | Expected                                    |
| ----------------- | --------------------------------------------------------------------- | ------------------------------------------- |
| Workflow lint     | `actionlint`                                                          | Clean                                       |
| Shell lint        | `shellcheck --severity=warning scripts/check-workflow-concurrency.sh` | Clean                                       |
| Concurrency check | `bash scripts/check-workflow-concurrency.sh`                          | Zero exit, after U1                         |
| Check bites       | The same script against `rust-ci.yml` before U1                       | Non-zero, naming the file                   |
| Consumer proof    | A `xurl-rs` PR run after its workaround is removed                    | Thirteen checks, all seven `ci / *` present |

The consumer run is the gate that matters. Nothing runnable in this repository exercises a reusable end to end, and
every local check passed while the collision was live.

---

## Definition of Done

- `rust-ci.yml`'s group begins with `rust-ci-` and retains its caller and ref components.
- The file states the caller-side rule where a consumer author will read it.
- The check fails on a context-only key and passes on this repository, in the hooks and in `lint.yml`.
- A consumer PR run, with its local workaround removed, lists every job including all seven from this reusable.
- The PR body states that consumers pin `@main`, so this reaches them on merge, and names `bird` and `agentnative-cli`
  as knowingly unverified.
- No experimental or abandoned code remains in the diff.

---

## Sources

- The failing consumer run: `brettdavies/xurl-rs` Actions run `34910294817`, six green jobs, no `ci / *`, conclusion
  `failure`.
- The passing run after the consumer-side workaround: `34910560339`, thirteen jobs, conclusion `success`.
- GitHub concurrency semantics: a queued job entering a group already held in progress cancels the in-progress work when
  `cancel-in-progress: true` is set.
- In-repo precedent: `.github/workflows/rust-release.yml`.
- The companion consumer plan: `docs/plans/2026-09-14-1916-fix-concurrency-group-ownership-plan.md` in `xurl-rs`.
