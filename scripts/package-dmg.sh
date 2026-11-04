#!/bin/bash
set -euo pipefail
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--skip-build' ]; }; then
    printf 'Usage: %s [--skip-build]\n' "$0" >&2; exit 2
fi
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if [ "${1:-}" != '--skip-build' ]; then bash scripts/build.sh; fi
output_root="${PROCSCOPE_OUTPUT_DIR:-$project_root/release}"
mkdir -p "$output_root" "$artifact_root/dmg"
output_root="$(cd "$output_root" && pwd)"
version=$(bash scripts/version.sh)
bash scripts/verify-app.sh "$app_path" "$version"
venv="$artifact_root/dmg-venv"
if [ ! -x "$venv/bin/python" ]; then
    # Xcode's python3 may still be 3.9; dmgbuild needs Python 3.10+.
    python_bin="${PROCSCOPE_PYTHON:-}"
    if [[ -z "$python_bin" ]]; then
        for candidate in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
            if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
                python_bin="$(command -v "$candidate")"
                break
            fi
        done
    fi
    if [[ -z "$python_bin" ]] || ! "$python_bin" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        printf 'DMG packaging requires Python 3.10+; set PROCSCOPE_PYTHON if needed.\n' >&2
        exit 1
    fi
    "$python_bin" -m venv "$venv"
fi
if ! "$venv/bin/python" -c 'from importlib.metadata import version; assert version("dmgbuild") == "1.6.7" and version("ds-store") == "1.3.3" and version("mac-alias") == "2.2.3"' >/dev/null 2>&1; then
    "$venv/bin/python" -m pip --disable-pip-version-check install -r Tools/dmg-requirements.txt
fi
stage_root=$(mktemp -d "$artifact_root/dmg/package.XXXXXX")
# Compile artwork only when its source changes. The app itself has no Python dependency.
renderer="$artifact_root/dmg/GenerateArtwork"
if [ ! -x "$renderer" ] || [ Tools/GenerateDMGArtwork.swift -nt "$renderer" ]; then
    xcrun swiftc -parse-as-library -module-cache-path "$artifact_root/cache/dmg" \
        Tools/GenerateDMGArtwork.swift -o "$renderer"
fi
"$renderer" "$stage_root" "$version"
"$venv/bin/dmgbuild" -s Tools/dmg-settings.py \
    -D "app=$app_path" -D "icon=$app_path/Contents/Resources/AppIcon.icns" \
    -D "background=$stage_root/background.tiff" 'ProcScope' "$stage_root/ProcScope.dmg"
/usr/bin/hdiutil verify "$stage_root/ProcScope.dmg"
# Verify the compressed installer too; Finder metadata can invalidate signatures.
verify_mount=$(mktemp -d "$stage_root/verify.XXXXXX")
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$verify_mount" "$stage_root/ProcScope.dmg" >/dev/null
bash scripts/verify-app.sh "$verify_mount/ProcScope.app" "$version"
cmp "$app_path/Contents/MacOS/ProcScope" "$verify_mount/ProcScope.app/Contents/MacOS/ProcScope"
cmp "$app_path/Contents/Info.plist" "$verify_mount/ProcScope.app/Contents/Info.plist"
[[ "$(readlink "$verify_mount/Applications")" == /Applications ]]
[[ -s "$verify_mount/.DS_Store" ]]
/usr/bin/hdiutil detach -quiet "$verify_mount"
rmdir "$verify_mount"
verify_mount=""
# Stable asset names keep website download links valid across every release.
mv -f "$stage_root/ProcScope.dmg" "$output_root/ProcScope.dmg"
cp "$stage_root/background@2x.png" "$output_root/dmg-background.png"
(cd "$output_root" && /usr/bin/shasum -a 256 ProcScope.dmg > ProcScope.dmg.sha256 && /usr/bin/shasum -a 256 -c ProcScope.dmg.sha256)
printf '\nInstaller: %s/ProcScope.dmg\nChecksum: %s/ProcScope.dmg.sha256\n' "$output_root" "$output_root"
