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
      rust-release-matrix-check.yml  # reusable pre-tag build of the release matrix
      rust-lib-release.yml  # reusable release workflow (library crate)
      rust-finalize-release.yml  # reusable finalize workflow
      search-presence.yml   # reusable post-deploy search monitoring for a site
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

A caller whose Homebrew formula installs the release's archives, rather than building the tagged source, needs
`attest: true`. `brettdavies/homebrew-tap` verifies each archive such a formula names against its attestation, with
this workflow as the signer, before it pins the checksum, and stops the formula bump when an archive has none.

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

### `rust-release-matrix-check.yml`

Builds the seven targets `rust-release.yml` builds, and releases nothing. The release build runs only on a tag push, so
without this a dependency that breaks a cross-compiled target is found while cutting the release, after the tag exists.
A caller runs it when its dependency graph or toolchain pin changes and on every release branch.

Every row is hard-fail, including the two linux-musl rows the release soft-fails by default. For a caller whose release
passes `linux_musl_required: true`, a red row here means the release would fail on the same row.

The matrix holds the same rows as the release build's. `scripts/check-release-matrix-parity.sh` compares the two by
target, runner, and cross flag, and fails this repo's lint run when they differ.

|                                 |                  |
| ------------------------------- | ---------------- |
| **Trigger**                     | `workflow_call`  |
| **Inputs**                      | None             |
| **Secrets**                     | None             |
| **Required caller permissions** | `contents: read` |

Triggers, path filters, and the concurrency group belong to the caller, because which paths can break a build differs
per repo.

**Caller example:**

```yaml
name: Release matrix check
on:
  workflow_dispatch:
  pull_request:
    paths:
      - Cargo.toml
      - Cargo.lock
      - rust-toolchain.toml
      - .github/workflows/release-matrix-check.yml
  push:
    branches: ['release/**']
permissions:
  contents: read
concurrency:
  group: release-matrix-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    uses: brettdavies/.github/.github/workflows/rust-release-matrix-check.yml@main
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

### `search-presence.yml`

Search monitoring for a site repository, run after each deploy. It runs the search-presence skill against the site's
`search-presence.toml`: the audit of what the site serves crawlers, submission of new and changed URLs to IndexNow,
Bing, and the Google sitemap, the Request indexing queue for the pages each deployment changed, the Search Console and
Bing index reads, and the report. The report goes to the job summary and to the site's one issue, which each run opens,
rebuilds, or closes. The job fails when a finding is at or above the config's `fail_on`, so that level lives in the
config.

Google is read with no stored key: Workload Identity Federation exchanges the job's OIDC token for a Search Console
access token, read-only unless `apply` is set, and the run puts it in the variable the config's `google.token_env`
names. A config with no `[google]` table skips Google.

The quota ledger, the submission ledger, the coverage cache, and the snapshots live in the Actions cache under one key
prefix per site. Each run restores them first and saves them last, whether it passed or failed, and runs for one
repository and config queue rather than overlap. Only `push`, `schedule`, and `workflow_dispatch` runs on the default
branch save state that later runs on that branch restore.

Submissions are a dry run unless `apply: true`. A submission ledger that has never seen the site, including one whose
cache entry was evicted, holds every URL until the first-run choice: give one run `apply: true` and
`first_run: baseline` (record the current state, send nothing) or `first_run: submit` (send every URL, for a new site),
then leave `first_run` empty.

The job summary and the issue show every finding's detail, impression and click totals included, to anyone who can read
the repository.

|                                 |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Inputs**                      | `config` (string, optional, default `search-presence.toml`), `apply` (bool, optional, default `false`; send submissions and ask for the read-write Search Console scope), `first_run` (string, optional, `baseline` or `submit`, default empty), `deployed_at` (string, optional, ISO 8601 with a zone, default the job's start), `skill_repository` (string, optional, default the skill's repository), `skill_ref` (string, optional, default `main`)                                              |
| **Secrets**                     | `SEARCH_PRESENCE_SKILL_TOKEN` (required; fine-grained PAT with Contents: read on the skill's repository only), `SEARCH_PRESENCE_WIF_PROVIDER` (required; the workload identity provider's full resource name), `SEARCH_PRESENCE_SERVICE_ACCOUNT` (required; the service account's email, a user on the Search Console property), `BING_WEBMASTER_API_KEY` (required), `INDEXNOW_KEY` (optional; without it IndexNow is skipped), `GOOGLE_API_KEY` (optional; without it Core Web Vitals are skipped) |
| **Required caller permissions** | `contents: read`, `id-token: write`, `issues: write`                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

**Caller example:**

```yaml
name: Deploy
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  deploy:
    runs-on: ubuntu-24.04
    steps:
      - run: <deploy the site>
  search-presence:
    needs: deploy
    uses: brettdavies/.github/.github/workflows/search-presence.yml@main
    permissions:
      contents: read
      id-token: write
      issues: write
    secrets:
      SEARCH_PRESENCE_SKILL_TOKEN: ${{ secrets.SEARCH_PRESENCE_SKILL_TOKEN }}
      SEARCH_PRESENCE_WIF_PROVIDER: ${{ secrets.SEARCH_PRESENCE_WIF_PROVIDER }}
      SEARCH_PRESENCE_SERVICE_ACCOUNT: ${{ secrets.SEARCH_PRESENCE_SERVICE_ACCOUNT }}
      BING_WEBMASTER_API_KEY: ${{ secrets.BING_WEBMASTER_API_KEY }}
```

Pass `INDEXNOW_KEY` and `GOOGLE_API_KEY` the same way to turn on IndexNow and Core Web Vitals.

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
- `search-presence.yml` validates `config`, `first_run`, and `deployed_at`, and refuses a `google.token_env` that names
  a variable the runner or the workflow already sets
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
