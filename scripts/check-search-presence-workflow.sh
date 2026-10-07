#!/usr/bin/env bash
# Search-presence workflow contract guard.
#
# Fails when `search-presence.yml` loses one of the properties that keep a
# site's state whole between runs, or that let it read Search Console at all.
#
# Why the rule exists: the workflow runs only in a site repository with Google
# and Bing credentials, so no run here exercises it, and each of these breaks
# with every step green. A cache saved only on success, or under a key or path
# the restore does not match, starts each run cold: the submission ledger
# forgets what was sent and the quota ledger counts from zero. A run cancelled
# by a newer one saves nothing it spent. Without explicit scopes the access
# token carries `cloud-platform`, which Search Console refuses, so every Google
# row reads unknown; an unconditional read-write scope asks for more than a
# dry run uses.
#
# Exit codes: 0 = every property holds, 1 = one does not (each named),
# 2 = the workflow or yq is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

wf=.github/workflows/search-presence.yml

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to read $wf" >&2
  exit 2
fi
if [ ! -f "$wf" ]; then
  echo "FAIL: $wf does not exist" >&2
  exit 2
fi

failures=0
fail() {
  echo "FAIL: $wf: $*" >&2
  failures=$((failures + 1))
}

step_field() {
  yq -r ".jobs[].steps[] | select((.uses // \"\") | test(\"^$1@\")) | .$2 // \"\"" "$wf"
}

if [ "$(yq -r '.concurrency."cancel-in-progress"' "$wf")" != false ]; then
  fail "concurrency.cancel-in-progress must be false, so a newer run queues instead of cancelling one that has spent quota"
fi

restore_path=$(step_field actions/cache/restore with.path)
restore_keys=$(step_field actions/cache/restore 'with."restore-keys"')
save_path=$(step_field actions/cache/save with.path)
save_key=$(step_field actions/cache/save with.key)
save_if=$(step_field actions/cache/save if)

if [ -z "$restore_path" ] || [ -z "$save_path" ]; then
  fail "state is restored with actions/cache/restore and saved with actions/cache/save"
elif [ "$restore_path" != "$save_path" ]; then
  fail "the restore path ($restore_path) and the save path ($save_path) differ, so the saved state is never restored"
fi
if [ -z "$restore_keys" ] || [[ "$save_key" != "$restore_keys"* ]]; then
  fail "the save key ($save_key) must start with the restore-keys prefix ($restore_keys)"
fi
if [[ "$save_if" != *"always()"* ]]; then
  fail "the save step runs under always(), so a run that fails on its findings keeps what it spent"
fi

scopes=$(step_field google-github-actions/auth with.access_token_scopes)
if [[ "$scopes" != *"auth/webmasters.readonly"* || "$scopes" != *"inputs.apply"* ]]; then
  fail "access_token_scopes asks for webmasters.readonly, and for webmasters only with inputs.apply: $scopes"
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "OK: $wf keeps its state between runs and asks for Search Console scopes"
