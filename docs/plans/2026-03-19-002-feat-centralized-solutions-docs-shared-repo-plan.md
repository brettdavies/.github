---
title: "Centralized Solutions Docs via Shared Private Repo"
type: feat
status: completed
date: 2026-03-19
---

# Centralized Solutions Docs via Shared Private Repo

## Overview

Consolidate `docs/solutions/` from three independent repos
(homebrew-tap, bird, xurl-rs) into a single private GitHub repo
(`brettdavies/solutions-docs`), cloned locally at
`~/dev/solutions-docs`, and symlinked into each consuming repo at
`docs/solutions/`. The symlink is gitignored — never committed.
This gives Claude Code's learnings-researcher agent access to all
22 institutional knowledge documents from any repo, with seamless
read-write editing.

## Problem Statement / Motivation

The compound engineering workflow produces `docs/solutions/` files
to prevent re-solving known problems. Currently these files are
siloed per repo:

| Repo | Files | Categories |
|---|---|---|
| homebrew-tap | 6 | workflow-issues, integration-issues |
| bird | 14 | architecture-patterns, build/perf/security |
| xurl-rs | 2 | rust-patterns, (1 uncategorized root) |
| **Total** | **22** | 6 distinct categories |

The learnings-researcher agent only searches `docs/solutions/` in
the current working directory. When working in homebrew-tap, the
agent cannot see bird's 14 solutions — even though many are
cross-cutting (release pipelines, PAT consolidation, CI patterns).
Cross-repo references exist only in MEMORY.md files and markdown
links, which the agent cannot follow.

**This fragmentation means the $100 Rule is undermined:** solutions
are compounded but not discoverable from all repos.

## Proposed Solution

**Approach: Shared Clone + Gitignored Symlink** (evaluated against
git submodules, committed symlinks, and git subtree — see
Alternatives Considered below).

```text
~/dev/solutions-docs/            <-- single private repo clone
  ├── architecture-patterns/
  ├── build-errors/
  ├── integration-issues/
  ├── performance-issues/
  ├── rust-patterns/
  ├── security-issues/
  └── workflow-issues/

~/dev/bird/docs/solutions       -> ~/dev/solutions-docs
~/dev/xurl-rs/docs/solutions    -> ~/dev/solutions-docs
~/dev/homebrew-tap/docs/solutions -> ~/dev/solutions-docs
```

How it works:

1. One `git clone` of `solutions-docs` at `~/dev/solutions-docs`
2. Each consuming repo adds `docs/solutions` to `.gitignore`
3. Each consuming repo creates symlink:
   `ln -s ~/dev/solutions-docs docs/solutions`
4. Reads, writes, and agent searches go through symlink
   transparently
5. Commits happen in `~/dev/solutions-docs` (a separate git repo)

## Technical Considerations

### Agent Commit Workflow (Critical)

When Claude Code's `/compound` skill writes to
`docs/solutions/some-file.md`, the write goes through the symlink
to `~/dev/solutions-docs`. But `git status` in the consuming repo
shows nothing (gitignored). The agent must be explicitly
instructed to commit in the target repo.

**Solution:** Add instructions to global `~/.claude/CLAUDE.md` and
each project's MEMORY.md:

```markdown
## Shared Solutions Repo

`docs/solutions/` is a symlink to `~/dev/solutions-docs`
(a separate git repo).
After writing to `docs/solutions/`, commit and push in
`~/dev/solutions-docs`:

cd ~/dev/solutions-docs && git add -A && git commit && git push
```

This is the lightest-touch option. No skill modification needed —
just agent awareness.

### Frontmatter Schema Normalization

The three repos use inconsistent frontmatter. The
learnings-researcher agent searches by `module:`, `problem_type:`,
`component:`, `title:`, `tags:`. Solutions missing these fields
are invisible to search.

**Solution:** During migration, normalize all 22 files to a
canonical schema:

| Field | Required | Notes |
|---|---|---|
| `title` | Yes | Human-readable title |
| `date` | Yes | YYYY-MM-DD |
| `problem_type` | Yes | Matches category dir (kebab-case) |
| `source_repo` | Yes | **New.** homebrew-tap, bird, xurl-rs |
| `severity` | Yes | low, medium, high, critical |
| `tags` | Yes | Array of searchable keywords |
| `symptoms` | No | What the problem looks like |
| `components` | No | Affected files/modules |
| `root_cause` | No | Why it happened |
| `resolution_type` | No | How it was fixed |

Rename non-standard fields: `category:` → `problem_type:`,
`affected_components:` → `components:`, add `module:` where
missing.

### Relative Path Breakage

Many solutions contain relative paths to files in their
originating repo (e.g., `../../plans/...`, `../../CLI_DESIGN.md`).
After migration, these paths break.

**Solution:** Rewrite repo-specific relative paths to absolute
GitHub URLs:

- `../../plans/some-plan.md` →
  `https://github.com/brettdavies/bird/blob/dev/docs/plans/some-plan.md`
- Inter-solution relative links (e.g., `../performance-issues/...`)
  remain valid within the shared repo.

### Guard Workflow Interaction

Current `guard-main-docs.yml` workflows check for
`docs/solutions/` paths in PRs to main. With gitignored symlinks,
solution files never appear in git diffs. The guard becomes a
no-op for solutions but continues to protect `docs/plans/` and
`docs/brainstorms/`.

No changes needed to guard workflows — this is a desirable
simplification.

### CI/CD Access

No current CI workflow reads `docs/solutions/` at runtime. If
needed in the future:

```yaml
- name: Clone shared solutions docs
  run: |
    git clone \
      https://x-access-token:${{ secrets.CI_RELEASE_TOKEN }}@github.com/brettdavies/solutions-docs.git \
      docs/solutions
```

The existing `CI_RELEASE_TOKEN` PAT must be scoped to include the
new repo.

## Alternative Approaches Considered

### Git Submodules — Rejected

- Pins to a specific commit (violates "always latest" requirement)
- Two-commit dance for every edit (commit in submodule, then
  commit pointer in parent)
- Detached HEAD footgun
- `git clone` does not include submodule content by default
  (must use `--recurse-submodules`)
- Higher cognitive overhead for a solo developer

### Git Subtree — Rejected

- Requires explicit `git subtree pull` in every consuming repo
  after any change (violates "always latest")
- `git subtree push` walks entire history, gets slower over time
- `--squash` vs full-history is a lose-lose for documentation
- Manual fan-out synchronization problem across 3+ repos

### Committed Symlinks — Rejected

- Symlink target path is machine-specific — breaks on CI runners
- `git clone` creates a broken symlink pointing to
  `~/dev/solutions-docs` which does not exist
- No advantage over gitignored symlink approach
- CI runners cannot resolve the symlink at all

## Acceptance Criteria

### Phase 1: Create Shared Repo and Migrate Content

- [x] Create private repo `brettdavies/solutions-docs` on GitHub
- [x] Move all 42 solution files into unified category structure
      (expanded from 3 to 7 repos)
- [x] Move xurl-rs `branch-reset-file-inventory.md` into
      `workflow-issues/`
- [ ] Normalize frontmatter schemas across all 42 files
      (deferred — minimal migration chosen)
- [x] Add `source_repo` field to all migrated files
- [x] Rewrite broken relative paths to absolute GitHub URLs
- [x] Push initial content to `solutions-docs` main branch

### Phase 2: Configure Consuming Repos

- [x] Add `docs/solutions` (no trailing slash) to `.gitignore`
      in all 7 repos
- [x] Remove original `docs/solutions/` directories from each
      repo's dev branch
- [x] Create symlinks locally:
      `ln -s ~/dev/solutions-docs docs/solutions`
- [x] Verify all 7 repos see 42 files through symlink

### Phase 3: Update Agent Configuration

- [x] Add shared solutions repo instructions to
      `~/.claude/CLAUDE.md`
- [x] Update MEMORY.md for each project (replace absolute
      cross-repo solution paths with `docs/solutions/` relative
      paths)
- [ ] Verify `/compound` workflow writes to symlink target and
      agent commits in `solutions-docs`

### Phase 4: Scope PAT and Verify

- [x] Ensure `CI_RELEASE_TOKEN` PAT includes `solutions-docs`
      repo access (confirmed: "All repositories" scope)
- [x] Verify CI workflows still pass (guard-main-docs is
      unaffected — docs/solutions files no longer in git diffs)

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Agent forgets to commit in solutions-docs | High | CLAUDE.md + MEMORY.md instructions |
| Stale local clone (forgot git pull) | Low | Acceptable for solo dev |
| Frontmatter normalization errors | Low | Review each file during migration |
| Future plans/brainstorms centralization | Medium | Out of scope; use absolute URLs now |

## Success Metrics

- learnings-researcher agent discovers cross-repo solutions
  (e.g., bird's release pipeline solution found when working
  in xurl-rs)
- `/compound` workflow successfully writes and commits solutions
  from any consuming repo
- Zero broken internal links between solutions in the shared repo
- New repo onboarding takes < 5 minutes (clone + symlink +
  gitignore)

## Out of Scope

- Centralizing `docs/plans/`, `docs/brainstorms/`, or
  `docs/reviews/` (defer until solutions centralization proves
  stable)
- Automated `git pull` mechanism for solutions-docs (manual pull
  is acceptable for solo developer)
- CI workflows that read solution content at runtime (no current
  need)

## Sources & References

### Internal References

- Release branch pattern:
  `docs/solutions/workflow-issues/release-branch-pattern-for-guarded-docs-20260317.md`
- PAT consolidation:
  `~/dev/bird/docs/solutions/architecture-patterns/github-pat-consolidation-across-repos-20260319.md`
- Guard workflow: `.github/workflows/guard-main-docs.yml`
  (all 3 repos)
- learnings-researcher agent:
  `~/.claude/plugins/cache/every-marketplace/compound-engineering/2.44.0/agents/research/learnings-researcher.md`

### External References

- [Git SCM Book: Submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules)
  (evaluated, rejected)
- [Atlassian: Git Subtree](https://www.atlassian.com/git/tutorials/git-subtree)
  (evaluated, rejected)
