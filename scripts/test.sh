#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
test_arch=$(uname -m)
python3 "$isolation_script" exec --root "$project_root" --lane test -- \
    xcodebuild -project ProcScope.xcodeproj -scheme ProcScope \
    -destination "platform=macOS,arch=$test_arch" \
    ARCHS="$test_arch" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test -quiet
