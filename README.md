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
      rust-change-scope.yml # reusable docs-only classifier feeding rust-ci.yml's docs_only
      rust-changelog-bump.yml  # reusable surface-growth check against the PR's changelog block
      rust-release.yml      # reusable release workflow (binary crate)
      rust-release-matrix-check.yml  # reusable pre-tag build of the release matrix
      rust-lib-release.yml  # reusable release workflow (library crate)
      rust-finalize-release.yml  # reusable finalize workflow
      pr-cache-cleanup.yml  # reusable delete of a closed pull request's Actions caches
      rust-cache-prune.yml  # reusable delete of a branch's superseded rust-cache entries after a warm run
      search-presence.yml   # reusable post-deploy search regression gate for a site
      lint-basics.yml       # reusable actionlint, markdownlint, shellcheck, and plan frontmatter
      lint.yml              # internal: actionlint on push/PR
  actions/
    actionlint/             # composite action behind lint-basics.yml's actionlint job
    plan-frontmatter/       # composite action behind lint-basics.yml's plans job
```

## Reusable workflows

### `rust-ci.yml`

CI for Rust CLI tools: fmt, clippy, test, security audit, package check.

|                                 |                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call` (no secrets)                                                                                                                                                                                                                                                                                                                                                              |
| **Inputs**                      | `advisories_blocking` (bool, optional, default `false`), `audit_ref` (string, optional, default empty; the ref the audit checks out), `docs_only` (bool, optional, default `false`; every job reports skipped, which counts as passing), `toolchain` (string, optional, default `stable`; a rust-toolchain file in the caller's repository outranks it), and the run-shaping inputs below |
| **Required caller permissions** | `contents: read`                                                                                                                                                                                                                                                                                                                                                                          |

Opt-in jobs, each off by default. A job that is off reports skipped, which a ruleset counts as passing. Three of them
run a script from the caller's checkout, because the rule it enforces belongs to the repository.

| Input                         | Job (check name under a `ci:` caller)  | What it runs                                                                                                   |
| ----------------------------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `cross_os_tests` (bool)       | `ci / Windows test`, `ci / macOS test` | `cargo test` on `windows-latest` and `macos-15`, the command the Linux job runs                                |
| `docs` (bool)                 | `ci / Doc build`                       | `cargo doc --workspace --no-deps --locked` with `RUSTDOCFLAGS=-D warnings`                                     |
| `msrv` (bool)                 | `ci / MSRV`                            | `cargo +<rust-version> check --workspace --all-features --locked`, the version read from the root `Cargo.toml` |
| `completions` (bool)          | `ci / Completions freshness`           | `scripts/generate-completions.sh --check`                                                                      |
| `lint_stdio` (bool)           | `ci / Output discipline`               | `scripts/lint-stdio.sh`, with ripgrep installed                                                                |
| `workflow_concurrency` (bool) | `ci / Workflow concurrency`            | `scripts/check-workflow-concurrency.sh`, vendored from github-repo-setup                                       |
| `anc_version` (string)        | `ci / Agent-native audit`              | `anc audit . --bin <anc_bin>` at that anc release, against the source tree and the release binary              |

The audit's other inputs: `anc_bin` (string, required with `anc_version`), `anc_score_floor` (number, default `0`; fails
below that `badge.score_pct`), `anc_blocking_tiers` (`must` by default, or `any` to fail on every `fail` or `error`
row), and `release_size_ceiling_bytes` (number, default `0` for no ceiling). The scorecard uploads as the
`anc-scorecard` artifact whenever the audit runs.

Every job builds the `dev` and `test` profiles with line-tables-only debug info and no incremental artifacts, set in the
workflow's own `env`. A caller's workflow `env` never reaches a called workflow's jobs, so a caller need not set either
for this workflow; `line-tables-only` needs Rust 1.71 or later.

Every job installs its toolchain with `rustup`. A caller with a `rust-toolchain.toml` or `rust-toolchain` file builds on
the toolchain the file names, with its components; any other caller builds on `toolchain`.

#### Choosing, warming, and splitting jobs

Three inputs change how a run goes rather than adding a check. Each defaults to the run described above.

| Input                  | Default | What it does                                                                                                                                                                                                                                                                                                                             |
| ---------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `jobs` (string)        | `all`   | A JSON array of the job ids to run, such as `'["fmt-clippy","tests"]'`; `'[]'` runs none. A job runs only when its own input turns it on, `docs_only` is false, and `jobs` names it. An id the workflow does not have fails `ci / Inputs`, which a ruleset should require.                                                               |
| `warm_cache` (bool)    | `false` | Builds what each check compiles without running it (`--no-run` tests, `cargo check` for clippy), and saves each cache only when its job succeeds; jobs that keep no Rust cache skip. Pass it on push, from a caller job of its own (`warm:` below), so its checks report as `warm / <job>` and never under a required `ci / <job>` name. |
| `test_runner` (string) | `cargo` | `nextest` runs `Fmt, clippy` and `Tests` in place of `Fmt, clippy, test`. `Tests` installs cargo-nextest at `nextest_version` (required), then runs `cargo nextest run --profile ci` and `cargo test --doc`; the `ci` profile comes from the caller's `.config/nextest.toml`.                                                            |

The `ci` profile can be as small as this, in the caller's `.config/nextest.toml`:

```toml
[profile.ci]
fail-fast = false
```

With `test_runner: nextest`, `test_partitions` (number, 1 to 4, default 1) runs `Tests` as that many
`--partition hash:k/N` jobs, named `Tests (k/N)`, the first of which also runs the doc tests, and `anc_debug_audit`
(bool, default `false`) has `Tests` build the debug `anc_bin` and audit it against `anc_score_floor` and
`anc_blocking_tiers`.

`ci / Inputs` runs only when one of `jobs`, `test_runner`, `test_partitions`, or `anc_debug_audit` is set, and reports
skipped otherwise. Under the cargo runner `ci / Fmt, clippy` and `ci / Tests` report skipped, and under nextest
`ci / Fmt, clippy, test` does. Every job name is literal, because GitHub reports a skipped job under its raw `name:`
text.

| Job id                       | Check name under a `ci:` caller                                                     |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| `check`                      | `ci / Fmt, clippy, test` (cargo runner)                                             |
| `fmt-clippy`                 | `ci / Fmt, clippy` (nextest runner)                                                 |
| `tests`                      | `ci / Tests (1/1)`, or `ci / Tests (k/N)` for each of N partitions (nextest runner) |
| `check-windows`              | `ci / Windows check`                                                                |
| `audit`                      | `ci / Security audit (advisories)`, `ci / Security audit (bans licenses sources)`   |
| `package-check`              | `ci / Package check`                                                                |
| `shellcheck`                 | `ci / Shellcheck`                                                                   |
| `test-windows`, `test-macos` | `ci / Windows test`, `ci / macOS test`                                              |
| `docs`                       | `ci / Doc build`                                                                    |
| `msrv`                       | `ci / MSRV`                                                                         |
| `completions`                | `ci / Completions freshness`                                                        |
| `lint-stdio`                 | `ci / Output discipline`                                                            |
| `workflow-concurrency`       | `ci / Workflow concurrency`                                                         |
| `anc`                        | `ci / Agent-native audit`                                                           |
| `changelog-check`            | `ci / Changelog`                                                                    |

**Caller example:**

```yaml
name: CI
on:
  pull_request:
permissions:
  contents: read
jobs:
  ci:
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
    with:
      cross_os_tests: true
      docs: true
      msrv: true
      completions: true
      lint_stdio: true
      workflow_concurrency: true
```

**Caller example, scoped and warmed:** a scope job names the jobs a change needs, and push runs fill the caches from a
caller job of their own. `if: ${{ !cancelled() }}` keeps the call running when the scope job fails, and `|| 'all'` then
runs every job, since a failed job's outputs are empty.

```yaml
on:
  pull_request:
  push:
    branches: [dev, main]
jobs:
  ci:
    needs: scope
    if: ${{ !cancelled() && github.event_name == 'pull_request' }}
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
    with:
      jobs: ${{ needs.scope.outputs.jobs || 'all' }} # a JSON array, such as '["fmt-clippy","tests"]'
      test_runner: nextest
      nextest_version: 0.9.150
  warm:
    if: github.event_name == 'push'
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
    with:
      warm_cache: true
      test_runner: nextest
      nextest_version: 0.9.150
```

### `rust-change-scope.yml`

Answers whether a pull request can reach cargo, so a caller can pass `docs_only` to `rust-ci.yml` and skip the Rust
battery for a change that edits only documentation no Rust source reads. The rule lives in the caller's script, which
reads changed paths on stdin and prints the cargo inputs among them; empty output means documentation only. On any event
other than `pull_request` the answer is `rust=true`, and a caller keyed on `rust == 'false'` runs the full battery when
this job fails.

|                                 |                                                                       |
| ------------------------------- | --------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call`                                                       |
| **Inputs**                      | `script` (string, optional, default `scripts/cargo-inputs.sh`)        |
| **Outputs**                     | `rust`: `false` when every changed path is documentation, else `true` |
| **Check name**                  | `<caller job key> / Change scope`                                     |
| **Required caller permissions** | `contents: read`                                                      |

**Caller example:**

```yaml
jobs:
  scope:
    uses: brettdavies/.github/.github/workflows/rust-change-scope.yml@main
  ci:
    needs: scope
    if: ${{ !cancelled() }}
    uses: brettdavies/.github/.github/workflows/rust-ci.yml@main
    with:
      docs_only: ${{ needs.scope.outputs.rust == 'false' }}
```

### `rust-changelog-bump.yml`

Fails a pull request whose CLI surface grows while its `## Changelog` block names no minor-or-higher section, so an
addition cannot ship as a patch by being filed under `### Changed`. The caller's script decides what the surface is and
how the block is read; it is called as `<script> check <base-tree> <head-tree> <pr-body-file>` and exits 0 (pass), 1
(grew without the section), or 2 (unreadable tree). The base tree holds only `surface_paths`, taken from the PR's base.

|                                 |                                                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **Trigger**                     | `workflow_call`                                                                                                    |
| **Inputs**                      | `script` (string, default `scripts/check-surface-bump.sh`), `surface_paths` (string, default `completions schema`) |
| **Check name**                  | `<caller job key> / Surface growth needs a minor section`                                                          |
| **Required caller permissions** | `contents: read`                                                                                                   |

The verdict depends on the PR body, so the caller triggers on `edited` as well and owns the concurrency group. PRs to
`main` are release PRs and stay out.

**Caller example:**

```yaml
name: Changelog bump
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
    branches-ignore: [main]
permissions:
  contents: read
concurrency:
  group: changelog-bump-${{ github.ref }}
  cancel-in-progress: true
jobs:
  changelog-bump:
    uses: brettdavies/.github/.github/workflows/rust-changelog-bump.yml@main
```

### `rust-release.yml`

Full release pipeline: version check, audit, cross-platform build (7 targets: 5 hard-required, 2 linux-musl rows that
soft-fail by default), crates.io publish (Trusted Publishing OIDC), a published GitHub Release not yet marked latest
(notes extracted from the changelog the `changelog` input names, the repository root's `CHANGELOG.md` by default),
Homebrew dispatch.

The `tag` input names the release, and no step reads the run's ref. A caller dispatches the release onto `main` from the
tag push. A run restores caches from its own ref and the default branch, and a run on a tag saves into the tag's scope,
which no later run reads, so only a release on `main` saves caches the next release restores. In the dispatched run the
ref names `main`, so `validate-inputs` checks the tag before anything builds: it refuses a tag that does not match
`^v[0-9]+\.[0-9]+\.[0-9]+$`, a run on any ref but the default branch or the tag's own, a tag the repository does not
have, and a tag whose commit is not the commit the run builds, which is `main`'s head.
`scripts/check-release-tag-source.sh` fails this repo's lint run when the workflow reads `github.ref*`,
`github.event.ref`, or `GITHUB_REF*`, except the one line where `validate-inputs` reads the ref for that check, or when
its release step sets no `tag_name`, which defaults to the ref.

The build links the caches it restores into the binaries it attests, so whatever can write those caches is inside the
release's trust boundary. On the default branch that is every job that runs there, the release-matrix check included,
which saves under the release's keys on purpose; a caller treats any job on its default branch as able to change what a
release ships. On the tag's own ref it is the tagged tree's workflows. Any other branch's caches can be written by
whoever pushes the branch, so a release on one stops as `release-ref-untrusted`.

The builds and the SBOM start once the inputs pass, beside the version check and the audits. Signing waits for all of
them and publishing waits for signing, so a failed version check or blocking audit signs and publishes nothing; a failed
advisories audit does not block. A failed required build row cancels the others, and `gh run rerun <id> --failed` builds
them again. Before it publishes, `publish-crate` waits up to ten minutes for each workspace member the crate depends on
to reach crates.io at the declared bound, so a library tag pushed beside the binary's publishes first. The crate
publishes with `cargo publish --no-verify`, which compiles nothing. The caller requires `rust-ci.yml`'s `Package check`,
which runs `cargo publish --dry-run --workspace`, on pull requests into the branch it tags, so the compile the publish
skips has passed on that tree.

On a cross row, `cross` asks `cargo metadata` on the host before it starts its image, and builds on the host when that
call fails. The row runs `cargo fetch --locked` first, and fails whenever `cross` prints its fallback note, even when
the host build passes, since that build links against the runner's libraries rather than the image's.

The release is published rather than drafted because `brew pr-pull` finds it by tag through
`GET /repos/{owner}/{repo}/releases/tags/{tag}`, which returns no drafts, and on that 404 creates a second release for
the same tag. It stays unmarked as latest until the tap publishes the formula and dispatches
`rust-finalize-release.yml`: after the bottles upload for a source-built formula, so the repository's latest release
always has them, and at once for a prebuilt formula, which installs the release's own archives and has no bottles.

Both darwin rows build on `macos-15`, `x86_64-apple-darwin` cross-built beside the native arm64 row. Every shared
workflow takes its macOS runner label from `.github/runner-labels.env`; to move them all to a new image, change that
line and run `scripts/check-runner-labels.sh --fix`, and the lint job fails any label left behind.
`macos_deployment_target` (default `15.0`) is set as `MACOSX_DEPLOYMENT_TARGET` for the whole build, so the C code a
build script compiles declares the same oldest macOS as the Rust code. After each darwin build, a step reads the macOS
version the binary and every `.a` and `.o` under its build directory declare, and fails, naming each file, when one is
newer than the deployment target.

With `attest: true`, the archives the build jobs produced and `sha256sum.txt` are attested with build provenance, and a
CycloneDX SBOM of the binary is attested against the archives, before anything is published: a failed attestation
publishes no crate and no release. Once the release exists, every published file is verified against its attestation,
all at once, and the Homebrew dispatch goes out only when every check passes. The signing job runs no code from the
caller's repository; the SBOM is generated in a job of its own with a read-only token. This workflow is the signer, so a
release verifies with `gh attestation verify <archive> --repo <owner>/<repo> --signer-workflow
brettdavies/.github/.github/workflows/rust-release.yml`.

In a release dispatched onto `main`, the attestation's certificate names `refs/heads/main` as its source ref and
`workflow_dispatch` as its trigger. Its source digest is the tagged commit, which `validate-inputs` holds the run to.
`--signer-workflow` checks the signer, not the source ref, so the command above verifies a dispatched release and one
run on its tag alike.

A caller whose Homebrew formula installs the release's archives, rather than building the tagged source, needs
`attest: true`. `brettdavies/homebrew-tap` verifies each archive such a formula names against its attestation, with this
workflow as the signer, before it pins the checksum, and stops the formula bump when an archive has none.

|                                 |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Inputs**                      | `tag` (string, required; `v<major>.<minor>.<patch>`, an existing tag at the commit the run builds), `crate` (string, required), `bin` (string, required), `linux_musl_required` (bool, optional, default `false`), `linux_musl_verify_alpine` (bool, optional, default `false`), `changelog` (string, optional, default the repository root's `CHANGELOG.md`), `artifact_name` (string, optional, default the crate name), `attest` (bool, optional, default `false`; build-provenance and SBOM attestations for the release archives), `macos_deployment_target` (string, optional, default `15.0`; the oldest macOS the darwin binaries run on) |
| **Secrets**                     | `CI_RELEASE_TOKEN` (required, explicit, not inherited)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Required caller permissions** | `contents: write`, `id-token: write`; with `attest: true`, also `attestations: write`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |

**Caller example:** the tag push compiles nothing and dispatches the release onto `main`, which needs `actions: write`.
A caller that releases on the tag push itself passes `tag: ${{ github.ref_name }}`, and its run saves its caches where
no later release reads them. The `run-name` titles the dispatched run `Release <tag>` and the tag push's run
`Dispatch <tag>`, and the dispatch job's notice gives the command that lists the release run. When the dispatch job
fails, that command shows whether the release started before anyone dispatches it by hand.

```yaml
name: Release
run-name: ${{ github.event_name == 'push' && 'Dispatch' || 'Release' }} ${{ inputs.tag || github.ref_name }}
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+']
  workflow_dispatch:
    inputs:
      tag:
        description: 'The release tag, v<major>.<minor>.<patch>'
        required: true
        type: string
permissions:
  contents: write
  id-token: write
jobs:
  dispatch:
    if: github.event_name == 'push'
    runs-on: ubuntu-22.04
    permissions:
      actions: write
    steps:
      - name: Dispatch the release onto main
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.ref_name }}
        run: |
          gh workflow run release.yml --repo "$GITHUB_REPOSITORY" --ref main -f tag="$TAG"
          echo "::notice title=release-dispatched::Release ${TAG} runs on main: gh run list --repo ${GITHUB_REPOSITORY} --workflow release.yml --event workflow_dispatch --limit 1 --json displayTitle,status,url"
  pipeline:
    if: github.event_name == 'workflow_dispatch'
    uses: brettdavies/.github/.github/workflows/rust-release.yml@main
    with:
      tag: ${{ inputs.tag }}
      crate: bird
      bin: bird
    secrets:
      CI_RELEASE_TOKEN: ${{ secrets.CI_RELEASE_TOKEN }}
```

#### Migrating a caller

A caller that passes no `tag` fails at startup, before any job runs, so nothing builds or publishes. To move one over:

1. Pass the tag. `tag: ${{ inputs.tag || github.ref_name }}` serves a caller that releases on its tag push and one that
   dispatches the release, as the example above does.
2. Require `rust-ci.yml`'s `Package check` on pull requests into the branch you tag. `publish-crate` compiles nothing, so
   without that check a crate that does not build from its package can publish.
3. Merge the caller change before pushing the next `v*` tag. A tag runs the caller at its own commit.

A tag pushed before the change merged cannot be released as it stands. A dispatch onto `main` refuses it as
`release-tag-moved`, because `main` carries the change and the tag does not, and a dispatch onto the tag runs a caller
that takes no `workflow_dispatch`. Nothing was published, so move the tag onto the merged commit,
`git tag -fa vX.Y.Z -m vX.Y.Z <commit> && git push --force origin vX.Y.Z`, or release the next patch.

#### When a release stops

Each refusal is an error annotation titled with its code. The annotation names the values that caused it, says what was
built or published, and gives the command that recovers, with the run's id, repository, and caller filled in; a
command that still holds a `<placeholder>` is one to finish first. `scripts/check-release-error-docs.sh` fails this
repo's lint run when a coded annotation links no heading below, or a heading this README lacks.

##### `release-tag-invalid`

The `tag` input is empty, or does not match `^v[0-9]+\.[0-9]+\.[0-9]+$`: a branch name, a commit id, a tag without its
`v`, or a library's `<crate>-v<version>` tag, which its `rust-lib-release.yml` caller releases. Nothing was built or
published. An empty tag means the caller passes none; see [Migrating a caller](#migrating-a-caller). Otherwise a tag push
may already have started the release, and the annotation's `gh run list` shows it. When none did, dispatch again with
the binary's tag, which the annotation fills in when the input names it, as `4.6.0` or `refs/tags/v4.6.0` does.

##### `release-ref-untrusted`

The run is on a ref other than the default branch or `refs/tags/<tag>`, such as a feature branch whose head is the tag's
commit. Nothing was built or published. A run restores its own ref's caches, and anyone who pushes a branch can write
that branch's, so a release from it could ship and attest code the tag does not carry. Dispatch onto the default branch
once its head is the tag's commit, or onto the tag's own ref; the annotation gives both commands.

##### `release-tag-missing`

The repository has no tag of that name, or the tag names something other than a commit. Nothing was built or published.
Push the tag on the commit to release. In a caller that dispatches the release from its tag push, as the example above
does, that push starts the release, and dispatching by hand as well would start a second one. A tag that names a tree or
a blob moves onto the commit with `git tag -fa`, pushed with `--force`.

##### `release-tag-unreadable`

GitHub's API did not answer a read of the tag, of the tag object an annotated tag names, or of the comparison between
the tag's commit and the run's. Nothing was built or published. A 403 means the caller's job grants no `contents: read`;
for another status, `gh run rerun <id>` runs the check again.

##### `release-tag-moved`

The tag's commit is not the commit the run builds, and the run's commit descends from it: the branch the release was
dispatched onto moved past the tag after it was pushed. Nothing was built or published.
`gh workflow run <caller> --ref <tag> -f tag=<tag>` releases from the tag's own ref, which builds the tagged commit and
saves no cache a later release restores. That dispatch needs the caller at the tag's commit to take `workflow_dispatch`;
a tag pushed before its caller did is covered under [Migrating a caller](#migrating-a-caller).

##### `release-tag-off-branch`

The tag's commit is not in the history of the commit the run builds: the tag was cut on another branch, or on a local
commit the branch never received. Nothing was built or published. The annotation gives no command, because releasing the
tag as it stands would publish a commit the branch does not carry. A person decides which commit is the release: move
the tag onto the branch, or merge the tag's commit into it, then push the tag again.

##### `release-version-mismatch`

The version in the tag is not the one the crate's `Cargo.toml` declares at the tagged commit, most often a version bump
left out of the release. Nothing is signed or published, but the builds started beside the check and run to the end;
`gh run cancel <id>` stops them. Then bump the version and tag the commit that carries it, or move the tag onto a commit
whose version matches.

##### `cross-host-fallback`

`cross` fell back to building a row on the host; the annotation quotes the warning it printed first, which is the cause.
Nothing was published. `gh run rerun <id> --failed` builds that row again, with the rows fail-fast cancelled, on the
version of this workflow the first attempt ran. When the fix is a change to this repository, `gh run rerun <id>` runs
every job on the current version, which is safe because nothing was published. When the row fails again with the same
warning, the cause is the runner or the image, not a passing fault: the caller's `rust-release-matrix-check.yml` caller
reproduces it outside a release. A matrix check that fails the same way goes to an issue on `brettdavies/.github`
quoting the warning.

##### `library-wait-timeout`

A workspace member the crate depends on was not on crates.io at its bound ten minutes after `publish-crate` started,
because the library's own release is still running, failed, or was never tagged. Nothing was published, and the builds
and attestations are kept. The annotation names the library's tag, `<crate>-v<version>`, with the `gh run list` that
shows its release run, and the step prints cargo's last answer for each library, which tells an index or network
failure apart from a version not yet published. A tag with no run was never pushed: push it on the release's commit.
Once the library's release run is green, `gh run rerun <id> --failed` runs `publish-crate` and the jobs after it.

##### `attestation-verify-failed`

A published file did not verify against the attestation `attest` made for it. It is the one refusal that comes after
publishing: the crate is on crates.io and the GitHub Release exists, but the Homebrew dispatch did not go out, so the
release is not marked latest. Each failed check's output is in its own log group. `gh run rerun <id> --failed` runs the
checks and the dispatch again, which clears an outage of GitHub's attestation API. A second failure means a published
file is not the one that was signed: dispatch nothing to Homebrew by hand, and escalate.

### `rust-release-matrix-check.yml`

Builds the seven targets `rust-release.yml` builds, and releases nothing. The release build runs only once its tag exists,
so without this a dependency that breaks a cross-compiled target is found while cutting the release, after the tag exists.
A caller runs it when its dependency graph or toolchain pin changes and on every release branch.

Every row is hard-fail, including the two linux-musl rows the release soft-fails by default. For a caller whose release
passes `linux_musl_required: true`, a red row here means the release would fail on the same row.

The matrix holds the same rows as the release build's, and the same steps that install and run `cross`, build, and
check the deployment target on the darwin rows. `scripts/check-release-matrix-parity.sh` compares the rows by target,
runner, and cross flag, those steps line by line, and the two `Cache dependencies` steps' `key` and `env-vars`. It fails
this repo's lint run when they differ, or when either build job runs the deployment-target check before `Build release`.

The build cache takes the release's key, so a run on `main` restores the release's caches, which keeps them from
expiring, and rebuilds and saves them when they have. Only a run on `main` saves, and a failed row saves nothing. A
caller that releases from `main` runs the check there on a weekly `schedule`, which covers GitHub's seven-day expiry. It
does not cover eviction: once a repository's caches pass its 10 GB limit, GitHub deletes the least recently used first,
and a release's caches touched once a week are among them. A caller keeps them by pruning the caches its other refs no
longer use.

|                                 |                                                                                              |
| ------------------------------- | -------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call`                                                                              |
| **Inputs**                      | `macos_deployment_target` (string, optional, default `15.0`), as `rust-release.yml` takes it |
| **Secrets**                     | None                                                                                         |
| **Required caller permissions** | `contents: read`                                                                             |

Triggers, path filters, and the concurrency group belong to the caller, because which paths can break a build differs
per repo.

**Caller example:**

```yaml
name: Release matrix check
on:
  workflow_dispatch:
  schedule:
    - cron: '0 6 * * 1'
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

Release pipeline for a library crate in a workspace: version check against the crate's own `Cargo.toml`, audit,
`cargo publish -p <crate>` (Trusted Publishing OIDC), GitHub Release (notes extracted from the changelog beside the
crate, `make_latest: false` so the binary's release stays the repository's latest). No binaries, no Homebrew.

The publish runs with `--no-verify`, which compiles nothing. The caller requires `rust-ci.yml`'s `Package check`, which
runs `cargo publish --dry-run --workspace`, on pull requests into the branch it tags, so the compile the publish skips
has passed on that tree. A `dry_run` rehearsal keeps the compile.

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

Marks the tag's GitHub Release as the repository's latest once the tap has published the formula, publishing it first if
it is still a draft. The tap dispatches it after the bottles upload for a source-built formula; a prebuilt formula
installs the release's own archives and has no bottles to wait for.

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

### `pr-cache-cleanup.yml`

Deletes a pull request's Actions caches when it closes. A pull request's caches live under `refs/pull/<n>/merge`, which
only that pull request's runs can read, so once it closes nothing reads them again. They still count against the
repository's 10 GB limit, and GitHub evicts the least recently used entries first, so they outlast the `dev` and `main`
entries every new pull request restores from. The job runs `gh cache delete --all --ref refs/pull/<n>/merge` with the
job's token, so no third-party action is involved. A fork's pull request gets a read-only token, so the job skips it and
those entries leave by eviction.

|                                 |                                    |
| ------------------------------- | ---------------------------------- |
| **Trigger**                     | `workflow_call` (no inputs)        |
| **Check name**                  | `<caller job key> / Delete caches` |
| **Required caller permissions** | `actions: write`                   |

The workflow runs from the pull request's merge commit, so a caller that a pull request adds also runs when that pull
request closes.

**Caller example:**

```yaml
name: PR cache cleanup
on:
  pull_request:
    types: [closed]
permissions: {}
jobs:
  cleanup:
    permissions:
      actions: write
    uses: brettdavies/.github/.github/workflows/pr-cache-cleanup.yml@main
```

### `rust-cache-prune.yml`

Deletes a branch's superseded rust-cache entries after a warm CI run. A rust-cache key ends in a hash of the manifests,
the lockfile, and the toolchain files, so each change to one of those leaves the branch holding the previous
generation's caches beside the current ones. They count against the repository's 10 GB limit, and GitHub evicts the
least recently used entries first, which can take the warm entries pull requests restore from. The job groups the
branch's `v0-rust-*` entries by key minus the trailing hash and keeps one per group: the entry the run saved, else the
one it restored, else the most recently read. It deletes the rest with the job's token.

- **A re-run after the branch moved on prunes nothing.** A re-run builds its original commit, so its caches are an older
  generation's. The job compares the branch head with the run's commit first and exits 0 when they differ.
- **A saved entry outranks a later read.** A pull request based on an earlier commit can restore the previous generation
  after the run saved the current one, which would make the old entry the most recently read.
- **"Saved by the run" counts every attempt.** It means created after the run's `created_at`, which stays at the first
  attempt's time. `run_started_at` moves to each re-run's start, so re-running a failed job would rank the first
  attempt's saves as old.
- **A restore outranks a later read too.** A run that restores its exact key saves nothing, and the same stale pull
  request can read the old generation after that restore. Among the entries read since the run was created, the newest
  generation is kept. A reverted lockfile change is the one case this gets wrong: the run restores the older generation,
  a pull request that reads the newer one afterward makes the prune keep the newer one, and the next run on the branch
  rebuilds and saves its key again.
- **A delete that races an eviction passes.** When a delete fails, the job lists the branch's caches again: an entry
  GitHub evicted in the meantime is already gone, and any other failure fails the job.
- **Some entries stay until eviction.** A retired job's key is alone in its group, and so is the previous toolchain's,
  because a toolchain change moves the key's environment hash too.
- **Branch refs only.** On a pull request's or a tag's ref the job skips; pull requests' caches are
  `pr-cache-cleanup.yml`'s.

|                                 |                                              |
| ------------------------------- | -------------------------------------------- |
| **Trigger**                     | `workflow_call` (no inputs)                  |
| **Check name**                  | `<caller job key> / Prune superseded caches` |
| **Required caller permissions** | `actions: write`, `contents: read`           |

Call it from a job that `needs:` every job that saves a cache, and only after all of them finished: a job that failed or
was cancelled saved nothing, so its key's newest entry would still be the old generation. Runs on one branch must not
overlap, so the caller's workflow needs a concurrency group per ref, as in the example: an older run still going can
save its generation after this run was created, and this run would keep that entry over its own. Inside a called
workflow `github.ref`, `github.sha`, and `github.run_id` are the caller's, so the job prunes the branch the caller ran
on.

**Caller example:**

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  # ... the jobs that save caches, here warm and windows ...
  prune-caches:
    needs: [warm, windows]
    if: ${{ !cancelled() && github.event_name != 'pull_request' && !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') }}
    permissions:
      actions: write
      contents: read
    uses: brettdavies/.github/.github/workflows/rust-cache-prune.yml@main
```

### `search-presence.yml`

A search regression gate for a site repository, run after a deployment. It audits what the deployed site serves crawlers
with the search-presence skill (robots.txt, sitemaps, status codes, noindex, canonicals, on-page tags, headers, and host
redirects) and fails the job on any row at or above the config's `fail_on` level: `fail` by default, or `warn` to block
on warnings as well. The job summary gives the count of rows per status and each blocking row with its next step. An
audit that cannot finish fails the job too, with a line in the summary saying so.

The skill reads the site's `search-presence.toml` itself: it audits the config's `origin`, leaves out its `private`
hosts, reads its `sitemaps` when robots.txt declares none, and blocks at its `fail_on` level, so call the workflow once
the deployment is live at that origin. The audit sends the skill's own User-Agent and only reads the site.

The gate submits nothing, reads no search-engine data, and keeps no state between runs. Submission to Bing and IndexNow,
Google index state and the Request indexing queue, trends, and the per-site issue run locally once the deployment is
live; the search-presence skill's documentation covers that run.

A newer run for the same repository and config cancels one in progress, since the newer audit describes the live site. A
caller with several sites calls the workflow once per config.

|                                 |                                                                                                                                                                                    |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**                     | `workflow_call`                                                                                                                                                                    |
| **Inputs**                      | `config` (string, optional, default `search-presence.toml`), `skill_repository` (string, optional, default the skill's repository), `skill_ref` (string, optional, default `main`) |
| **Secrets**                     | `SEARCH_PRESENCE_SKILL_TOKEN` (required; fine-grained PAT with Contents: read on the skill's repository only)                                                                      |
| **Required caller permissions** | `contents: read`                                                                                                                                                                   |

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
    secrets:
      SEARCH_PRESENCE_SKILL_TOKEN: ${{ secrets.SEARCH_PRESENCE_SKILL_TOKEN }}
```

### `lint-basics.yml`

actionlint and markdownlint for any repository, with opt-in shellcheck, plan frontmatter, and workflow concurrency jobs.
A job that is off reports skipped, which a ruleset counts as passing.

|                                 |                              |
| ------------------------------- | ---------------------------- |
| **Trigger**                     | `workflow_call` (no secrets) |
| **Required caller permissions** | `contents: read`             |

| Input                  | Type    | Default                | Effect                                                                                                         |
| ---------------------- | ------- | ---------------------- | -------------------------------------------------------------------------------------------------------------- |
| `actionlint-version`   | string  | empty (`1.7.12`)       | The [`rhysd/actionlint`](#actionlint) release, as `X.Y.Z`; empty selects the release the action pins           |
| `actionlint-sha256`    | string  | empty                  | SHA-256 of that release's archive for the runner's architecture; needed only for a release with no pinned one  |
| `markdownlint`         | boolean | `true`                 | Runs `basics / markdownlint`                                                                                   |
| `markdownlint-globs`   | string  | `**/*.md`              | Glob patterns passed to markdownlint-cli2                                                                      |
| `shellcheck`           | boolean | `false`                | Runs `basics / shellcheck`                                                                                     |
| `shellcheck-files`     | string  | `*.sh scripts/hooks/*` | Whitespace-separated git pathspecs; only tracked files are checked                                             |
| `shellcheck-severity`  | string  | `warning`              | Minimum severity that fails the job: `error`, `warning`, `info`, or `style`                                    |
| `plans`                | boolean | `false`                | Runs `basics / plans`, the [plan frontmatter](#plan-frontmatter) check                                         |
| `plans-globs`          | string  | `docs/plans/*.md`      | Whitespace-separated glob patterns from the repository root; `**` matches any depth; each must match a file    |
| `workflow-concurrency` | boolean | `false`                | Runs `basics / Workflow concurrency`: `scripts/check-workflow-concurrency.sh`, vendored from github-repo-setup |
| `runs-on`              | string  | `ubuntu-latest`        | Runner label for every job                                                                                     |

`basics / actionlint` always runs. The check names assume a `basics:` caller job.

**Caller example:**

```yaml
name: Lint
on:
  pull_request:
permissions:
  contents: read
jobs:
  basics:
    uses: brettdavies/.github/.github/workflows/lint-basics.yml@main
    with:
      shellcheck: true
      plans: true
      workflow-concurrency: true
```

#### actionlint

The `actionlint` job runs the `actions/actionlint` composite action. It downloads upstream
[`rhysd/actionlint`](https://github.com/rhysd/actionlint) and shellcheck 0.11.0, checks each archive against a SHA-256
before unpacking it, and lints every workflow in the repository, reading `.github/actionlint.yaml` when there is one.

| Finding                          | Annotation | Job    |
| -------------------------------- | ---------- | ------ |
| shellcheck `info`                | notice     | passes |
| shellcheck `warning`             | warning    | passes |
| shellcheck `style` or `error`    | error      | fails  |
| anything else actionlint reports | error      | fails  |

Every workflow is reported, whether or not the pull request touches it. GitHub shows at most 10 annotations of one level
per step, so more than 10 failing findings lead with an annotation that gives the count; the job log holds every
finding. pyflakes does not run, so a `shell: python` step gets no Python lint. The job runs on Linux x86_64 and arm64
runners.

**Matching local hooks.** A repository that keeps its tool versions in a file passes the one it reads. `with:` cannot
read a file, so a job reads it first:

```yaml
jobs:
  tools:
    runs-on: ubuntu-latest
    outputs:
      actionlint: ${{ steps.read.outputs.actionlint }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - id: read
        run: |
          version=$(bash scripts/tool-version.sh actionlint)
          echo "actionlint=$version" >> "$GITHUB_OUTPUT"
  basics:
    needs: tools
    uses: brettdavies/.github/.github/workflows/lint-basics.yml@main
    with:
      actionlint-version: ${{ needs.tools.outputs.actionlint }}
```

**A release with no pinned checksum.** The job fails before downloading anything unless the caller supplies the checksum
for its runner's architecture. GitHub records each asset's digest when it is uploaded, and the input takes the
`sha256:<hex>` value this prints as it stands. For a release with no recorded digest the command prints nothing, and the
checksum comes from `sha256sum` over an archive you have checked.

```bash
gh release view v1.7.11 -R rhysd/actionlint --json assets \
  --jq '.assets[] | select(.name == "actionlint_1.7.11_linux_amd64.tar.gz") | .digest'
```

```yaml
with:
  actionlint-version: '1.7.11'
  actionlint-sha256: '900919a84f2229bac68ca9cd4103ea297abc35e9689ebb842c6e34a3d1b01b0a'
```

To pin a release for every caller, add its digests to `known_actionlint_sha256` in
`actions/actionlint/install-actionlint.sh`, and raise `default_version` there and the default in the input table above
when it should become the default. A supplied checksum that disagrees with a pinned one fails the job.

**Syntax newer than the release.** actionlint reports what its release does not know as an error. 1.7.12 rejects the
`ubuntu-26.04` label, `concurrency.queue`, and the `code-quality` permission scope, among others. List a label in the
caller's `.github/actionlint.yaml`, and ignore the rest by message:

```yaml
self-hosted-runner:
  labels:
    - ubuntu-26.04
paths:
  .github/workflows/deploy.yml:
    ignore:
      - unexpected key "queue"
```

**A hang.** actionlint 1.7.10 to 1.7.12 are known to hang on a `run:` block bigger than the runner's pipe buffer, 64 KiB
on hosted runners ([rhysd/actionlint#650](https://github.com/rhysd/actionlint/issues/650)). The job fails after 300
seconds and names the cause; moving that block into a script clears it.

#### Plan frontmatter

The `plans` job runs the `actions/plan-frontmatter` composite action over every file `plans-globs` matches. Each plan
opens with YAML frontmatter, the lines between a `---` on line 1 and the next `---` line, and carries a `status:` from a
closed set plus the keys that status requires:

| `status`     | Meaning                                                | Required keys                     |
| ------------ | ------------------------------------------------------ | --------------------------------- |
| `proposed`   | Not approved, or not started                           | none                              |
| `active`     | Some units merged or in open PRs                       | none                              |
| `blocked`    | Waiting on something named                             | `blocked_on`                      |
| `merged`     | Every unit on the integration branch, not yet released | `prs`, `completed`                |
| `released`   | Shipped in a release or a production deploy            | `prs`, `completed`, `released_in` |
| `done`       | A spike or process plan that ships nothing             | `completed`                       |
| `superseded` | Replaced by another plan                               | `superseded_by`                   |
| `dropped`    | Abandoned                                              | `dropped_reason`                  |

| Key              | Format                                                                                                                     | Allowed on                   |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| `prs`            | A non-empty YAML list of quoted PR refs, each `#N` or `owner/repo#N`: `prs: ["#149", "brettdavies/agentnative-site#40"]`   | every status                 |
| `completed`      | A real calendar date, `YYYY-MM-DD`                                                                                         | `merged`, `released`, `done` |
| `released_in`    | A release tag `vX.Y.Z` (an optional `-pre` or `+build` suffix), a quoted release PR `"#N"`, or the 40-character commit SHA | `released`                   |
| `blocked_on`     | Non-empty text naming what the plan waits on                                                                               | `blocked`                    |
| `superseded_by`  | A plan path, or `owner/repo:path` for a plan in another repository                                                         | `superseded`                 |
| `dropped_reason` | Non-empty text saying why the plan was abandoned                                                                           | `dropped`                    |

An unquoted `#` starts a YAML comment, so PR refs are always quoted: `prs: [#149]` does not parse, and `prs: #149` reads
as no value. A key on a status that does not own it fails, such as `completed` on an `active` plan. Every other key
passes unread (`title`, `type`, `date`, `origin`, `topic`, `deepened`, `artifact_contract`, and so on). A file with no
frontmatter, frontmatter that is not valid YAML, and a repeated key fail too. Each problem is an error annotation on its
file and line, worded as the fix, and the job fails on any.

```yaml
---
title: "feat: score every requirement row"
status: released
prs: ["#149", "#152"]
completed: 2026-10-20
released_in: v0.7.0
---
```

The checker is Python 3 standard library and parses the frontmatter with mikefarah yq v4 (`yq -o=json`), which the
GitHub-hosted Ubuntu and macOS images ship. On a runner without it, the action downloads a pinned yq release and checks
its sha256 first. To run the check locally from a plan repository, with mikefarah yq v4 on `PATH`:

```bash
python3 <path-to-this-repo>/actions/plan-frontmatter/check.py 'docs/plans/*.md'
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
- `search-presence.yml` refuses a `config` path outside the repository and hands the skill the config by path, so no
  config value reaches a shell
- The `plan-frontmatter` action downloads yq only as a pinned release whose sha256 matches before it runs
- The `actionlint` action unpacks actionlint and shellcheck only after each archive matches a sha256 that did not come
  from the same download, and fails before downloading a release with no known checksum
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

The Homebrew dispatch names the formula after the crate: `rust-release.yml` sends `client_payload[formula]` as the
`crate` input, so `formula name == crate name`. The repository travels separately as `client_payload[repo]`, and
`homebrew-tap/publish.yml` reads the owner and repository from the formula's `url`, so the repository name may differ. A
tool whose formula is named differently from its crate needs an optional `formula` input on `rust-release.yml`.

## Local hooks

`scripts/hooks/` carries `pre-commit` (actionlint + markdownlint on staged files) and `pre-push` (actionlint,
markdownlint, shellcheck, and the plan-frontmatter and actionlint action tests across the repo), mirroring the CI lint
gate locally. Activate per clone:

```bash
git config core.hooksPath scripts/hooks
```

Each check no-ops with a notice when its tool is not installed.
