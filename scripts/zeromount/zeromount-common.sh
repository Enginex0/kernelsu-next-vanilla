#!/bin/bash
# zeromount-common.sh -- shared version detection and verification helpers
# Sourced by all inject-zeromount-*.sh scripts
#
# Exports: ZM_KVER, ZM_API
# Provides: detect_kernel_version, verify_injection, zm_backup, zm_cleanup

# Detect kernel version and classify into API generation.
#
# Sets:
#   ZM_KVER  - kernel version string (e.g. "5.10", "6.6")
#   ZM_API   - API generation tag:
#     inode_only  (5.10)  - generic_permission(inode, mask)
#     user_ns     (5.15, 6.1) - generic_permission(userns, inode, mask)
#     mnt_idmap   (6.6)   - generic_permission(idmap, inode, mask)
detect_kernel_version() {
    if [[ -n "${KERNEL_VERSION:-}" ]]; then
        ZM_KVER="$KERNEL_VERSION"
    elif [[ -n "${1:-}" && -f "$1" ]]; then
        # Caller passed a kernel source file -- walk up to find Makefile
        local dir
        dir="$(dirname "$1")"
        while [[ "$dir" != "/" ]]; do
            if [[ -f "$dir/Makefile" ]] && grep -q '^VERSION' "$dir/Makefile"; then
                local ver patch
                ver=$(grep '^VERSION' "$dir/Makefile" | head -1 | awk '{print $3}')
                patch=$(grep '^PATCHLEVEL' "$dir/Makefile" | head -1 | awk '{print $3}')
                ZM_KVER="${ver}.${patch}"
                break
            fi
            dir="$(dirname "$dir")"
        done
    fi

    if [[ -z "${ZM_KVER:-}" ]]; then
        echo "FATAL: Cannot detect kernel version."
        echo "  Set KERNEL_VERSION env var or pass a kernel source file path."
        exit 1
    fi

    case "$ZM_KVER" in
        5.10|5.4)   ZM_API="inode_only" ;;
        5.15|6.1)   ZM_API="user_ns"    ;;
        6.6)        ZM_API="mnt_idmap"  ;;
        6.12)       ZM_API="mnt_idmap"  ;;
        *)
            echo "FATAL: Unsupported kernel version: $ZM_KVER"
            exit 1
            ;;
    esac

    export ZM_KVER ZM_API
    echo "[zeromount] Kernel $ZM_KVER, API generation: $ZM_API"
}

# Verify an injection marker exists in the target file.
# Usage: verify_injection <file> <grep-pattern> <description>
# Exits 1 on failure.
verify_injection() {
    local file="$1"
    local marker="$2"
    local description="$3"

    if ! grep -q "$marker" "$file"; then
        echo "FATAL: $description"
        echo "  Marker '$marker' not found in $file"
        exit 1
    fi
}

# Create a backup and set up a trap to restore on failure.
# Usage: zm_backup <file>
# Sets ZM_BACKUP_FILE for the trap.
zm_backup() {
    local file="$1"
    ZM_BACKUP_FILE="${file}.zm-bak"
    cp "$file" "$ZM_BACKUP_FILE"
    trap 'if [[ -n "${ZM_BACKUP_FILE:-}" && -f "$ZM_BACKUP_FILE" ]]; then
        echo "FATAL: Restoring backup due to injection failure"
        mv "$ZM_BACKUP_FILE" "'"$file"'"
    fi' EXIT
}

# Remove backup on success (call at end of script).
zm_cleanup() {
    if [[ -n "${ZM_BACKUP_FILE:-}" && -f "$ZM_BACKUP_FILE" ]]; then
        rm -f "$ZM_BACKUP_FILE"
    fi
    trap - EXIT
}
