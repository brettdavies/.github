#!/usr/bin/env bash
# Error-docs guard.
#
# Fails when a coded error annotation in `.github/workflows/`
# (`::error title=<code>::` with a kebab-case code) does not link `#<code>`,
# or when a workflow links a README.md heading, as `${DOCS}#<anchor>` with
# DOCS set to README.md or as `README.md#<anchor>`, that README.md does not
# have.
#
# Why the rule exists: an annotation's link is how an operator or agent gets
# from a failed run to its recovery. GitHub opens a link whose heading is gone
# at the top of the page, so a renamed heading breaks the link with no error,
# and every past run's annotation links README.md on main, where the heading
# has to keep its name.
#
# Usage: scripts/check-release-error-docs.sh
#
# Exit codes: 0 = every coded annotation links a heading README.md has,
# 1 = one does not (each named with its line), 2 = a workflow sets DOCS to a
# page other than README.md.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readme_url=https://github.com/brettdavies/.github/blob/main/README.md

other_docs=$(grep -nE '^[[:space:]]+DOCS:' .github/workflows/*.yml | grep -vF "DOCS: ${readme_url}" | sed 's/^/  /' || true)
if [ -n "$other_docs" ]; then
  echo "FAIL: these DOCS values name a page other than ${readme_url}, which this guard checks headings in:" >&2
  echo "$other_docs" >&2
  echo "Point DOCS at README.md, or teach this guard the other page's headings." >&2
  exit 2
fi

# GitHub's heading anchor: lowercase, punctuation other than `-` and `_`
# dropped, spaces turned into hyphens.
anchors=$(grep -E '^#{1,6} ' README.md | sed -E 's/^#+ +//' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g')

failures=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  where="${hit%%:*}"
  rest="${hit#*:}"
  where="${where}:${rest%%:*}"
  text="${rest#*:}"
  code=$(sed -nE 's/.*::error title=([a-z0-9]+(-[a-z0-9]+)+)::.*/\1/p' <<<"$text")
  if [ -n "$code" ] && ! grep -qE "#${code}([^a-z0-9_-]|$)" <<<"$text"; then
    echo "FAIL: ${where} titles an annotation ${code} and links no #${code}" >&2
    failures=$((failures + 1))
  fi
  while IFS= read -r anchor; do
    [ -n "$anchor" ] || continue
    if ! grep -qxF "$anchor" <<<"$anchors"; then
      echo "FAIL: ${where} links README.md#${anchor}, and README.md has no heading with that anchor" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -oE '(\$\{DOCS\}|README\.md)#[a-z0-9_-]+' <<<"$text" | sed 's/.*#//')
done < <(grep -nE '::error title=|\$\{DOCS\}#|README\.md#' .github/workflows/*.yml | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)

if [ "$failures" -gt 0 ]; then
  echo "" >&2
  echo "Give each coded annotation a link to its own code, and README.md a heading for each code, such as ##### \`<code>\` under \"When a release stops\"." >&2
  exit 1
fi

echo "OK: every coded annotation in .github/workflows links a README.md heading that exists"
