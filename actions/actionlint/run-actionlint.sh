#!/usr/bin/env bash
# Runs the actionlint in DIR over the workflows of the current directory's
# project and prints one GitHub annotation per finding.
#
# A shellcheck finding at warning or info severity annotates without failing.
# Every other finding fails, and so does a shellcheck line this script cannot
# read. pyflakes is off so a runner that happens to carry it cannot change the
# result.
#
# Usage: run-actionlint.sh DIR
set -euo pipefail

dir=${1:?usage: run-actionlint.sh DIR}

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
findings=$("$dir/actionlint" -no-color -shellcheck="$dir/shellcheck" -pyflakes= -format "$format") || status=$?

if [ "$status" -gt 1 ]; then
  echo "::error title=actionlint::actionlint could not run and exited ${status}; its message is in the step log"
  exit "$status"
fi

if [ "$status" -eq 0 ]; then
  echo "actionlint: no findings"
  exit 0
fi

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
  printf '::%s file=%s,line=%s,col=%s,title=actionlint::%s\n' \
    "$level" "$(escape_property "$file")" "$(escape_property "$line")" "$(escape_property "$column")" \
    "$(escape_data "$message [$kind]")"
done <<<"$findings"

if [ $((failing + below_gate)) -eq 0 ]; then
  echo "::error title=actionlint::actionlint reported findings this script could not read"
  exit 1
fi

echo "actionlint: ${failing} failing, ${below_gate} below the gate"
[ "$failing" -eq 0 ]
