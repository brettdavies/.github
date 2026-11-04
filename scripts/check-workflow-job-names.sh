#!/usr/bin/env bash
# Skippable-job name guard.
#
# Fails when a job in `.github/workflows/` that can be skipped has a `name:`
# built from an expression. A job can be skipped when it has an `if:`, or a
# `needs:` whose job fails or is skipped.
#
# Why the rule exists: GitHub reports a skipped job under its raw `name:` text,
# without evaluating it. A job named `Doc build${{ inputs.suffix }}` that is
# skipped reports as exactly that string, so every check that skips is renamed,
# and a ruleset that requires `ci / Doc build` waits forever for a check that
# never reports under that name. No run fails; the pull request just never
# becomes mergeable. A matrix job keeps a literal name too: GitHub appends each
# cell's matrix values to it on its own.
#
# Exit codes: 0 = every skippable job has a literal name, 1 = one does not
# (each named), 2 = yq is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to read the workflows" >&2
  exit 2
fi

failures=0
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  offenders=$(yq '.jobs // {} | to_entries | .[]
    | select((.value.name // "" | tostring | test("\$\{\{")) and (.value.if != null or .value.needs != null))
    | .key + " (name: " + .value.name + ")"' "$wf")
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    echo "FAIL: $wf job $job can be skipped, and a skipped job reports under its raw name" >&2
    failures=$((failures + 1))
  done <<<"$offenders"
done

if [ "$failures" -gt 0 ]; then
  cat >&2 <<'EOF'

Give each job above a literal `name:`. A variant of a job that must report
under another name runs from a caller job of its own (`warm:` rather than
`ci:`), and a matrix job's literal name gets its cells' values appended.
EOF
  exit 1
fi

echo "OK: every job that can be skipped has a literal name"
