#!/usr/bin/env bash
# rust-ci job-id guard.
#
# Fails when `rust-ci.yml`'s `jobs` input and its jobs disagree: an id in the
# `validate-inputs` job's KNOWN_JOBS list that names no job, a job missing from
# that list, or a job whose condition does not test `jobs` for its own id in
# the full form `(inputs.jobs == 'all' || contains(fromJSON(inputs.jobs), '<id>'))`.
#
# Why the rule exists: a caller passes `jobs` to choose which jobs run. A job
# that never reads it runs on every caller's narrowed list; a job missing from
# KNOWN_JOBS fails the `Inputs` job for every caller that names it; and an id
# left in the list after its job is renamed lets a caller's stale name pass
# validation while the job it meant skips, which a ruleset counts as success.
# No run fails on any of these until a caller trips it. A test without the
# `inputs.jobs == 'all'` half parses `all` as JSON, and the job errors for every
# caller that keeps the default.
#
# Exit codes: 0 = the list and the jobs agree, 1 = they differ (each named),
# 2 = the workflow or yq is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

wf=.github/workflows/rust-ci.yml
validator=validate-inputs

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to check $wf" >&2
  exit 2
fi
if [ ! -f "$wf" ]; then
  echo "FAIL: $wf does not exist" >&2
  exit 2
fi

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

jobs=$(yq '.jobs | keys | .[]' "$wf" | grep -vxF "$validator" | sort)
known=$(yq ".jobs.\"$validator\".env.KNOWN_JOBS" "$wf" | jq -r '.[]' | sort)

if [ -z "$known" ]; then
  echo "FAIL: no KNOWN_JOBS list read from the $validator job in $wf" >&2
  exit 2
fi

while IFS= read -r id; do
  fail "KNOWN_JOBS names '$id', which is not a job in $wf"
done < <(comm -13 <(printf '%s\n' "$jobs") <(printf '%s\n' "$known"))

while IFS= read -r id; do
  fail "job '$id' is missing from KNOWN_JOBS in the $validator job"
done < <(comm -23 <(printf '%s\n' "$jobs") <(printf '%s\n' "$known"))

# A matrix job carries its test in `env` (RUN_STEPS), every other job in `if`.
while IFS= read -r id; do
  gate="(inputs.jobs == 'all' || contains(fromJSON(inputs.jobs), '$id'))"
  # Captured before matching: `grep -q` exits at the first match, and under
  # pipefail the SIGPIPE that leaves yq would fail a job that passes.
  conditions=$(yq ".jobs.\"$id\" | (.if, .env) | .. | select(tag == \"!!str\")" "$wf")
  if ! grep -qF "$gate" <<<"$conditions"; then
    fail "job '$id' does not test the jobs input for its own id; add $gate to its if (or, in a matrix job, to RUN_STEPS)"
  fi
done <<<"$jobs"

if [ "$failures" -gt 0 ]; then
  echo "" >&2
  echo "Keep KNOWN_JOBS equal to the job ids under jobs: (all but $validator), and give each job the test above." >&2
  exit 1
fi

echo "OK: $(printf '%s\n' "$jobs" | wc -l | tr -d ' ') jobs in $wf read the jobs input for their own id, and KNOWN_JOBS lists each of them"
