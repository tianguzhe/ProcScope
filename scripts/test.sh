#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
test_arch=$(uname -m)
xcodebuild -project ProcScope.xcodeproj -scheme ProcScope \
    -destination "platform=macOS,arch=$test_arch" -derivedDataPath build/test \
    ARCHS="$test_arch" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test -quiet
