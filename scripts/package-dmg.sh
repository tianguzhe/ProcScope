#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--skip-build' ]; }; then
    printf 'Usage: %s [--skip-build]\n' "$0" >&2; exit 2
fi
if [ "${1:-}" != '--skip-build' ]; then bash scripts/build.sh; fi
output_root="${PROCSCOPE_OUTPUT_DIR:-$project_root/release}"
mkdir -p "$output_root" build/dmg
output_root="$(cd "$output_root" && pwd)"
app_path="$output_root/ProcScope.app"
bash scripts/verify-app.sh "$app_path"
version=$(bash scripts/version.sh)
actual=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")
[ "$actual" = "$version" ] || { printf 'Stale app: rebuild version %s before packaging.\n' "$version" >&2; exit 1; }
venv="$project_root/build/dmg-venv"
if [ ! -x "$venv/bin/python" ]; then python3 -m venv "$venv"; fi
if ! "$venv/bin/python" -c 'from importlib.metadata import version; assert version("dmgbuild") == "1.6.7" and version("ds-store") == "1.3.3" and version("mac-alias") == "2.2.3"' >/dev/null 2>&1; then
    "$venv/bin/python" -m pip --disable-pip-version-check install -r Tools/dmg-requirements.txt
fi
work_root=$(mktemp -d "$project_root/build/dmg/package.XXXXXX")
trap 'rm -rf "$work_root"' EXIT
# Compile artwork only when its source changes. The app itself has no Python dependency.
renderer="$project_root/build/dmg/GenerateArtwork"
if [ ! -x "$renderer" ] || [ Tools/GenerateDMGArtwork.swift -nt "$renderer" ]; then
    xcrun swiftc -parse-as-library -module-cache-path "$project_root/build/dmg/swift-cache" \
        Tools/GenerateDMGArtwork.swift -o "$renderer"
fi
"$renderer" "$work_root" "$version"
"$venv/bin/dmgbuild" -s Tools/dmg-settings.py \
    -D "app=$app_path" -D "icon=$app_path/Contents/Resources/AppIcon.icns" \
    -D "background=$work_root/background.tiff" 'ProcScope' "$work_root/ProcScope.dmg"
/usr/bin/hdiutil verify "$work_root/ProcScope.dmg"
# Stable asset names keep website download links valid across every release.
mv -f "$work_root/ProcScope.dmg" "$output_root/ProcScope.dmg"
cp "$work_root/background@2x.png" "$output_root/dmg-background.png"
(cd "$output_root" && /usr/bin/shasum -a 256 ProcScope.dmg > ProcScope.dmg.sha256)
printf '\nInstaller: %s/ProcScope.dmg\nChecksum: %s/ProcScope.dmg.sha256\n' "$output_root" "$output_root"
