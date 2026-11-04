#!/usr/bin/env bash
# Runner-label guard.
#
# Fails when a macOS runner label in `.github/workflows/` or `README.md`
# differs from `MACOS_RUNNER` in `.github/runner-labels.env`.
#
# Why the rule exists: GitHub Actions has no variable a reusable workflow can
# share across files for `runs-on`. `vars` resolves in the caller's repository,
# and `env` is not available to `runs-on`. So each shared workflow names its
# macOS label itself, and a label that moves in one file and not another
# splits CI, the release, and its pre-tag check across different macOS images.
# One file holds the label; this guard holds every occurrence to it.
#
# Usage: scripts/check-runner-labels.sh [--fix]
#   --fix rewrites every macOS label to the value in the source file.
#
# Exit codes: 0 = every label matches, 1 = one differs (each named),
# 2 = the source file is missing or holds no valid label.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

source_file=.github/runner-labels.env
macos=$(sed -n 's/^MACOS_RUNNER=//p' "$source_file" 2>/dev/null || true)
if [[ ! $macos =~ ^macos-[0-9a-z.-]+$ ]]; then
  echo "FAIL: $source_file must hold one MACOS_RUNNER=macos-<version> line" >&2
  exit 2
fi

# A hosted macOS label: `macos-latest`, or a version with an optional size or
# architecture suffix. Build artifacts named `macos-objects.txt` and the like
# have no digit after the dash, so they never match.
label='macos-(latest|[0-9]+(\.[0-9]+)?(-(intel|large|xlarge))?)'
files=(.github/workflows/*.yml README.md)

if [ "${1:-}" = "--fix" ]; then
  perl -pi -e "s/\\b${label}\\b/${macos}/g" "${files[@]}"
fi

failures=0
while IFS=: read -r file line found; do
  if [ "$found" != "$macos" ]; then
    echo "FAIL: $file:$line names $found; $source_file sets $macos (run scripts/check-runner-labels.sh --fix)"
    failures=$((failures + 1))
  fi
done < <(grep -noE "$label" "${files[@]}" || true)

if [ "$failures" -gt 0 ]; then
  exit 1
fi
echo "OK: every macOS runner label is $macos, from $source_file"
