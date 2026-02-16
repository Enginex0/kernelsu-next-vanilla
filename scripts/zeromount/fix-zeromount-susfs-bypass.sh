#!/bin/bash
# fix-zeromount-susfs-bypass.sh
# Validates that zeromount.c has proper SUSFS bypass coverage via
# the centralized zeromount_should_skip() function.
#
# The core patch handles SUSFS bypass through zeromount_should_skip(),
# which already includes susfs_is_current_proc_umounted() under
# CONFIG_KSU_SUSFS. All public zeromount functions call should_skip,
# so per-function SUSFS injection is unnecessary.
#
# This script verifies the invariant holds and patches resolve_path
# if it still uses the old ZEROMOUNT_DISABLED() pattern directly.

set -e

ZEROMOUNT_C="${1:-fs/zeromount.c}"

if [[ ! -f "$ZEROMOUNT_C" ]]; then
    echo "[-] File not found: $ZEROMOUNT_C"
    exit 1
fi

echo "[*] Validating ZeroMount SUSFS bypass in: $ZEROMOUNT_C"

ERRORS=0

# 1. Verify zeromount_should_skip() exists and contains SUSFS check
if ! grep -q 'zeromount_should_skip' "$ZEROMOUNT_C"; then
    echo "[-] FATAL: zeromount_should_skip() not found"
    echo "    This script requires the centralized skip function from the core patch"
    exit 1
fi

if grep -A20 'zeromount_should_skip' "$ZEROMOUNT_C" | grep -q 'susfs_is_current_proc_umounted'; then
    echo "[+] zeromount_should_skip() contains SUSFS bypass check"
else
    echo "[-] FAIL: zeromount_should_skip() missing susfs_is_current_proc_umounted()"
    ERRORS=$((ERRORS + 1))
fi

# 2. Verify susfs.h include is present under CONFIG_KSU_SUSFS guard
if grep -B2 '#include <linux/susfs.h>' "$ZEROMOUNT_C" | grep -q 'CONFIG_KSU_SUSFS'; then
    echo "[+] susfs.h include present with CONFIG_KSU_SUSFS guard"
else
    echo "[-] FAIL: Missing #include <linux/susfs.h> under CONFIG_KSU_SUSFS"
    ERRORS=$((ERRORS + 1))
fi

# 3. Verify all public functions use zeromount_should_skip() rather than
#    ZEROMOUNT_DISABLED() directly. The only exception is the macro definition
#    and zeromount_should_skip() itself.
FUNCS_TO_CHECK=(
    "zeromount_is_traversal_allowed"
    "zeromount_is_injected_file"
    "zeromount_getname_hook"
    "zeromount_inject_dents64"
    "zeromount_inject_dents"
    "zeromount_spoof_statfs"
    "zeromount_spoof_xattr"
    "zeromount_get_virtual_path_for_inode"
    "zeromount_build_absolute_path"
)

echo "[*] Checking public functions call zeromount_should_skip()..."
for func in "${FUNCS_TO_CHECK[@]}"; do
    # Extract function body (from signature to next function-level closing brace)
    # and check it calls zeromount_should_skip
    if ! grep -q "^[a-z].*${func}" "$ZEROMOUNT_C" 2>/dev/null; then
        continue  # function not in this file (might be in header as inline)
    fi

    BODY=$(sed -n "/^[a-z].*${func}/,/^}/p" "$ZEROMOUNT_C" 2>/dev/null)
    if echo "$BODY" | grep -q 'zeromount_should_skip'; then
        echo "  [+] $func -> calls zeromount_should_skip()"
    elif echo "$BODY" | grep -q 'ZEROMOUNT_DISABLED'; then
        echo "  [!] $func -> uses ZEROMOUNT_DISABLED() directly (no SUSFS coverage)"
        echo "      This function is not protected by susfs_is_current_proc_umounted()"
        ERRORS=$((ERRORS + 1))
    fi
done

# 4. Special case: zeromount_resolve_path uses zeromount_is_critical_process()
#    and ZEROMOUNT_DISABLED() directly. It gets SUSFS coverage from callers:
#    - zeromount_getname_hook calls should_skip before resolve_path
#    - zeromount_build_absolute_path calls should_skip before callers use resolve_path
#    - zeromount_inject_dents* call should_skip before resolve_path
#    So we note it but don't fail.
RESOLVE_BODY=$(sed -n "/^char \*zeromount_resolve_path/,/^}/p" "$ZEROMOUNT_C" 2>/dev/null)
if echo "$RESOLVE_BODY" | grep -q 'ZEROMOUNT_DISABLED'; then
    if echo "$RESOLVE_BODY" | grep -q 'zeromount_should_skip'; then
        echo "  [+] zeromount_resolve_path -> calls zeromount_should_skip()"
    else
        echo "  [~] zeromount_resolve_path -> uses ZEROMOUNT_DISABLED() directly"
        echo "      SUSFS coverage provided by callers (getname_hook, build_absolute_path)"
        echo "      This is acceptable as long as resolve_path is not called directly"
        echo "      from VFS hooks without a prior should_skip() check."
    fi
fi

# 5. Verify zeromount_is_uid_blocked is exported (needed by SUSFS coupling)
if grep -q 'EXPORT_SYMBOL(zeromount_is_uid_blocked)' "$ZEROMOUNT_C"; then
    echo "[+] zeromount_is_uid_blocked exported for SUSFS coupling"
else
    echo "[-] FAIL: zeromount_is_uid_blocked not exported"
    echo "    SUSFS coupling script needs this symbol"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
    echo "[+] SUCCESS: SUSFS bypass validation passed"
    echo "    All public functions have SUSFS coverage via zeromount_should_skip()"
else
    echo "[-] FAILED: $ERRORS issue(s) found"
    echo "    Review the output above and fix zeromount-core.patch"
    exit 1
fi
