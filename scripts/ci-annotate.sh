#!/bin/bash
# Retain the failing command's exit status and surface useful CI diagnostics.
set -uo pipefail
if [ "$#" -lt 2 ]; then printf 'Usage: %s <title> <command> [args...]\n' "$0" >&2; exit 2; fi
annotation_title="$1"
shift
log_path=$(mktemp)
trap 'rm -f "$log_path"' EXIT
"$@" 2>&1 | tee "$log_path"
command_status=${PIPESTATUS[0]}
if [ "$command_status" -ne 0 ]; then
    lines=$(awk '/error:|failed|Fatal error|fatal error/' "$log_path" | tail -n 35)
    [ -n "$lines" ] || lines=$(tail -n 35 "$log_path")
    lines=${lines//'%'/'%25'}; lines=${lines//$'\r'/'%0D'}; lines=${lines//$'\n'/'%0A'}
    printf '::error title=%s failed::%s\n' "$annotation_title" "$lines"
fi
exit "$command_status"
