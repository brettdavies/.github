#!/usr/bin/env bash
# Runs the actionlint in DIR over the workflows of the current directory's
# project and prints one GitHub annotation per finding.
#
# A shellcheck finding at warning or info severity annotates without failing.
# Every other finding fails, and so does a shellcheck line this script cannot
# read. pyflakes is off so a runner that happens to carry it cannot change the
# result.
#
# Usage: [ACTIONLINT_TIMEOUT_SECONDS=N] run-actionlint.sh DIR
set -euo pipefail

dir=${1:?usage: run-actionlint.sh DIR}
timeout_seconds=${ACTIONLINT_TIMEOUT_SECONDS:-300}

# actionlint turns its shellcheck rule off without a message when the command is
# missing, which would pass a workflow the gate should fail.
if [ ! -x "$dir/shellcheck" ]; then
  echo "::error title=actionlint::no shellcheck to run in ${dir}, so the shellcheck findings would go unreported"
  exit 1
fi

# GitHub keeps this many annotations of one level from a step.
annotation_cap=10

# actionlint unescapes \n, \t, and \\ in the format before Go parses it, so a
# quoted string inside an action needs the doubled backslash. Newlines and tabs
# in a value would otherwise split a record.
format='{{range .}}{{replace .Filepath "\\n" " " "\\r" " " "\\t" " "}}\t{{.Line}}\t{{.Column}}\t{{.Kind}}\t{{replace .Message "\\n" " " "\\r" " " "\\t" " "}}\n{{end}}'

# https://github.com/actions/toolkit/blob/main/packages/core/src/command.ts
escape_data() {
  local value=${1//%/%25}
  value=${value//$'\r'/%0D}
  printf '%s' "${value//$'\n'/%0A}"
}

escape_property() {
  local value
  value=$(escape_data "$1")
  value=${value//:/%3A}
  printf '%s' "${value//,/%2C}"
}

status=0
findings=$(timeout -k 5 "$timeout_seconds" "$dir/actionlint" -no-color -shellcheck="$dir/shellcheck" -pyflakes= -format "$format") || status=$?

case "$status" in
  0)
    echo "actionlint: no findings"
    exit 0
    ;;
  1) ;;
  124 | 137)
    echo "::error title=actionlint::actionlint did not finish in ${timeout_seconds} s. Releases up to 1.7.12 hang on a run block bigger than the runner's pipe buffer (https://github.com/rhysd/actionlint/issues/650); move the largest run block into a script."
    exit "$status"
    ;;
  *)
    echo "::error title=actionlint::actionlint could not run and exited ${status}; its message is in the step log"
    exit "$status"
    ;;
esac

annotations=()
failing=0
below_gate=0
below_gate_pattern='^shellcheck reported issue in this script: SC[0-9]+:(warning|info):'
while IFS=$'\t' read -r file line column kind message; do
  [ -n "$file" ] || continue
  level=error
  if [ "$kind" = shellcheck ] && [[ "$message" =~ $below_gate_pattern ]]; then
    case "${BASH_REMATCH[1]}" in
      warning) level=warning ;;
      info) level=notice ;;
    esac
  fi
  if [ "$level" = error ]; then
    failing=$((failing + 1))
  else
    below_gate=$((below_gate + 1))
  fi
  annotations+=("::${level} file=$(escape_property "$file"),line=$(escape_property "$line"),col=$(escape_property "$column"),title=actionlint::$(escape_data "$message [$kind]")")
done <<<"$findings"

if [ $((failing + below_gate)) -eq 0 ]; then
  echo "::error title=actionlint::actionlint reported findings this script could not read"
  exit 1
fi

# Past the cap the count goes first, because the findings after it lose their
# annotation; it takes one of the slots, so up to the cap it would cost one.
if [ "$failing" -gt "$annotation_cap" ]; then
  echo "::error title=actionlint::${failing} findings fail this job and a step shows at most ${annotation_cap} error annotations, so $((annotation_cap - 1)) appear beside this one; the step log lists every one"
fi
printf '%s\n' "${annotations[@]}"
echo "actionlint: ${failing} failing, ${below_gate} below the gate"
[ "$failing" -eq 0 ]
