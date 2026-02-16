#!/bin/bash
# inject-zeromount-core.sh - Register ZeroMount in Kconfig/Makefile and install core source files
#
# Replaces the context-sensitive zeromount-core.patch hunks for fs/Kconfig and fs/Makefile
# with scripted insertion that works across 5.10, 5.15, 6.1, 6.6 regardless of line numbers.
# New files (zeromount.c, zeromount.h) are copied directly since they have no context deps.
#
# Usage: ./inject-zeromount-core.sh <kernel-source-root>

set -e

KERNEL_ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$KERNEL_ROOT/fs/Kconfig" ]; then
    echo "Error: $KERNEL_ROOT/fs/Kconfig not found — is this a kernel source tree?"
    exit 1
fi

if [ ! -f "$KERNEL_ROOT/fs/Makefile" ]; then
    echo "Error: $KERNEL_ROOT/fs/Makefile not found"
    exit 1
fi

echo "Injecting ZeroMount core into: $KERNEL_ROOT"

# --- 1. fs/Kconfig: add CONFIG_ZEROMOUNT before final endmenu ---

KCONFIG="$KERNEL_ROOT/fs/Kconfig"

if grep -q 'config ZEROMOUNT' "$KCONFIG"; then
    echo "  [1/4] Kconfig already has ZEROMOUNT. Skipping."
else
    echo "  [1/4] Adding CONFIG_ZEROMOUNT to fs/Kconfig..."

    # Insert the config block before the last 'endmenu' in fs/Kconfig.
    # tac/reverse approach: find the LAST endmenu, insert before it.
    if ! grep -q '^endmenu' "$KCONFIG"; then
        echo "Error: No 'endmenu' found in fs/Kconfig"
        exit 1
    fi

    # Use sed to insert before the last endmenu
    # Get the line number of the last endmenu
    LAST_ENDMENU=$(grep -n '^endmenu' "$KCONFIG" | tail -1 | cut -d: -f1)

    sed -i "${LAST_ENDMENU}i\\
\\
config ZEROMOUNT\\
\\tbool \"ZeroMount Path Redirection Subsystem\"\\
\\tdefault y\\
\\thelp\\
\\t  ZeroMount allows path redirection and virtual file injection\\
\\t  without mounting filesystems. Useful for systemless modifications." "$KCONFIG"

    if ! grep -q 'config ZEROMOUNT' "$KCONFIG"; then
        echo "Error: Failed to inject ZEROMOUNT into Kconfig"
        exit 1
    fi
fi

# --- 2. fs/Makefile: append zeromount.o build rule ---

MAKEFILE="$KERNEL_ROOT/fs/Makefile"

if grep -q 'CONFIG_ZEROMOUNT' "$MAKEFILE"; then
    echo "  [2/4] Makefile already has CONFIG_ZEROMOUNT. Skipping."
else
    echo "  [2/4] Adding zeromount.o to fs/Makefile..."

    # Append to end — no context dependency at all
    echo 'obj-$(CONFIG_ZEROMOUNT) += zeromount.o' >> "$MAKEFILE"

    if ! grep -q 'CONFIG_ZEROMOUNT' "$MAKEFILE"; then
        echo "Error: Failed to add zeromount.o to Makefile"
        exit 1
    fi
fi

# --- 3. fs/zeromount.c: copy core implementation ---

ZEROMOUNT_C="$KERNEL_ROOT/fs/zeromount.c"
ZEROMOUNT_C_SRC="$SCRIPT_DIR/src/zeromount.c"

if [ -f "$ZEROMOUNT_C" ]; then
    echo "  [3/4] fs/zeromount.c already exists. Skipping."
else
    echo "  [3/4] Installing fs/zeromount.c..."
    if [ ! -f "$ZEROMOUNT_C_SRC" ]; then
        echo "Error: Source file not found: $ZEROMOUNT_C_SRC"
        exit 1
    fi
    cp "$ZEROMOUNT_C_SRC" "$ZEROMOUNT_C"
fi

# --- 4. include/linux/zeromount.h: copy header ---

ZEROMOUNT_H="$KERNEL_ROOT/include/linux/zeromount.h"
ZEROMOUNT_H_SRC="$SCRIPT_DIR/src/zeromount.h"

if [ -f "$ZEROMOUNT_H" ]; then
    echo "  [4/4] include/linux/zeromount.h already exists. Skipping."
else
    echo "  [4/4] Installing include/linux/zeromount.h..."
    if [ ! -f "$ZEROMOUNT_H_SRC" ]; then
        echo "Error: Source file not found: $ZEROMOUNT_H_SRC"
        exit 1
    fi
    cp "$ZEROMOUNT_H_SRC" "$ZEROMOUNT_H"
fi

echo "ZeroMount core injection complete."
