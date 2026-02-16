#!/bin/bash
# inject-zeromount-stat.sh - Inject ZeroMount hooks into fs/stat.c
#
# Hooks vfs_statx() to intercept relative path stat operations for injected directories.
# When a relative path resolves to a ZeroMount rule, redirect stat to the source file.
#
# Kernel version differences:
#   5.4:      int vfs_statx(...)      — exported, non-static, error = -EINVAL
#   5.10:     static int vfs_statx(int dfd, const char __user *filename, ...)
#   6.6:      static int vfs_statx(int dfd, struct filename *filename, ...)
# The hook adapts to whichever signature is present.
#
# Usage: ./inject-zeromount-stat.sh <path-to-stat.c>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/zeromount-common.sh"

TARGET="${1:-fs/stat.c}"
MARKER="CONFIG_ZEROMOUNT"

if [[ ! -f "$TARGET" ]]; then
    echo "Error: File not found: $TARGET"
    exit 1
fi

echo "Injecting ZeroMount stat hooks into: $TARGET"

if grep -q "$MARKER" "$TARGET"; then
    echo "File already contains ZeroMount hooks ($MARKER found). Skipping."
    exit 0
fi

detect_kernel_version "$TARGET"
zm_backup "$TARGET"

if ! grep -q '#include <linux/uaccess.h>' "$TARGET"; then
    echo "Error: Cannot find #include <linux/uaccess.h>"
    exit 1
fi

if ! grep -q 'int vfs_statx' "$TARGET"; then
    echo "Error: Cannot find 'int vfs_statx' function"
    exit 1
fi

echo "  [1/2] Injecting zeromount.h include..."
sed -i '/#include <linux\/uaccess.h>/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif' "$TARGET"

echo "  [2/2] Injecting hook into vfs_statx..."

# Detect which vfs_statx signature we have
if grep -qE '(static )?int vfs_statx\(int dfd, const char __user \*filename' "$TARGET"; then
    # 5.4/5.10: filename is a raw user pointer
    FILENAME_IS_USER_PTR=1
elif grep -qE '(static )?int vfs_statx\(int dfd, struct filename \*filename' "$TARGET"; then
    # 5.15+/6.x: filename is a struct filename * (already resolved)
    FILENAME_IS_USER_PTR=0
else
    echo "Error: Cannot determine vfs_statx signature variant"
    exit 1
fi

if [[ "$FILENAME_IS_USER_PTR" -eq 1 ]]; then
    # 5.10: inject helper that copies from userspace
    sed -i '/^\(static \)\{0,1\}int vfs_statx(/i\
#ifdef CONFIG_ZEROMOUNT\
/* ZeroMount stat hook for relative path intercept (5.10 user-ptr variant) */\
static inline int zeromount_stat_hook(int dfd, const char __user *filename,\
                                      struct kstat *stat, u32 request_mask,\
                                      int flags) {\
    if (filename) {\
        char kname[NAME_MAX + 1];\
        long copied = strncpy_from_user(kname, filename, sizeof(kname));\
        if (copied > 0 && kname[0] != '"'"'/'"'"') {\
            char *abs_path = zeromount_build_absolute_path(dfd, kname);\
            if (abs_path) {\
                char *resolved = zeromount_resolve_path(abs_path);\
                if (resolved) {\
                    struct path zm_path;\
                    int zm_ret = kern_path(resolved,\
                        (flags & AT_SYMLINK_NOFOLLOW) ? 0 : LOOKUP_FOLLOW, &zm_path);\
                    kfree(resolved);\
                    kfree(abs_path);\
                    if (zm_ret == 0) {\
                        zm_ret = vfs_getattr(&zm_path, stat, request_mask,\
                            (flags & AT_SYMLINK_NOFOLLOW) ? AT_SYMLINK_NOFOLLOW : 0);\
                        path_put(&zm_path);\
                        return zm_ret;\
                    }\
                } else {\
                    kfree(abs_path);\
                }\
            }\
        }\
    }\
    return -ENOENT;\
}\
#endif' "$TARGET"
else
    # 6.6: filename is struct filename *, use filename->name directly
    sed -i '/^\(static \)\{0,1\}int vfs_statx(/i\
#ifdef CONFIG_ZEROMOUNT\
/* ZeroMount stat hook for relative path intercept (6.x filename-struct variant) */\
static inline int zeromount_stat_hook(int dfd, struct filename *filename,\
                                      struct kstat *stat, u32 request_mask,\
                                      int flags) {\
    if (filename && filename->name && filename->name[0] != '"'"'/'"'"') {\
        char *abs_path = zeromount_build_absolute_path(dfd, filename->name);\
        if (abs_path) {\
            char *resolved = zeromount_resolve_path(abs_path);\
            if (resolved) {\
                struct path zm_path;\
                int zm_ret = kern_path(resolved,\
                    (flags & AT_SYMLINK_NOFOLLOW) ? 0 : LOOKUP_FOLLOW, &zm_path);\
                kfree(resolved);\
                kfree(abs_path);\
                if (zm_ret == 0) {\
                    zm_ret = vfs_getattr(&zm_path, stat, request_mask,\
                        (flags & AT_SYMLINK_NOFOLLOW) ? AT_SYMLINK_NOFOLLOW : 0);\
                    path_put(&zm_path);\
                    return zm_ret;\
                }\
            } else {\
                kfree(abs_path);\
            }\
        }\
    }\
    return -ENOENT;\
}\
#endif' "$TARGET"
fi

# Inject the call into vfs_statx after variable declarations
awk '
BEGIN { state = 0; injected = 0 }

# 5.4: vfs_statx is non-static (exported); 5.10+: static
/^(static )?int vfs_statx\(/ { state = 1 }

# 5.4: int error = -EINVAL; 5.10+: int error;
state == 1 && /^[[:space:]]*int error[; =]/ && !injected {
    print
    print ""
    print "#ifdef CONFIG_ZEROMOUNT"
    print "\t/* Try ZeroMount hook for relative paths */"
    print "\tif (filename && dfd != AT_FDCWD) {"
    print "\t\tint zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);"
    print "\t\tif (zm_ret != -ENOENT)"
    print "\t\t\treturn zm_ret;"
    print "\t}"
    print "#endif"
    print ""
    injected = 1
    next
}

state == 1 && /^}$/ { state = 0 }

{ print }

END {
    if (!injected) {
        print "INJECTION_FAILED: vfs_statx" > "/dev/stderr"
        exit 1
    }
}
' "$TARGET" > "${TARGET}.tmp"

if [ $? -ne 0 ]; then
    echo "Error: awk injection failed"
    exit 1
fi

mv "${TARGET}.tmp" "$TARGET"

echo ""
echo "Verifying injection..."

verify_injection "$TARGET" '#include <linux/zeromount.h>' "zeromount.h include not found"
verify_injection "$TARGET" 'zeromount_stat_hook' "zeromount_stat_hook function not found"
verify_injection "$TARGET" 'zeromount_resolve_path' "zeromount_resolve_path call not found"

zm_cleanup
echo "ZeroMount stat hooks injection complete ($ZM_API variant)."
