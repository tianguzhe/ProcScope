#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [ "$#" -ne 0 ]; then printf 'Usage: %s\n' "$0" >&2; exit 2; fi
build_root="${PROCSCOPE_BUILD_DIR:-$project_root/build/release}"
output_root="${PROCSCOPE_OUTPUT_DIR:-$project_root/release}"
version=$(bash scripts/version.sh)
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
stage_root=$(mktemp -d "$output_root/.app-stage.XXXXXX")
trap 'rm -rf "$stage_root"' EXIT
xcodebuild -project ProcScope.xcodeproj -scheme ProcScope -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_root" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build -quiet
/usr/bin/ditto "$build_root/Build/Products/Release/ProcScope.app" "$stage_root/ProcScope.app"
/usr/bin/codesign --force --sign - "$stage_root/ProcScope.app"
bash scripts/verify-app.sh "$stage_root/ProcScope.app"
actual=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$stage_root/ProcScope.app/Contents/Info.plist")
[ "$actual" = "$version" ] || { printf 'Built version %s differs from %s\n' "$actual" "$version" >&2; exit 1; }
# Stage and validate everything before replacing an older generated app.
if [ -e "$output_root/ProcScope.app" ]; then mv "$output_root/ProcScope.app" "$stage_root/previous.app"; fi
if ! mv "$stage_root/ProcScope.app" "$output_root/ProcScope.app"; then
    if [ -d "$stage_root/previous.app" ]; then mv "$stage_root/previous.app" "$output_root/ProcScope.app"; fi
    exit 1
fi
printf 'Built ProcScope %s: %s/ProcScope.app\n' "$version" "$output_root"
