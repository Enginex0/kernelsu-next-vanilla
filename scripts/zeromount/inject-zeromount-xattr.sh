#!/bin/bash
# inject-zeromount-xattr.sh - Inject ZeroMount xattr spoofing hooks into fs/xattr.c
#
# vfs_getxattr() signature varies across versions:
#   5.10: vfs_getxattr(struct dentry *dentry, const char *name, void *value, size_t size)
#   5.15: vfs_getxattr(struct user_namespace *mnt_userns, struct dentry *dentry, ...)
#   6.6:  vfs_getxattr(struct mnt_idmap *idmap, struct dentry *dentry, ...)
#
# On 5.10, the function body opens with `{` then immediately has logic.
# On 5.15+, the function body has `struct inode *inode = ...;` and `int error;`
# before the first executable line. We inject after `int error;` to stay
# after all declarations (C89 compliance).
#
# On 5.10 where there's no `int error;` inside vfs_getxattr, we inject after
# the opening `{` using a compound statement block to isolate the declaration.
#
# In all cases, dentry/name/value/size are valid parameter names.
#
# Usage: ./inject-zeromount-xattr.sh <path-to-xattr.c>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/zeromount-common.sh"

TARGET="${1:-fs/xattr.c}"

echo "[INFO] ZeroMount xattr hook injection"
echo "[INFO] Target: $TARGET"

if [ ! -f "$TARGET" ]; then
    echo "[ERROR] Target file not found: $TARGET"
    exit 1
fi

if grep -q "zeromount_spoof_xattr" "$TARGET"; then
    echo "[INFO] Hooks already present - skipping"
    exit 0
fi

detect_kernel_version "$TARGET"
zm_backup "$TARGET"

echo "[INFO] Injecting include..."
sed -i '/#include <linux\/uaccess.h>/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif' "$TARGET"

verify_injection "$TARGET" '#include <linux/zeromount.h>' "Failed to inject include"
echo "[OK] Include injected"

echo "[INFO] Injecting vfs_getxattr hook..."

# Determine injection strategy:
# Check if vfs_getxattr body has "int error;" (5.15/6.1/6.6) or not (5.10)
# Extract function body -- must match exactly "vfs_getxattr(" not "vfs_getxattr_alloc("
FUNC_BODY=$(sed -n '/^ssize_t$/,/^}/{ /^vfs_getxattr(/,/^}/p }' "$TARGET" 2>/dev/null)
if [ -z "$FUNC_BODY" ]; then
    FUNC_BODY=$(sed -n '/^ssize_t vfs_getxattr(/,/^}/p' "$TARGET" 2>/dev/null)
fi

if echo "$FUNC_BODY" | grep -q $'^\tint error;'; then
    # 5.15/6.1/6.6: inject after "int error;" inside vfs_getxattr
    INJECT_MODE="after_error"
else
    # 5.10: inject after opening brace, use compound block for C89 compliance
    INJECT_MODE="after_brace"
fi

echo "[INFO] Injection mode: $INJECT_MODE"

# awk state machine handles split function signatures (return type on separate line)
awk -v mode="$INJECT_MODE" '
BEGIN { in_vfs_getxattr = 0; injected = 0; held_line = "" }

# Hold "ssize_t" alone on a line to check next line
/^ssize_t$/ && held_line == "" {
    held_line = $0
    next
}

# Process line after held ssize_t
held_line != "" {
    if (/^vfs_getxattr\(/) {
        in_vfs_getxattr = 1
    }
    print held_line
    held_line = ""
}

# Also handle single-line signature: "ssize_t vfs_getxattr("
/^ssize_t vfs_getxattr\(/ { in_vfs_getxattr = 1 }

# 5.10 path: inject after opening brace using compound block
in_vfs_getxattr && mode == "after_brace" && /^\{$/ && !injected {
    print
    print "#ifdef CONFIG_ZEROMOUNT"
    print "\t{"
    print "\t\tssize_t zm_ret = zeromount_spoof_xattr(dentry, name, value, size);"
    print "\t\tif (zm_ret != -EOPNOTSUPP)"
    print "\t\t\treturn zm_ret;"
    print "\t}"
    print "#endif"
    injected = 1
    in_vfs_getxattr = 0
    next
}

# 5.15/6.1/6.6 path: inject after "int error;" line
in_vfs_getxattr && mode == "after_error" && /^\tint error;$/ && !injected {
    print
    print ""
    print "#ifdef CONFIG_ZEROMOUNT"
    print "\t{"
    print "\t\tssize_t zm_ret = zeromount_spoof_xattr(dentry, name, value, size);"
    print "\t\tif (zm_ret != -EOPNOTSUPP)"
    print "\t\t\treturn zm_ret;"
    print "\t}"
    print "#endif"
    injected = 1
    in_vfs_getxattr = 0
    next
}

{ print }

END {
    if (held_line != "") print held_line
    if (!injected) {
        print "INJECTION_FAILED: vfs_getxattr" > "/dev/stderr"
        exit 1
    }
}
' "$TARGET" > "${TARGET}.tmp"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to inject vfs_getxattr hook"
    exit 1
fi
mv "${TARGET}.tmp" "$TARGET"

verify_injection "$TARGET" 'zeromount_spoof_xattr' "Failed to inject vfs_getxattr hook"
echo "[OK] vfs_getxattr hook injected"

zm_cleanup

echo "[SUCCESS] ZeroMount xattr hooks injected ($ZM_API variant)"
echo "  - Include: <linux/zeromount.h>"
echo "  - Hook: vfs_getxattr() -> zeromount_spoof_xattr(dentry, name, value, size)"
