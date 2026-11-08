#!/usr/bin/env bash
# Release-tag source guard.
#
# Fails when `rust-release.yml` reads the run's ref outside a comment
# (`github.ref`, `github.ref_name`, `github.event.ref`, `GITHUB_REF`,
# `GITHUB_REF_NAME`, or any other `github.ref*`, `github.event.ref*`, or
# `GITHUB_REF*` field), or when one of its `softprops/action-gh-release` steps
# sets no `tag_name`.
#
# Why the rule exists: a caller dispatches the release onto its default branch,
# so the build restores that branch's caches, and in that run the ref names the
# branch, not the tag. A step that read it would check, name, or download the
# release as `main`. The release action takes its tag from the ref unless
# `tag_name` is set, and no text names that read, so a release step without it
# would create a tag called `main`. The workflow takes the tag as its `tag`
# input, and every job reads it from `validate-inputs`, which checks it.
#
# Usage: check-release-tag-source.sh [workflow], by default
# .github/workflows/rust-release.yml.
#
# Exit codes: 0 = nothing reads the ref and every release step names its tag,
# 1 = something does not (each named with its line), 2 = the workflow or yq is
# missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

wf="${1:-.github/workflows/rust-release.yml}"

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to check $wf; install it with brew install yq, or see https://github.com/mikefarah/yq#install" >&2
  exit 2
fi
if [ ! -f "$wf" ]; then
  echo "FAIL: $wf does not exist" >&2
  exit 2
fi

failures=0

# The job a line sits in, by the last two-space-indented key above it.
job_at() {
  awk -v want="$1" 'NR > want { exit } /^  [a-z][a-z0-9_-]*:$/ { job = substr($1, 1, length($1) - 1) } END { print job }' "$wf"
}

refs=$(grep -nE 'github\.(event\.)?ref|GITHUB_REF' "$wf" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  line="${hit%%:*}"
  hint=""
  if [ "$(job_at "$line")" = validate-inputs ]; then
    hint=" (validate-inputs checks the tag, so it reads inputs.tag)"
  fi
  echo "FAIL: $wf:${line} reads the run's ref, which names the branch in a dispatched run${hint}: ${hit#*:}" >&2
  failures=$((failures + 1))
done <<<"$refs"

untagged=$(yq '.jobs[].steps[]? | select((.uses // "") | test("^softprops/action-gh-release@")) | select((.with.tag_name // "") == "") | (.name // .uses) + "|" + (line | tostring)' "$wf")
while IFS='|' read -r step line; do
  [ -n "$step" ] || continue
  echo "FAIL: $wf:$line step '$step' sets no tag_name, so the release takes its tag from the run's ref" >&2
  failures=$((failures + 1))
done <<<"$untagged"

if [ "$failures" -gt 0 ]; then
  echo "" >&2
  echo "Read the tag from needs.validate-inputs.outputs.tag (through env: in a run step), and set tag_name on every release step." >&2
  exit 1
fi

echo "OK: $wf reads no ref, and every release step names its tag"
