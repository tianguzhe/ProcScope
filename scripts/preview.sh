#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p build/previews
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$project_root/build/preview-cache" \
    -import-objc-header ProcScope/Services/ProcBridge.h \
    ProcScope/Models/*.swift ProcScope/Services/SystemService.swift ProcScope/Views/*.swift \
    Tools/RenderPreviews.swift -o build/previews/RenderPreviews
build/previews/RenderPreviews "${1:-docs}"
