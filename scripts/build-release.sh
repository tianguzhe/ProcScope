#!/bin/bash
# Compatibility entry point: build + sign + designed DMG + SHA-256.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$project_root/scripts/package-dmg.sh" "$@"
