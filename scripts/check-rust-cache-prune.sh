#!/usr/bin/env bash
# Rust cache prune contract guard.
#
# Fails when `rust-cache-prune.yml` loses one of the properties that keep its
# deletes to superseded entries: a job limited to branch refs and to
# `actions: write` plus `contents: read`, nothing pruned once the branch has
# moved on, an entry the run saved kept over one a pull request read later,
# saves counted from every attempt of the run, the run's own exact-key restore
# kept over an older generation a pull request read after it, only `v0-rust-*`
# entries touched, and a delete that races an eviction tolerated while any
# other failed delete fails the job.
#
# Why the rule exists: the workflow runs only in a caller's CI, against that
# repository's caches, so no run here exercises it, and each property breaks
# with every step green: the job deletes the entry the next run needs, and the
# only symptom is a cold build later.
#
# The behavior is checked by running the prune step's own `run:` block, as the
# runner does, against a stub `gh` that serves a canned cache listing, the
# branch head, and the run's `created_at` and `run_started_at`, and records
# each delete instead of sending it.
#
# Exit codes: 0 = every property holds, 1 = one does not (each named),
# 2 = the workflow, yq, or jq is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

wf=.github/workflows/rust-cache-prune.yml

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

if [ "$(yq -o=json -I=0 '.permissions' "$wf")" != '{}' ]; then
  fail "the workflow's permissions must be {}, so each job states its own"
fi
granted=$(yq -o=json -I=0 '.jobs.prune.permissions' "$wf")
if [ "$granted" != '{"actions":"write","contents":"read"}' ]; then
  fail "job prune's permissions must be exactly actions: write and contents: read, not $granted"
fi
if [ "$(yq -r '.jobs.prune.if' "$wf")" != "startsWith(github.ref, 'refs/heads/')" ]; then
  fail "job prune must run only on branch refs: if: startsWith(github.ref, 'refs/heads/')"
fi

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
yq -r '.jobs.prune.steps[0].run' "$wf" >"$sandbox/prune.sh"
cat >"$sandbox/bin/gh" <<'EOF'
#!/usr/bin/env bash
expr=
for ((i = 1; i < $#; i++)); do
  if [ "${!i}" = --jq ]; then
    next=$((i + 1))
    expr=${!next}
  fi
done
answer() {
  if [ -n "$expr" ]; then jq -r "$expr"; else cat; fi
}
# An id in `gone` is listed the first time, then evicted before its delete.
listed() {
  local out=("$STUB_DIR/deletes")
  if [ -e "$STUB_DIR/listed" ]; then out+=("$STUB_DIR/gone"); fi
  touch "$STUB_DIR/listed"
  jq --rawfile out <(cat "${out[@]}") \
    '[.[] | select((.id | tostring) as $id | $out | split("\n") | index($id) | not)]' "$STUB_DIR/listing.json"
}
case "$1 $2" in
  "cache list") listed | answer ;;
  "cache delete")
    if grep -qx "$3" "$STUB_DIR/deny"; then
      echo "HTTP 403: Resource not accessible by integration" >&2
      exit 1
    elif grep -qx "$3" "$STUB_DIR/gone"; then
      echo "X Could not find a cache matching $3 in $GH_REPO" >&2
      exit 1
    fi
    echo "$3" >>"$STUB_DIR/deletes"
    ;;
  "api repos/"*)
    case "$2" in
      */git/ref/*) jq -n --arg sha "$STUB_HEAD" '{object: {sha: $sha}}' | answer ;;
      */actions/runs/*) jq -n --arg c "$STUB_CREATED" --arg s "$STUB_STARTED" '{created_at: $c, run_started_at: $s}' | answer ;;
      *) echo "stub gh: unexpected api path $2" >&2; exit 1 ;;
    esac
    ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$sandbox/bin/gh"

sha=1111111111111111111111111111111111111111
created=2026-11-10T19:30:00Z
started=2026-11-10T19:46:58Z

# entry <id> <key> <createdAt> <lastAccessedAt>, one per line on stdin, gives
# the JSON array `gh cache list` prints. Cache times carry fractional seconds
# of varying length and the run's times carry none, as GitHub returns them.
listing() {
  jq -R -s 'split("\n") | map(select(length > 0) | split(" ")
    | {id: (.[0] | tonumber), key: .[1], createdAt: .[2], lastAccessedAt: .[3], sizeInBytes: 1048576})'
}

# check <name> <head> <expected deletes> <expected outcome> [gone ids] [denied ids]
check() {
  local name=$1 head=$2 want=$3 outcome=$4 gone=${5:-} deny=${6:-}
  local dir="$sandbox/$name" rc=0 got
  mkdir -p "$dir/work"
  cp "$sandbox/listing.json" "$dir/listing.json"
  : >"$dir/deletes"
  tr ' ' '\n' <<<"$gone" >"$dir/gone"
  tr ' ' '\n' <<<"$deny" >"$dir/deny"
  (cd "$dir/work" && env PATH="$sandbox/bin:$PATH" STUB_DIR="$dir" STUB_HEAD="$head" STUB_CREATED="$created" \
    STUB_STARTED="$started" GH_TOKEN=stub GH_REPO=owner/repo REF=refs/heads/dev GITHUB_SHA="$sha" GITHUB_RUN_ID=1 \
    bash --noprofile --norc -eo pipefail "$sandbox/prune.sh" </dev/null >"$dir/log" 2>&1) || rc=$?
  got=$(sort -n "$dir/deletes" | paste -sd' ')
  if [ "$outcome" = pass ] && [ "$rc" -ne 0 ]; then
    fail "$name: the step exits $rc: $(tail -n 2 "$dir/log" | tr '\n' ' ')"
  elif [ "$outcome" = fail ] && [ "$rc" -eq 0 ]; then
    fail "$name: the step passes; it must fail"
  fi
  if [ "$got" != "$want" ]; then
    fail "$name: deletes '${got}', expected '${want}'"
  fi
}

ci=v0-rust-ci-linux-Linux-x64-cc6d2644
win=v0-rust-windows-Windows_NT-x64-a16af5f6

listing >"$sandbox/listing.json" <<EOF
1 $ci-09439984 2026-11-09T22:54:47.02535Z 2026-11-10T19:53:12.401177Z
2 $ci-5e1c7a02 2026-11-10T19:51:40.218843Z 2026-11-10T19:51:40.218843Z
3 $win-09439984 2026-11-09T03:07:35.317645Z 2026-11-10T19:47:20.55431Z
4 $win-5e1c7a02 2026-11-10T19:55:03.774092Z 2026-11-10T19:55:03.774092Z
EOF
check "a saved entry outranks a later read" "$sha" "1 3" pass
check "a re-run after the branch moved on" 2222222222222222222222222222222222222222 "" pass
check "a delete that races an eviction" "$sha" "3" pass "1"
check "a delete that fails for another reason" "$sha" "" fail "" "1"

listing >"$sandbox/listing.json" <<EOF
1 $ci-09439984 2026-11-09T22:54:47.02535Z 2026-11-10T19:38:05.1Z
2 $ci-5e1c7a02 2026-11-10T19:36:40.5Z 2026-11-10T19:36:40.5Z
EOF
check "a save from an earlier attempt of the run" "$sha" "1" pass

listing >"$sandbox/listing.json" <<EOF
1 $ci-09439984 2026-11-09T22:54:47.02535Z 2026-11-10T19:45:00.01Z
2 $ci-5e1c7a02 2026-11-10T18:00:00.25Z 2026-11-10T19:35:00.7Z
EOF
check "an exact-key restore and a later read of an older generation" "$sha" "1" pass

listing >"$sandbox/listing.json" <<EOF
1 v0-rust-x86_64-unknown-linux-gnu-build-Linux-x64-ae49ceb1-7c0d11e5 2026-11-01T10:00:00.5Z 2026-11-02T10:00:00.5Z
2 v0-rust-x86_64-unknown-linux-gnu-build-Linux-x64-ae49ceb1-09439984 2026-11-10T19:00:00.5Z 2026-11-10T19:00:00.5Z
EOF
check "nothing saved or read by the run" "$sha" "1" pass

listing >"$sandbox/listing.json" <<EOF
1 node-cache-Linux-x64-09439984 2026-11-09T22:54:47.02535Z 2026-11-10T19:53:12.401177Z
2 node-cache-Linux-x64-5e1c7a02 2026-11-10T19:51:40.218843Z 2026-11-10T19:51:40.218843Z
3 $ci-5e1c7a02 2026-11-10T19:51:40.218843Z 2026-11-10T19:51:40.218843Z
EOF
check "entries outside v0-rust-* and groups of one" "$sha" "" pass

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "OK: $wf keeps the run's entries, skips a moved branch, touches only v0-rust-* entries, and fails only on a real delete failure"
