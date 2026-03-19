# brettdavies/.github

Reusable GitHub Actions workflows for all brettdavies Rust CLI tools.

## Why

Every SHA bump, runner update, or new feature requires exactly one PR to this repo
instead of N PRs across N consumer repos.

## Directory structure

GitHub requires reusable workflows in `.github/workflows/`. Since this repo *is*
named `.github`, the on-disk path is:

```text
.github/                    # repo root
  .github/                  # GitHub's special directory
    workflows/
      rust-ci.yml           # reusable CI workflow
      rust-release.yml      # reusable release workflow
      rust-finalize-release.yml  # reusable finalize workflow
      lint.yml              # internal: actionlint on push/PR
```

## Reusable workflows

### `rust-ci.yml`

CI for Rust CLI tools: fmt, clippy, test, security audit, package check, changelog.

| | |
|---|---|
| **Trigger** | `workflow_call` (no inputs) |
| **Required caller permissions** | `contents: write` |
| **Secrets** | `CHANGELOG_TOKEN` (optional) — PAT with admin bypass for changelog commits past rulesets. Falls back to `GITHUB_TOKEN`. Required on personal repos with `pull_request` rulesets. |

**Caller example:**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  contents: write
jobs:
  ci:
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
    secrets:
      CHANGELOG_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

### `rust-release.yml`

Full release pipeline: version check, audit, cross-platform build (5 targets),
crates.io publish (Trusted Publishing OIDC), draft GitHub Release, Homebrew dispatch.

| | |
|---|---|
| **Trigger** | `workflow_call` |
| **Inputs** | `crate` (string, required), `bin` (string, required) |
| **Secrets** | `HOMEBREW_TAP_TOKEN` (required, explicit — not inherited) |
| **Required caller permissions** | `contents: write`, `id-token: write` |

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
      HOMEBREW_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

### `rust-finalize-release.yml`

Publishes a draft GitHub Release after Homebrew bottles are uploaded.

| | |
|---|---|
| **Trigger** | `workflow_call` (no inputs) |
| **Required caller permissions** | `contents: write` |
| **Secrets** | None (only `GITHUB_TOKEN`, which flows automatically) |

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

The Homebrew dispatch chain assumes `formula name == crate name == repo name`.
If a future tool breaks this coupling, add an optional `formula` input to
`rust-release.yml` and update `homebrew-tap/publish.yml`.
