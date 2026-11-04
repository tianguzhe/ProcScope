#!/bin/bash
set -euo pipefail
if [ "$#" -ne 0 ]; then printf 'Usage: %s\n' "$0" >&2; exit 2; fi
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
build_root="${PROCSCOPE_BUILD_DIR:-$artifact_root/xcode/release}"
version=$(bash scripts/version.sh)
stage_root=$(mktemp -d "$artifact_root/app-stage.XXXXXX")
python3 "$isolation_script" exec --root "$project_root" --lane release -- \
    xcodebuild -project ProcScope.xcodeproj -scheme ProcScope -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_root" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build -quiet
/usr/bin/ditto "$build_root/Build/Products/Release/ProcScope.app" "$stage_root/ProcScope.app"
/usr/bin/codesign --force --sign - "$stage_root/ProcScope.app"
bash scripts/verify-app.sh "$stage_root/ProcScope.app" "$version"
# Stage and validate everything before replacing an older generated app.
if [ -e "$app_path" ]; then mv "$app_path" "$stage_root/previous.app"; fi
if ! mv "$stage_root/ProcScope.app" "$app_path"; then
    if [ -d "$stage_root/previous.app" ]; then mv "$stage_root/previous.app" "$app_path"; fi
    exit 1
fi
printf 'Built ProcScope %s (intermediate app): %s\n' "$version" "$app_path"
