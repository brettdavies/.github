#!/usr/bin/env bash
# Release-matrix parity guard.
#
# Fails when the build matrix of `rust-release-matrix-check.yml` and the build
# matrix of `rust-release.yml` hold different rows, comparing each row's target,
# runner, and cross flag, or when their `Install NASM` or `Check the macOS
# deployment target` steps differ in any line.
#
# Why the rule exists: the check workflow builds, before a tag, what the release
# builds after one. A row the release gains and the check lacks is a target no
# release branch ever builds, and its first failure is a failed release. No run
# fails on a missing row, so nothing else would report the gap. The same holds
# for both steps: a check that provisions a row differently, or reads objects
# differently, from the release passes a build the release then fails, or the
# reverse.
#
# Exit codes: 0 = both matrices hold the same rows and the same steps, 1 = they
# differ (the difference is printed), 2 = a matrix or a step could not be read.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

release=.github/workflows/rust-release.yml
check=.github/workflows/rust-release-matrix-check.yml

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
    injob && /^  [A-Za-z_-]+:/ { flush(); injob = 0 }
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

for wf in "$release" "$check"; do
  if [ ! -f "$wf" ]; then
    echo "FAIL: $wf does not exist" >&2
    exit 2
  fi
done

release_rows=$(rows "$release")
check_rows=$(rows "$check")

require_rows() {
  if [ -z "$2" ]; then
    echo "FAIL: no build matrix rows read from $1" >&2
    exit 2
  fi
}
require_rows "$release" "$release_rows"
require_rows "$check" "$check_rows"

# A step's lines, from its `- name:` line to the line before the next step,
# comment, or job.
step_text() {
  awk -v name="      - name: $2" '
    $0 == name { on = 1; print; next }
    on && (/^      - / || /^  [A-Za-z_-]+:/ || /^      #/) { exit }
    on { print }
  ' "$1"
}

steps_differ=false
for step in "Install NASM" "Check the macOS deployment target"; do
  for wf in "$release" "$check"; do
    if [ -z "$(step_text "$wf" "$step")" ]; then
      echo "FAIL: no \`$step\` step in $wf" >&2
      exit 2
    fi
  done
  release_step=$(step_text "$release" "$step")
  check_step=$(step_text "$check" "$step")
  if [ "$release_step" != "$check_step" ]; then
    steps_differ=true
    echo "FAIL: the \`$step\` steps differ (< $release, > $check)" >&2
    diff <(printf '%s\n' "$release_step") <(printf '%s\n' "$check_step") >&2 || true
  fi
done

if [ "$release_rows" = "$check_rows" ]; then
  if [ "$steps_differ" = false ]; then
    echo "OK: $check builds the same $(printf '%s\n' "$check_rows" | wc -l | tr -d ' ') rows as $release, with the same NASM and deployment-target steps"
    exit 0
  fi
  echo "" >&2
  echo "Give both workflows the same step text." >&2
  exit 1
fi

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
cat >&2 <<'EOF'

Give both workflows the same `matrix.include` rows. A target the release builds
has to build on a release branch first.
EOF
exit 1
