# `reconcile-lockfile` action

Regenerate a lockfile (or any derived, must-be-rebuilt artifact) after a Dependabot bump and commit it back to the pull
request branch.

## Why

Dependabot updates a manifest (`package.json`, `Cargo.toml`, ...) but does not always reconcile the matching lockfile.
Bun is the clearest case: Dependabot bumps `package.json` and leaves `bun.lock` stale, so the next `bun install
--frozen-lockfile` (CI and the local pre-push hook) fails on every Dependabot PR. This action runs the reconcile command
on the PR branch and pushes the regenerated file back, so the frozen install sees a lockfile that matches the manifest.

## Inputs

| Input            | Required | Default                                                 | Description                                                                    |
| ---------------- | -------- | ------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `command`        | yes      | —                                                       | Command that regenerates the artifact(s), e.g. `bun install --ignore-scripts`. |
| `files`          | yes      | —                                                       | Space-separated paths to stage and commit when changed, e.g. `bun.lock`.       |
| `commit-message` | no       | `chore(deps): reconcile lockfile after dependency bump` | Message for the reconcile commit.                                              |

The action pushes only when `files` change; a bump that leaves the lockfile untouched is a no-op, which also makes the
second run (after the reconcile push) terminate without looping.

## Calling job owns checkout and setup

The action runs the command and pushes; the caller owns everything ecosystem-specific:

- **Checkout with a write-capable token.** A `GITHUB_TOKEN` push does not re-trigger checks, so the required check never
  lands on the reconciled head and the PR stays unmergeable. Check out with a PAT (stored as a **Dependabot secret**,
  since Dependabot-triggered runs cannot see Actions secrets) so the push re-triggers CI on the new head.
- **Toolchain setup.** `setup-bun`, `setup-node`, the Rust toolchain — whatever the reconcile command needs.
- **The `dependabot[bot]` actor guard**, so the job runs only on Dependabot PRs.

## Example (Bun)

```yaml
name: Dependabot lockfile sync

on:
  pull_request:
    branches: [dev, main]

permissions:
  contents: read

jobs:
  reconcile:
    if: github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@<sha> # v7.0.1
        with:
          ref: ${{ github.head_ref }}
          token: ${{ secrets.DEPENDABOT_RECONCILE_TOKEN }}
      - uses: oven-sh/setup-bun@<sha> # v2.2.0
        with:
          bun-version: 1.3.14
      - uses: brettdavies/.github/actions/reconcile-lockfile@main
        with:
          command: bun install --ignore-scripts
          files: bun.lock
```

## The `DEPENDABOT_RECONCILE_TOKEN` secret

A fine-grained PAT scoped to the repo with **Contents: Read and write** and nothing else, stored as a **Dependabot**
secret (`gh secret set DEPENDABOT_RECONCILE_TOKEN --app dependabot --repo <owner>/<repo>`). `brettdavies` is a user
account, so there is no org-level secret store; each repo carries its own.
