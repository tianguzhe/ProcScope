#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$artifact_root/previews"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$artifact_root/cache/previews" \
    -import-objc-header ProcScope/Services/ProcBridge.h \
    ProcScope/Models/*.swift ProcScope/Services/*.swift ProcScope/Views/*.swift \
    Tools/RenderPreviews.swift -o "$artifact_root/previews/RenderPreviews"
PROCSCOPE_PREVIEW_VERSION="$(bash scripts/version.sh)" "$artifact_root/previews/RenderPreviews" "${1:-docs}"
