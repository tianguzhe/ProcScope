#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
version=$(awk -F ' = ' '/^MARKETING_VERSION = / {print $2}' "$project_root/Version.xcconfig")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Expected a three-part version in Version.xcconfig; got: %s\n' "$version" >&2
    exit 1
fi
printf '%s\n' "$version"
