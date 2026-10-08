#!/usr/bin/env bash
# Search-presence workflow contract guard.
#
# Fails when `search-presence.yml` loses one of the properties that make it a
# read-only regression gate: a token limited to `contents: read`, no OIDC
# token, the skill's checkout authenticated with the skill token, and a job
# that fails when the audit exits non-zero or reports rows at the config's
# fail_on level.
#
# Why the rule exists: the workflow runs only in a site repository with a
# deployed site and the skill token, so no run here exercises it, and each of
# these breaks with every step green. A wider grant or an OIDC token hands an
# audit more than it reads. A skill checkout without the token fails only in a
# caller, against a private skill repository. An audit step that swallows
# its exit code passes every deploy, regressions included.
#
# The exit property is checked by running the audit step's own `run:` block,
# as the runner does, with a stub `uv` that answers with a fixed report and
# exit code.
#
# Exit codes: 0 = every property holds, 1 = one does not (each named),
# 2 = the workflow, yq, or jq is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

wf=.github/workflows/search-presence.yml

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is required to check $wf" >&2
    exit 2
  fi
done
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
  if [ "$(yq -o=json -I=0 "$audit_select | .env | keys | sort" "$wf")" != '["FAIL_ON","ORIGIN"]' ]; then
    fail "the audit step reads ORIGIN and FAIL_ON from its env, and nothing else"
  fi

  sandbox=$(mktemp -d)
  trap 'rm -rf "$sandbox"' EXIT
  mkdir -p "$sandbox/bin" "$sandbox/tmp"
  cat >"$sandbox/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$STUB_REPORT"
exit "$STUB_EXIT"
EOF
  chmod +x "$sandbox/bin/uv"
  yq -r "$audit_select | .run" "$wf" >"$sandbox/audit.sh"

  report() {
    jq -cn --arg status "$1" '{origin: "https://example.com", identity: {user_agent: "stub"},
      rows: [{id: "H1", title: "stub", status: $status, detail: "stub",
        next_step: {action: "none", command: "", docs: ""}}]}'
  }
  error='{"error":{"reason":"fetch-failed","exit_code":2,"message":"stub","next_step":{"action":"none","command":"","docs":""}}}'

  # case: name, audit exit, report, fail_on, whether the step must pass
  while IFS='|' read -r name code body level expect; do
    rc=0
    env PATH="$sandbox/bin:$PATH" STUB_EXIT="$code" STUB_REPORT="$body" ORIGIN=https://example.com \
      FAIL_ON="$level" SKILL_DIR="$sandbox/skill" RUNNER_TEMP="$sandbox/tmp" \
      GITHUB_STEP_SUMMARY="$sandbox/summary" GITHUB_OUTPUT="$sandbox/output" \
      bash --noprofile --norc -eo pipefail "$sandbox/audit.sh" </dev/null >"$sandbox/log" 2>&1 || rc=$?
    if [ "$expect" = pass ] && [ "$rc" -ne 0 ]; then
      fail "the audit step fails on $name (exit $rc): $(tail -n 3 "$sandbox/log" | tr '\n' ' ')"
    elif [ "$expect" = fail ] && [ "$rc" -eq 0 ]; then
      fail "the audit step passes on $name; the job must fail"
    fi
  done <<EOF
exit 0 with only pass rows|0|$(report pass)|fail|pass
exit 0 with a warn row at fail_on = fail|0|$(report warn)|fail|pass
exit 1 with a fail row|1|$(report fail)|fail|fail
exit 1 with only pass rows|1|$(report pass)|fail|fail
exit 2 with the error envelope|2|$error|fail|fail
exit 0 with a warn row at fail_on = warn|0|$(report warn)|warn|fail
EOF
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "OK: $wf reads with contents: read only, checks out the skill with its token, and fails on the audit's verdict"
