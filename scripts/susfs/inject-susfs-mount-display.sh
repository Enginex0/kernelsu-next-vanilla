#!/bin/bash
# inject-susfs-mount-display.sh
# Modifies the GKI SUSFS patch file to add zeromount UID exclusion checks
# in the 3 show_* functions (show_vfsmnt, show_mountinfo, show_vfsstat).
#
# NOTE: This operates on a .patch file, not a .c file directly. The sed
# patterns match patch-format lines (starting with +).
#
# Usage: ./inject-susfs-mount-display.sh <SUSFS_KERNEL_PATCHES_DIR>

set -e

SUSFS_DIR="$1"

if [ -z "$SUSFS_DIR" ]; then
    echo "Usage: $0 <SUSFS_KERNEL_PATCHES_DIR>"
    exit 1
fi

# Find the GKI patch file (version-specific name)
GKI_PATCH=$(find "$SUSFS_DIR" -maxdepth 1 -name '50_add_susfs_in_gki-*.patch' -print -quit)

if [ -z "$GKI_PATCH" ] || [ ! -f "$GKI_PATCH" ]; then
    echo "FATAL: no 50_add_susfs_in_gki-*.patch found in $SUSFS_DIR"
    exit 1
fi

echo "=== inject-susfs-mount-display ==="
echo "    Target: $(basename "$GKI_PATCH")"
inject_count=0

# --- 1. Add extern declarations ---
if grep -q 'susfs_is_uid_zeromount_excluded' "$GKI_PATCH"; then
    echo "[=] zeromount extern already present in GKI patch"
else
    echo "[+] Injecting zeromount extern declarations"
    sed -i '/^+extern bool susfs_is_current_ksu_domain(void);/a +#ifdef CONFIG_ZEROMOUNT\n+extern bool susfs_is_uid_zeromount_excluded(uid_t uid);\n+#endif' "$GKI_PATCH"
    ((inject_count++)) || true
fi

# --- 2. Inject zeromount condition into show_* blocks ---
# Upstream pattern (3 show_* functions in proc_namespace.c):
#   +		!susfs_is_current_ksu_domain())
#   +	{
# Fork target:
#   +		!susfs_is_current_ksu_domain()
#   +#ifdef CONFIG_ZEROMOUNT
#   +		&& !susfs_is_uid_zeromount_excluded(current_uid().val)
#   +#endif
#   +		)
#   +	{
#
# The key: split the closing ')' off the ksu_domain line and insert the zeromount guard.
# Only match lines inside CONFIG_KSU_SUSFS_SUS_MOUNT blocks that have the negated check
# with closing paren: !susfs_is_current_ksu_domain())

inline_count=$(grep -c '!susfs_is_uid_zeromount_excluded' "$GKI_PATCH" || true)
if [ "$inline_count" -ge 3 ]; then
    echo "[=] zeromount inline checks already present ($inline_count found)"
else
    echo "[+] Injecting zeromount checks into show_* functions"
    # Match: +		!susfs_is_current_ksu_domain())
    # Only in proc_namespace.c section (preceded by susfs_hide_sus_mnts_for_non_su_procs)
    awk '
    /^\+\t\t!susfs_is_current_ksu_domain\(\)\)$/ {
        # Split: remove closing ) and add zeromount guard before it
        print "+\t\t!susfs_is_current_ksu_domain()"
        print "+#ifdef CONFIG_ZEROMOUNT"
        print "+\t\t&& !susfs_is_uid_zeromount_excluded(current_uid().val)"
        print "+#endif"
        print "+\t\t)"
        next
    }
    { print }
    ' "$GKI_PATCH" > "$GKI_PATCH.tmp" && mv "$GKI_PATCH.tmp" "$GKI_PATCH"
    ((inject_count++)) || true
fi

# Validate: 2 extern declarations + 3 inline uses = 5
count=$(grep -c 'susfs_is_uid_zeromount_excluded' "$GKI_PATCH" || true)
if [ "$count" -lt 5 ]; then
    echo "FATAL: expected at least 5 zeromount references in GKI patch, found $count"
    exit 1
fi

echo "=== Done: $inject_count injections applied ==="
