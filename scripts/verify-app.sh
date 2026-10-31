#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then printf 'Usage: %s <ProcScope.app>\n' "$0" >&2; exit 2; fi
app_path="$1"
binary="$app_path/Contents/MacOS/ProcScope"
/usr/bin/codesign --verify --deep --strict "$app_path"
archs=$(/usr/bin/lipo -archs "$binary")
for target_arch in arm64 x86_64; do
    [[ " $archs " == *" $target_arch "* ]] || { printf 'Missing architecture: %s\n' "$target_arch" >&2; exit 1; }
    minimum=$(/usr/bin/otool -arch "$target_arch" -l "$binary" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')
    [ "$minimum" = '14.0' ] || { printf '%s minimum macOS is %s, expected 14.0\n' "$target_arch" "$minimum" >&2; exit 1; }
done
printf 'Verified signature, arm64 + x86_64, macOS 14.0 minimum.\n'
