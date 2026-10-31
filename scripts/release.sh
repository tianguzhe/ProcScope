#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
version=$(bash scripts/version.sh)
tag="v$version"
[ "$(git branch --show-current)" = main ] || { printf 'Release from main.\n' >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { printf 'Commit changes before releasing.\n' >&2; exit 1; }
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    printf '%s exists. Bump Version.xcconfig first.\n' "$tag" >&2; exit 1
fi
bash scripts/test.sh
git tag -a "$tag" -m "ProcScope $tag"
if ! git push --atomic origin main "refs/tags/$tag"; then
    git tag -d "$tag" >/dev/null
    printf 'Push failed; removed the newly created local tag.\n' >&2
    exit 1
fi
printf 'Pushed %s. GitHub Actions will build, verify and publish ProcScope.dmg.\n' "$tag"
