#!/usr/bin/env bash
# Release-matrix parity guard.
#
# Fails when the build job of `rust-release-matrix-check.yml` and the build job
# of `rust-release.yml` differ in what decides a build's outcome: the matrix
# rows (each row's target, runner, and cross flag), any line of the steps both
# jobs share (installing and running `cross`, the build, and the
# deployment-target check), or the `key` and `env-vars` of their
# `Cache dependencies` steps. It also fails when either job runs
# `Check the macOS deployment target` before `Build release`.
#
# Why the rule exists: the check workflow builds, before a tag, what the release
# builds after one. A row the release gains and the check lacks is a target no
# release branch ever builds, and its first failure is a failed release. No run
# fails on a missing row, so nothing else would report the gap. The same holds
# for a shared step: a check that builds or reads objects differently from the
# release passes a build the release then fails, or the reverse. A check whose
# cache key differs saves caches the release never restores, so its runs leave
# the release cold.
#
# Exit codes: 0 = both jobs hold the same rows, steps, and cache key, with the
# deployment-target check after the build in both, 1 = they differ or that step
# runs before the build (each difference is printed), 2 = a matrix or a step
# could not be read.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

release=.github/workflows/rust-release.yml
check=.github/workflows/rust-release-matrix-check.yml

shared_steps=(
  "Install cargo-binstall"
  "Install cross"
  "Fetch crates for cross"
  "Build release"
  "Check the macOS deployment target"
)

# One line per row of the `build` job's `matrix.include`: target, runner, and
# whether the row cross-compiles. A row opens at its `- os:` line and closes at
# the next line indented no deeper, so a `target:` key elsewhere in the job is
# never read as a row.
rows() {
  awk '
    function flush() {
      if (open && target != "") print target, os, cross
      open = 0
    }
    /^  build:/ { injob = 1; next }
    injob && /^  [^ #]/ { flush(); injob = 0 }
    !injob { next }
    /^[[:space:]]*(#|$)/ { next }
    { indent = match($0, /[^ ]/) - 1 }
    /^[[:space:]]+- os:/ {
      flush()
      open = 1; rowindent = indent; os = $3; target = ""; cross = "false"
      next
    }
    open && indent <= rowindent { flush(); next }
    open && /^[[:space:]]+target:/ { target = $2; next }
    open && /^[[:space:]]+cross:/ { cross = $2; next }
    END { flush() }
  ' "$1" | sort
}

# The named step's lines in the `build` job, from its `- name:` line to the
# line before the next step, comment, or job, without trailing blank lines. A
# comment above a step is not part of it, so the two jobs may explain a step
# differently.
step_text() {
  awk -v want="      - name: $2" '
    /^  build:/ { injob = 1; next }
    injob && /^  [^ #]/ { exit }
    injob && $0 == want { on = 1; print; next }
    on && (/^      - / || /^      #/) { exit }
    on && /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
    on { printf "%s", blanks; blanks = ""; print }
  ' "$1"
}

# The file line of the step's `- name:` line in the `build` job.
step_line() {
  awk -v want="      - name: $2" '
    /^  build:/ { injob = 1; next }
    injob && /^  [^ #]/ { exit }
    injob && $0 == want { print NR; exit }
  ' "$1"
}

# How many times the `build` job names the step.
step_count() {
  awk -v want="      - name: $2" '
    /^  build:/ { injob = 1; next }
    injob && /^  [^ #]/ { exit }
    injob && $0 == want { n++ }
    END { print n + 0 }
  ' "$1"
}

# Which side of `Build release` the `build` job runs the deployment-target
# check on. Before the build the step reads only what the cache restored and
# never the binary this run builds: with a cold cache it fails every darwin
# row, and with a warm one it can pass on objects this run did not make.
minos_side() {
  awk '
    /^  build:/ { injob = 1; next }
    injob && /^  [^ #]/ { exit }
    injob && /^      - name: Build release$/ { build = NR }
    injob && /^      - name: Check the macOS deployment target$/ { minos = NR }
    END { print (minos > build ? "after" : "before") }
  ' "$1"
}

for wf in "$release" "$check"; do
  if [ ! -f "$wf" ]; then
    echo "FAIL: $wf does not exist" >&2
    exit 2
  fi
done

release_rows=$(rows "$release")
check_rows=$(rows "$check")
for wf in "$release" "$check"; do
  if [ -z "$(rows "$wf")" ]; then
    echo "FAIL: no build matrix rows read from $wf" >&2
    exit 2
  fi
  for name in "${shared_steps[@]}" "Cache dependencies"; do
    case "$(step_count "$wf" "$name")" in
      1) ;;
      0)
        echo "FAIL: no \`$name\` step in the build job of $wf" >&2
        exit 2
        ;;
      *)
        echo "FAIL: the build job of $wf has more than one \`$name\` step, so the guard cannot tell which one runs" >&2
        exit 2
        ;;
    esac
  done
done

failures=0

if [ "$release_rows" != "$check_rows" ]; then
  failures=$((failures + 1))
  echo "FAIL: the build matrices differ (target, runner, cross)" >&2
  only_release=$(comm -23 <(printf '%s\n' "$release_rows") <(printf '%s\n' "$check_rows"))
  only_check=$(comm -13 <(printf '%s\n' "$release_rows") <(printf '%s\n' "$check_rows"))
  if [ -n "$only_release" ]; then
    echo "  only in $release:" >&2
    printf '%s\n' "$only_release" | sed 's/^/    /' >&2
  fi
  if [ -n "$only_check" ]; then
    echo "  only in $check:" >&2
    printf '%s\n' "$only_check" | sed 's/^/    /' >&2
  fi
  echo "  Give both workflows the same \`matrix.include\` rows. A target the release builds has to build on a release branch first." >&2
fi

for name in "${shared_steps[@]}"; do
  release_step=$(step_text "$release" "$name")
  check_step=$(step_text "$check" "$name")
  if [ "$release_step" != "$check_step" ]; then
    failures=$((failures + 1))
    echo "FAIL: the \`$name\` steps differ (< $release:$(step_line "$release" "$name"), > $check:$(step_line "$check" "$name"); diff lines count from each step's name line)" >&2
    diff <(printf '%s\n' "$release_step") <(printf '%s\n' "$check_step") >&2 || true
    echo "  Give both workflows the same step text." >&2
  fi
done

cache_key() {
  step_text "$1" "Cache dependencies" | grep -E '^[[:space:]]+(key|env-vars):' || true
}
release_key=$(cache_key "$release")
check_key=$(cache_key "$check")
if [ "$release_key" != "$check_key" ]; then
  failures=$((failures + 1))
  echo "FAIL: the \`Cache dependencies\` steps differ in key or env-vars (< $release, > $check)" >&2
  diff <(printf '%s\n' "$release_key") <(printf '%s\n' "$check_key") >&2 || true
  echo "  Give both steps the same key and env-vars, so the check's runs refresh the caches the release restores." >&2
fi

for wf in "$release" "$check"; do
  if [ "$(minos_side "$wf")" = before ]; then
    failures=$((failures + 1))
    echo "FAIL: $wf runs \`Check the macOS deployment target\` before \`Build release\`, so it never reads what this run builds" >&2
    echo "  Move the step after \`Build release\` in the build job." >&2
  fi
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "OK: $check builds the same $(printf '%s\n' "$check_rows" | wc -l | tr -d ' ') rows as $release, with the same ${#shared_steps[@]} shared steps and cache key"
