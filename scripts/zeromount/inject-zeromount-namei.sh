#!/bin/bash
# inject-zeromount-namei.sh - Inject ZeroMount hooks into fs/namei.c
# Part of ZeroMount VFS-level path redirection subsystem
#
# Usage: ./inject-zeromount-namei.sh <path-to-namei.c>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=zeromount-common.sh
source "$SCRIPT_DIR/zeromount-common.sh"

TARGET="${1:-fs/namei.c}"
MARKER="CONFIG_ZEROMOUNT"

if [[ ! -f "$TARGET" ]]; then
    echo "Error: File not found: $TARGET"
    exit 1
fi

detect_kernel_version "$TARGET"

echo "Injecting ZeroMount hooks into: $TARGET"

if grep -q "$MARKER" "$TARGET"; then
    echo "File already contains ZeroMount hooks ($MARKER found). Skipping."
    exit 0
fi

zm_backup "$TARGET"

inject_include() {
    echo "  [1/4] Injecting zeromount.h include..."
    sed -i '/#include "mount.h"/a\
\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif' "$TARGET"

    verify_injection "$TARGET" "zeromount.h" "Failed to inject include directive"
}

inject_getname_hook() {
    echo "  [2/4] Injecting getname_flags() hook..."

    sed -i '/audit_getname(result);/{
N
/\n[[:space:]]*return result;/s/audit_getname(result);/audit_getname(result);\
\
#ifdef CONFIG_ZEROMOUNT\
	if (!IS_ERR(result)) {\
		result = zeromount_getname_hook(result);\
	}\
#endif\
/
}' "$TARGET"

    verify_injection "$TARGET" "zeromount_getname_hook" "Failed to inject getname_flags() hook"
}

inject_generic_permission_hook() {
    echo "  [3/4] Injecting generic_permission() hook..."

    # Match any signature variant:
    #   5.10:     int generic_permission(struct inode *inode, int mask)
    #   5.15/6.1: int generic_permission(struct user_namespace *mnt_userns, struct inode *inode, int mask)
    #   6.6:      int generic_permission(struct mnt_idmap *idmap, struct inode *inode, int mask)
    awk '
BEGIN { state = 0; injected = 0 }

/^int generic_permission\(/ { state = 1 }

state == 1 && /^[[:space:]]*int ret;/ && !injected {
    print
    print ""
    print "#ifdef CONFIG_ZEROMOUNT"
    print "\tif (zeromount_is_injected_file(inode)) {"
    print "\t\tif (mask & MAY_WRITE)"
    print "\t\t\treturn -EACCES;"
    print "\t\treturn 0;"
    print "\t}"
    print ""
    print "\tif (S_ISDIR(inode->i_mode) && zeromount_is_traversal_allowed(inode, mask)) {"
    print "\t\treturn 0;"
    print "\t}"
    print "#endif"
    injected = 1
    next
}

state == 1 && /^}$/ { state = 0 }

{ print }

END {
    if (!injected) {
        print "INJECTION_FAILED: generic_permission" > "/dev/stderr"
        exit 1
    }
}
' "$TARGET" > "${TARGET}.tmp"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to inject generic_permission() hook"
        rm -f "${TARGET}.tmp"
        exit 1
    fi
    mv "${TARGET}.tmp" "$TARGET"

    verify_injection "$TARGET" "zeromount_is_injected_file" "Failed to inject generic_permission() hook"
}

inject_inode_permission_hook() {
    echo "  [4/4] Injecting inode_permission() hook..."

    # Match any signature variant:
    #   5.10:     int inode_permission(struct inode *inode, int mask)
    #   5.15/6.1: int inode_permission(struct user_namespace *mnt_userns, struct inode *inode, int mask)
    #   6.6:      int inode_permission(struct mnt_idmap *idmap, struct inode *inode, int mask)
    awk '
BEGIN { state = 0; injected = 0 }

/^int inode_permission\(/ { state = 1 }

state == 1 && /^[[:space:]]*int retval;/ && !injected {
    print
    print ""
    print "#ifdef CONFIG_ZEROMOUNT"
    print "\tif (zeromount_is_injected_file(inode)) {"
    print "\t\tif (mask & MAY_WRITE)"
    print "\t\t\treturn -EACCES;"
    print "\t\treturn 0;"
    print "\t}"
    print ""
    print "\tif (S_ISDIR(inode->i_mode) && zeromount_is_traversal_allowed(inode, mask)) {"
    print "\t\treturn 0;"
    print "\t}"
    print "#endif"
    injected = 1
    next
}

state == 1 && /^}$/ { state = 0 }

{ print }

END {
    if (!injected) {
        print "INJECTION_FAILED: inode_permission" > "/dev/stderr"
        exit 1
    }
}
' "$TARGET" > "${TARGET}.tmp"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to inject inode_permission() hook"
        rm -f "${TARGET}.tmp"
        exit 1
    fi
    mv "${TARGET}.tmp" "$TARGET"

    verify_injection "$TARGET" "zeromount_is_injected_file" "Failed to inject inode_permission() hook"
}

inject_include
inject_getname_hook
inject_generic_permission_hook
inject_inode_permission_hook

zm_cleanup
echo "ZeroMount namei.c hooks injected successfully."
