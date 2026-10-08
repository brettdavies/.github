#!/usr/bin/env bash
# Search-presence workflow contract guard.
#
# Fails when `search-presence.yml` loses one of the properties that make it a
# read-only regression gate: a token limited to `contents: read`, no OIDC
# token, the skill's checkout authenticated with the skill token, an audit
# step that gets no secret, and a job that fails when the audit exits non-zero.
#
# Why the rule exists: the workflow runs only in a site repository with a
# deployed site and the skill token, so no run here exercises it, and each of
# these breaks with every step green. A wider grant or an OIDC token hands an
# audit more than it reads. A skill checkout without the token fails only in a
# caller, against a private skill repository. An audit step that swallows
# its exit code passes every deploy, regressions included.
#
# The exit property is checked by running the audit step's own `run:` block,
# as the runner does, with a stub `uv` that exits with each of the audit's
# codes: 0 passes, 1 is rows at or above fail_on, 2 is an audit that did not
# finish, which also leaves a line in the job summary.
#
# Exit codes: 0 = every property holds, 1 = one does not (each named),
# 2 = the workflow or yq is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

wf=.github/workflows/search-presence.yml

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
  echo "FAIL: $wf: $*" >&2
  failures=$((failures + 1))
}

read_only='{"contents":"read"}'
granted=$(yq -o=json -I=0 '.permissions' "$wf")
if [ "$granted" != "$read_only" ]; then
  fail "the workflow's permissions must be exactly contents: read, not $granted"
fi
while read -r job; do
  granted=$(yq -o=json -I=0 ".jobs.\"$job\".permissions" "$wf")
  if [ "$granted" != null ] && [ "$granted" != "$read_only" ]; then
    fail "job $job's permissions must be absent or exactly contents: read, not $granted"
  fi
done < <(yq -r '.jobs | keys | .[]' "$wf")

if [ "$(yq '[.. | select(key == "id-token")] | length' "$wf")" != 0 ]; then
  fail "id-token appears in the workflow; the audit needs no OIDC token"
fi

token_re='^\$\{\{ *secrets\.SEARCH_PRESENCE_SKILL_TOKEN *\}\}$'
mapfile -t skill_tokens < <(yq -r '.jobs[].steps[]
  | select((.uses // "") | test("^actions/checkout@"))
  | select((.with.repository // "") | test("inputs\.skill_repository"))
  | .with.token // ""' "$wf")
if [ ${#skill_tokens[@]} -ne 1 ]; then
  fail "exactly one actions/checkout step checks out inputs.skill_repository, not ${#skill_tokens[@]}"
elif [[ ! "${skill_tokens[0]}" =~ $token_re ]]; then
  fail "the skill checkout's token must be secrets.SEARCH_PRESENCE_SKILL_TOKEN, not '${skill_tokens[0]}'"
fi

audit_select='.jobs[].steps[] | select((.run // "") | test("audit_indexability\.py"))'
audit_count=$(yq "[$audit_select] | length" "$wf")
if [ "$audit_count" != 1 ]; then
  fail "exactly one step runs audit_indexability.py, not $audit_count"
else
  job=$(yq -r '.jobs | to_entries[] | select(.value.steps[] | (.run // "") | test("audit_indexability\.py")) | .key' "$wf")
  if [ "$(yq ".jobs.\"$job\".\"continue-on-error\" // false" "$wf")" != false ]; then
    fail "job $job sets continue-on-error, so a failed audit passes the job"
  fi
  if [ "$(yq "$audit_select | .\"continue-on-error\" // false" "$wf")" != false ]; then
    fail "the audit step sets continue-on-error, so a failed audit passes the job"
  fi
  if [ "$(yq "$audit_select | .if // \"\"" "$wf")" != "" ]; then
    fail "the audit step carries an if:, so it can be skipped with the job green"
  fi
  if [ "$(yq -o=json -I=0 "$audit_select | .env | keys" "$wf")" != '["CONFIG"]' ]; then
    fail "the audit step's env must hold CONFIG and nothing else, so the audit gets no secret"
  fi

  sandbox=$(mktemp -d)
  trap 'rm -rf "$sandbox"' EXIT
  mkdir -p "$sandbox/bin"
  cat >"$sandbox/bin/uv" <<'EOF'
#!/usr/bin/env bash
exit "$STUB_EXIT"
EOF
  chmod +x "$sandbox/bin/uv"
  yq -r "$audit_select | .run" "$wf" >"$sandbox/audit.sh"

  for code in 0 1 2 3; do
    rc=0
    : >"$sandbox/summary"
    env PATH="$sandbox/bin:$PATH" STUB_EXIT="$code" CONFIG=search-presence.toml SKILL_DIR="$sandbox/skill" \
      GITHUB_STEP_SUMMARY="$sandbox/summary" bash --noprofile --norc -eo pipefail "$sandbox/audit.sh" \
      </dev/null >"$sandbox/log" 2>&1 || rc=$?
    if [ "$code" -eq 0 ] && [ "$rc" -ne 0 ]; then
      fail "the audit step fails when the audit exits 0 (exit $rc): $(tail -n 3 "$sandbox/log" | tr '\n' ' ')"
    elif [ "$code" -ne 0 ] && [ "$rc" -eq 0 ]; then
      fail "the audit step passes when the audit exits $code; the job must fail"
    fi
    if [ "$code" -eq 2 ] && ! grep -q "did not finish" "$sandbox/summary"; then
      fail "the audit step leaves no 'did not finish' line in the job summary when the audit exits 2"
    fi
  done
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "OK: $wf reads with contents: read only, checks out the skill with its token, and fails on the audit's exit code"
