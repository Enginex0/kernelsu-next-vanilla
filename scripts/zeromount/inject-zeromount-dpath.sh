#!/bin/bash
# inject-zeromount-dpath.sh - Inject ZeroMount hooks into fs/d_path.c
# Part of ZeroMount VFS-level path redirection subsystem
#
# Kernel version differences:
#   5.10: d_path has local vars: char *res, struct path root, int error
#   6.6:  d_path uses DECLARE_BUFFER(b, buf, buflen), no int error
# The hook adapts to whichever local variable structure is present.
#
# Usage: ./inject-zeromount-dpath.sh <path-to-d_path.c>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/zeromount-common.sh"

TARGET="${1:-fs/d_path.c}"
MARKER="CONFIG_ZEROMOUNT"

if [[ ! -f "$TARGET" ]]; then
    echo "Error: File not found: $TARGET"
    exit 1
fi

echo "Injecting ZeroMount hooks into: $TARGET"

if grep -q "$MARKER" "$TARGET"; then
    echo "File already contains ZeroMount hooks ($MARKER found). Skipping."
    exit 0
fi

detect_kernel_version "$TARGET"
zm_backup "$TARGET"

inject_include() {
    echo "  [1/2] Injecting zeromount.h include..."
    sed -i '/#include "mount.h"/a\
\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif' "$TARGET"

    verify_injection "$TARGET" "zeromount.h" "Failed to inject include directive"
}

inject_dpath_hook() {
    echo "  [2/2] Injecting d_path() virtual path spoofing hook..."

    # Determine which anchor to use for injection inside d_path
    if grep -q $'^\tint error;' "$TARGET" && grep -q 'char \*res = buf + buflen' "$TARGET"; then
        # 5.10: anchor on "int error;" -- use res-based path construction
        awk '
        /^char \*d_path\(const struct path \*path, char \*buf, int buflen\)$/ {
            in_dpath = 1
        }
        in_dpath && /^\tint error;$/ {
            print $0
            print ""
            print "#ifdef CONFIG_ZEROMOUNT"
            print "\tif (path->dentry && d_backing_inode(path->dentry)) {"
            print "\t\tchar *v_path = zeromount_get_virtual_path_for_inode(d_backing_inode(path->dentry));"
            print ""
            print "\t\tif (v_path) {"
            print "\t\t\tint len = strlen(v_path);"
            print "\t\t\tif (buflen < len + 1) {"
            print "\t\t\t\tkfree(v_path);"
            print "\t\t\t\treturn ERR_PTR(-ENAMETOOLONG);"
            print "\t\t\t}"
            print "\t\t\t*--res = '"'"'\\0'"'"';"
            print "\t\t\tres -= len;"
            print "\t\t\tmemcpy(res, v_path, len);"
            print ""
            print "\t\t\tkfree(v_path);"
            print "\t\t\treturn res;"
            print "\t\t}"
            print "\t}"
            print "#endif"
            print ""
            in_dpath = 0
            next
        }
        { print }
        ' "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
    elif grep -q 'DECLARE_BUFFER' "$TARGET"; then
        # 6.6: anchor on "struct path root;" -- write into buf directly
        awk '
        /^char \*d_path\(const struct path \*path, char \*buf, int buflen\)$/ {
            in_dpath = 1
        }
        in_dpath && /^\tstruct path root;$/ {
            print $0
            print ""
            print "#ifdef CONFIG_ZEROMOUNT"
            print "\tif (path->dentry && d_backing_inode(path->dentry)) {"
            print "\t\tchar *v_path = zeromount_get_virtual_path_for_inode(d_backing_inode(path->dentry));"
            print ""
            print "\t\tif (v_path) {"
            print "\t\t\tint len = strlen(v_path);"
            print "\t\t\tif (buflen < len + 1) {"
            print "\t\t\t\tkfree(v_path);"
            print "\t\t\t\treturn ERR_PTR(-ENAMETOOLONG);"
            print "\t\t\t}"
            print "\t\t\tmemcpy(buf, v_path, len);"
            print "\t\t\tbuf[len] = '"'"'\\0'"'"';"
            print ""
            print "\t\t\tkfree(v_path);"
            print "\t\t\treturn buf;"
            print "\t\t}"
            print "\t}"
            print "#endif"
            print ""
            in_dpath = 0
            next
        }
        { print }
        ' "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
    else
        echo "Error: Cannot determine d_path local variable structure"
        exit 1
    fi

    verify_injection "$TARGET" "zeromount_get_virtual_path_for_inode" "Failed to inject d_path() hook"
}

inject_include
inject_dpath_hook

zm_cleanup
echo "ZeroMount d_path.c hooks injected successfully ($ZM_API variant)."
