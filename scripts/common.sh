#!/bin/bash
# Shared artifact paths and failure cleanup for local and CI entry points.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_root="$project_root/.build/artifacts.noindex"
isolation_script="$project_root/scripts/build_isolation.py"
app_path="$artifact_root/ProcScope.app"
stage_root=""
verify_mount=""
python3 "$isolation_script" prepare --root "$project_root" >/dev/null || exit $?
cd "$project_root"

procscope_detach_verification_image() {
    [[ -n "$verify_mount" ]] || return 0
    local mount_status=0
    # Distinguish an unmounted directory (3) from a failed probe (any other error).
    python3 -c 'import os,sys; sys.exit(0 if os.path.ismount(sys.argv[1]) else 3)' "$verify_mount" || mount_status=$?
    case "$mount_status" in
        0)
            /usr/bin/hdiutil detach -quiet "$verify_mount" 2>/dev/null ||
                /usr/bin/hdiutil detach -force -quiet "$verify_mount" 2>/dev/null || return 1
            ;;
        3) ;;
        *) return 1 ;;
    esac
    rmdir "$verify_mount" 2>/dev/null || true
    verify_mount=""
}

procscope_cleanup() {
    local code=$? preserve_stage=0
    trap - EXIT
    if ! procscope_detach_verification_image; then
        printf 'Could not verify or detach %s; preserving package work directory.\n' "$verify_mount" >&2
        preserve_stage=1
        [[ "$code" -ne 0 ]] || code=1
    fi
    if ! python3 "$isolation_script" cleanup --root "$project_root"; then
        [[ "$code" -ne 0 ]] || code=1
    fi
    if [[ -n "$stage_root" && "$preserve_stage" -eq 0 ]]; then rm -rf "$stage_root"; fi
    exit "$code"
}
trap procscope_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
