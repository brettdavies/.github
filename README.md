# brettdavies/.github

Reusable GitHub Actions workflows for brettdavies repositories.

## Why

Every SHA bump, runner update, or new feature requires exactly one PR to this repo instead of N PRs across N consumer
repos.

## Directory structure

GitHub requires reusable workflows in `.github/workflows/`. Since this repo *is* named `.github`, the on-disk paths are:

```text
.github/                    # repo root
  .github/                  # GitHub's special directory
    workflows/
      rust-ci.yml           # reusable CI workflow
      rust-release.yml      # reusable release workflow (binary crate)
      rust-lib-release.yml  # reusable release workflow (library crate)
      rust-finalize-release.yml  # reusable finalize workflow
      lint.yml              # internal: actionlint on push/PR
```

## Reusable workflows

### `rust-ci.yml`

CI for Rust CLI tools: fmt, clippy, test, security audit, package check.

|                                 |                                                                                                                                                                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call` (no secrets)                                                                                                                                                                                                          |
| **Inputs**                      | `advisories_blocking` (bool, optional, default `false`), `windows_nasm` (bool, optional, default `false`; NASM on the Windows job), `docs_only` (bool, optional, default `false`; every job reports skipped, which counts as passing) |
| **Required caller permissions** | `contents: read`                                                                                                                                                                                                                      |

**Caller example:**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  ci:
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
```

### `rust-release.yml`

Full release pipeline: version check, audit, cross-platform build (7 targets — 5 hard-required, 2 linux-musl rows
soft-fail by default), crates.io publish (Trusted Publishing OIDC), draft GitHub Release (notes extracted from the
changelog the `changelog` input names, the repository root's `CHANGELOG.md` by default), Homebrew dispatch.

With `attest: true`, the archives the build jobs produced and `sha256sum.txt` are attested with build provenance, and a
CycloneDX SBOM of the binary is attested against the archives, before anything is published: a failed attestation
publishes no crate and no release. Once the release exists, every published file is verified against its attestation,
and the Homebrew dispatch goes out only when that passes. The signing job runs no code from the caller's repository;
the SBOM is generated in a job of its own with a read-only token. This workflow is the signer, so a release verifies
with `gh attestation verify <archive> --repo <owner>/<repo> --signer-workflow
brettdavies/.github/.github/workflows/rust-release.yml`.

|                                 |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Trigger**                     | `workflow_call`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **Inputs**                      | `crate` (string, required), `bin` (string, required), `linux_musl_required` (bool, optional, default `false`), `linux_musl_verify_alpine` (bool, optional, default `false`), `changelog` (string, optional, default the repository root's `CHANGELOG.md`), `artifact_name` (string, optional, default the crate name), `windows_nasm` (bool, optional, default `false`; NASM on the `x86_64-pc-windows-msvc` row), `attest` (bool, optional, default `false`; build-provenance and SBOM attestations for the release archives) |
| **Secrets**                     | `CI_RELEASE_TOKEN` (required, explicit — not inherited)                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Required caller permissions** | `contents: write`, `id-token: write`; with `attest: true`, also `attestations: write`                                                                                                                                                                                                                                                                                                                                                                                                                                          |

**Caller example:**

```yaml
name: Release
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+']
permissions:
  contents: write
  id-token: write
jobs:
  pipeline:
    uses: brettdavies/.github/.github/workflows/rust-release.yml@main
    with:
      crate: bird
      bin: bird
    secrets:
      CI_RELEASE_TOKEN: ${{ secrets.CI_RELEASE_TOKEN }}
```

### `rust-lib-release.yml`

Release pipeline for a library crate in a workspace: version check against the crate's own `Cargo.toml`, audit, `cargo
publish -p <crate>` (Trusted Publishing OIDC), GitHub Release (notes extracted from the changelog beside the crate,
`make_latest: false` so the binary's release stays the repository's latest). No binaries, no Homebrew.

|                                 |                                                                                                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call`                                                                                                                                                              |
| **Inputs**                      | `crate` (string, required), `tag_prefix` (string, optional, default `<crate>-v`), `changelog` (string, optional, default the `CHANGELOG.md` beside the crate's `Cargo.toml`) |
| **Secrets**                     | None (crates.io Trusted Publishing and `GITHUB_TOKEN`, which flow automatically)                                                                                             |
| **Required caller permissions** | `contents: write`, `id-token: write`                                                                                                                                         |

**Caller example:**

```yaml
name: Release library
on:
  push:
    tags: ['xdk-rs-v[0-9]+.[0-9]+.[0-9]+']
permissions:
  contents: write
  id-token: write
jobs:
  pipeline:
    uses: brettdavies/.github/.github/workflows/rust-lib-release.yml@main
    with:
      crate: xdk-rs
```

### `rust-finalize-release.yml`

Publishes a draft GitHub Release after Homebrew bottles are uploaded.

|                                 |                                                       |
| ------------------------------- | ----------------------------------------------------- |
| **Trigger**                     | `workflow_call` (no inputs)                           |
| **Required caller permissions** | `contents: write`                                     |
| **Secrets**                     | None (only `GITHUB_TOKEN`, which flows automatically) |

**Caller example:**

```yaml
name: Finalize Release
on:
  repository_dispatch:
    types: [finalize-release]
permissions:
  contents: write
jobs:
  finalize:
    uses: brettdavies/.github/.github/workflows/rust-finalize-release.yml@main
```

### `guard-main-docs.yml`

Blocks engineering docs (`docs/architecture/`, `docs/brainstorms/`, `docs/ideation/`, `docs/plans/`, `docs/research/`,
`docs/reviews/`, `docs/solutions/`) from reaching main.

|                                 |                             |
| ------------------------------- | --------------------------- |
| **Trigger**                     | `workflow_call` (no inputs) |
| **Required caller permissions** | `pull-requests: read`       |

**Caller example:**

```yaml
name: Guard main from engineering docs
on:
  pull_request:
    branches: [main]
permissions:
  pull-requests: read
jobs:
  guard-docs:
    uses: brettdavies/.github/.github/workflows/guard-main-docs.yml@main
```

### `guard-main-provenance.yml`

Verifies that every non-exempt commit in a PR to `main` carries a `(#N)` PR reference, indicating it was squash-merged
from a feature PR to `dev`. Catches direct-pushes to `dev` or release branches that bypass the PR-review boundary.

Skipped automatically for `release/*` head branches — cherry-picks from dev inherently lose their PR references, and the
release PR itself is the review gate.

Exempt commit-message prefixes: `docs:`, `chore:`, `ci:`, `style:`, `build:` (housekeeping commits authored directly on
the release branch — version bumps, changelogs, CI tweaks). `test:` is **not** exempt — tests are code and must go
through PRs.

|                                 |                             |
| ------------------------------- | --------------------------- |
| **Trigger**                     | `workflow_call` (no inputs) |
| **Required caller permissions** | `pull-requests: read`       |

**Caller example:**

```yaml
name: Guard main commit provenance
on:
  pull_request:
    branches: [main]
permissions:
  pull-requests: read
jobs:
  guard-provenance:
    uses: brettdavies/.github/.github/workflows/guard-main-provenance.yml@main
```

### `guard-release-branch.yml`

Rejects PRs to main whose head branch doesn't start with `release/`. Enforces the release-branch pattern so that `dev`
is never a PR head (which keeps `deleteBranchOnMerge: true` compatible with a forever `dev` branch).

|                                 |                                                                   |
| ------------------------------- | ----------------------------------------------------------------- |
| **Trigger**                     | `workflow_call` with optional `prefix` input (default `release/`) |
| **Required caller permissions** | `pull-requests: read`                                             |

**Caller example:**

```yaml
name: Guard release branch pattern
on:
  pull_request:
    branches: [main]
permissions:
  pull-requests: read
jobs:
  guard-release:
    uses: brettdavies/.github/.github/workflows/guard-release-branch.yml@main
```

## Ruleset templates

Starting points for GitHub branch protection, committed under `.github/rulesets/`. Consumer repos copy these into their
own `.github/rulesets/` and extend the `required_status_checks` list with repo-specific checks.

| Template            | Purpose                                                                                                                                                                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `protect-main.json` | Squash-only PR merge, linear history, required signatures, `actionlint` required. Add repo-specific checks (`ci / <job>`, `guard-docs / check-forbidden-docs`, `Guard release branch pattern / check-release-branch-name`) before applying. |
| `protect-dev.json`  | Dev forever-branch protection: no deletion, no non-fast-forward, required signatures. No PR requirement at the ruleset level (enforced by convention + `guard-release-branch` on the main side).                                            |

Apply with `gh api`:

```bash
gh api -X POST repos/<owner>/<repo>/rulesets --input .github/rulesets/protect-dev.json
gh api -X PUT  repos/<owner>/<repo>/rulesets/<id> --input .github/rulesets/protect-main.json
```

## Security

- All third-party actions are SHA-pinned (except `dtolnay/rust-toolchain@stable`)
- No `secrets: inherit` — secrets are passed explicitly
- All `${{ }}` expressions in `run:` blocks use `env:` indirection (zero direct interpolation)
- Input validation: `crate` and `bin` are validated with `[a-zA-Z0-9_-]+` regex
- Tag format validation in finalize-release (`^v[0-9]+\.[0-9]+\.[0-9]+$`)
- Per-job permission narrowing inside reusable workflows

## Ref pinning

Consumer repos reference these workflows via `@main`. Rationale:

- Same owner controls all repos (no supply chain risk)
- `actionlint` CI + branch protection catches errors before propagation
- Rollback: revert one commit in this repo (faster than updating N consumers)

Migrate to `@v1` semver tags when a third-party contributor or third+ consumer arrives.

## Naming convention

- `rust-*` prefix: language-specific reusable workflows
- Unprefixed (`lint.yml`): repo-internal infrastructure
- Caller workflows stay unprefixed (`ci.yml`, `release.yml`) — they describe intent

## Naming coupling

The Homebrew dispatch chain assumes `formula name == crate name == repo name`. If a future tool breaks this coupling,
add an optional `formula` input to `rust-release.yml` and update `homebrew-tap/publish.yml`.

## Local hooks

`scripts/hooks/` carries `pre-commit` (actionlint + markdownlint on staged files) and `pre-push` (actionlint,
markdownlint, shellcheck across the repo), mirroring the CI lint gate locally. Activate per clone:

```bash
git config core.hooksPath scripts/hooks
```

Each check no-ops with a notice when its tool is not installed.
