#!/bin/bash
# Inject sus_proc_net_unix feature into kernel source
# Usage: ./inject_sus_proc_net_unix.sh <kernel_common_dir> <kernelsu_dir>

set -e
COMMON_DIR="$1"
KSU_DIR="$2"

if [ -z "$COMMON_DIR" ] || [ ! -d "$COMMON_DIR" ]; then
    echo "Usage: $0 <kernel_common_dir> <kernelsu_dir>"
    exit 1
fi

cd "$COMMON_DIR"
echo "=== Injecting sus_proc_net_unix into $COMMON_DIR ==="

# 1. Add CMD constant to susfs_def.h
if ! grep -q "CMD_SUSFS_ADD_SUS_PROC_NET_UNIX" include/linux/susfs_def.h 2>/dev/null; then
    sed -i '/CMD_SUSFS_ADD_SUS_MAP/a #define CMD_SUSFS_ADD_SUS_PROC_NET_UNIX 0x60030' include/linux/susfs_def.h
    echo "✓ CMD constant added to susfs_def.h"
fi

# 2. Add struct definitions to susfs.h (insert after st_susfs_sus_map struct block)
if ! grep -q "st_susfs_sus_proc_net_unix" include/linux/susfs.h 2>/dev/null; then
    cat > /tmp/sus_unix_struct.txt << 'STRUCTEOF'

/* sus_proc_net_unix - hide unix socket entries from /proc/net/unix */
#ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX
struct st_susfs_sus_proc_net_unix {
	char                                    socket_name_pattern[SUSFS_MAX_LEN_PATHNAME];
	int                                     err;
};

struct st_susfs_sus_proc_net_unix_list {
	struct list_head                        list;
	char                                    socket_name_pattern[SUSFS_MAX_LEN_PATHNAME];
};
#endif
STRUCTEOF
    # Find line AFTER the #endif that closes st_susfs_sus_map (look for pattern: struct st_susfs_sus_map ... #endif)
    LINE=$(grep -n "st_susfs_sus_map" include/linux/susfs.h | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        # Find the next #endif after st_susfs_sus_map
        ENDIF_LINE=$(tail -n +$LINE include/linux/susfs.h | grep -n "^#endif" | head -1 | cut -d: -f1)
        if [ -n "$ENDIF_LINE" ]; then
            INSERT_LINE=$((LINE + ENDIF_LINE - 1))
            head -n "$INSERT_LINE" include/linux/susfs.h > /tmp/susfs.h.tmp
            cat /tmp/sus_unix_struct.txt >> /tmp/susfs.h.tmp
            tail -n +$((INSERT_LINE + 1)) include/linux/susfs.h >> /tmp/susfs.h.tmp
            mv /tmp/susfs.h.tmp include/linux/susfs.h
            echo "✓ Struct definitions added to susfs.h (after line $INSERT_LINE)"
        else
            echo "⚠ Could not find #endif after st_susfs_sus_map"
        fi
    else
        echo "⚠ Could not find st_susfs_sus_map in susfs.h"
    fi
fi

# 3. Add function declarations to susfs.h
if ! grep -q "susfs_add_sus_proc_net_unix" include/linux/susfs.h 2>/dev/null; then
    cat > /tmp/sus_unix_decl.txt << 'DECLEOF'

/* sus_proc_net_unix */
#ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX
void susfs_add_sus_proc_net_unix(void __user **user_info);
extern bool susfs_is_sus_proc_net_unix(const char *socket_name);
#endif
DECLEOF
    LINE=$(grep -n "void susfs_add_sus_map" include/linux/susfs.h | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        head -n "$LINE" include/linux/susfs.h > /tmp/susfs.h.tmp
        cat /tmp/sus_unix_decl.txt >> /tmp/susfs.h.tmp
        tail -n +$((LINE + 1)) include/linux/susfs.h >> /tmp/susfs.h.tmp
        mv /tmp/susfs.h.tmp include/linux/susfs.h
        echo "✓ Function declarations added to susfs.h"
    fi
fi

# 4. Add implementation to fs/susfs.c
if ! grep -q "sus_proc_net_unix" fs/susfs.c 2>/dev/null; then
    cat >> fs/susfs.c << 'IMPLEOF'

/* sus_proc_net_unix - hide Zygisk sockets from /proc/net/unix */
#ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX
static DEFINE_SPINLOCK(susfs_spin_lock_sus_proc_net_unix);
static LIST_HEAD(LH_SUS_PROC_NET_UNIX);
static const char *sus_unix_builtin[] = {"zn_zygote", "zygiskd", "magiskd", "_magisk", "zygisk_", NULL};

void susfs_add_sus_proc_net_unix(void __user **user_info) {
	struct st_susfs_sus_proc_net_unix info = {0};
	struct st_susfs_sus_proc_net_unix_list *cursor, *new_list;
	if (copy_from_user(&info, (void __user*)*user_info, sizeof(info))) { info.err = -EFAULT; goto out; }
	info.socket_name_pattern[SUSFS_MAX_LEN_PATHNAME - 1] = '\0';
	if (!info.socket_name_pattern[0]) { info.err = -EINVAL; goto out; }
	new_list = kmalloc(sizeof(*new_list), GFP_KERNEL);
	if (!new_list) { info.err = -ENOMEM; goto out; }
	strncpy(new_list->socket_name_pattern, info.socket_name_pattern, SUSFS_MAX_LEN_PATHNAME - 1);
	INIT_LIST_HEAD(&new_list->list);
	spin_lock(&susfs_spin_lock_sus_proc_net_unix);
	list_for_each_entry(cursor, &LH_SUS_PROC_NET_UNIX, list) {
		if (!strcmp(cursor->socket_name_pattern, info.socket_name_pattern)) {
			spin_unlock(&susfs_spin_lock_sus_proc_net_unix); kfree(new_list); info.err = 0; goto out;
		}
	}
	list_add_tail(&new_list->list, &LH_SUS_PROC_NET_UNIX);
	spin_unlock(&susfs_spin_lock_sus_proc_net_unix);
	SUSFS_LOGI("sus_proc_net_unix: added '%s'\n", info.socket_name_pattern);
	info.err = 0;
out:
	copy_to_user(&((struct st_susfs_sus_proc_net_unix __user*)*user_info)->err, &info.err, sizeof(info.err));
}

bool susfs_is_sus_proc_net_unix(const char *name) {
	struct st_susfs_sus_proc_net_unix_list *cursor;
	const char **p;
	if (!name || !*name || unlikely(!susfs_is_current_proc_umounted())) return false;
	for (p = sus_unix_builtin; *p; p++) if (strstr(name, *p)) return true;
	spin_lock(&susfs_spin_lock_sus_proc_net_unix);
	list_for_each_entry(cursor, &LH_SUS_PROC_NET_UNIX, list) {
		if (strstr(name, cursor->socket_name_pattern)) { spin_unlock(&susfs_spin_lock_sus_proc_net_unix); return true; }
	}
	spin_unlock(&susfs_spin_lock_sus_proc_net_unix);
	return false;
}
EXPORT_SYMBOL(susfs_is_sus_proc_net_unix);
#endif
IMPLEOF
    echo "✓ Implementation added to fs/susfs.c"
fi

# 5. Add hook to net/unix/af_unix.c
if ! grep -q "susfs_is_sus_proc_net_unix" net/unix/af_unix.c 2>/dev/null; then
    # Add include at top of file
    sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX\n#include <linux/susfs.h>\n#endif\n' net/unix/af_unix.c

    # Create helper function file
    cat > /tmp/sus_unix_helper.txt << 'HELPEREOF'

#ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX
static bool susfs_should_hide_unix_socket(struct unix_sock *u) {
	char buf[108]; int i, len;
	if (!u || !u->addr) return false;
	len = u->addr->len - sizeof(short);
	if (len <= 1 || len > 107) return false;
	for (i = 1; i < len; i++) buf[i-1] = u->addr->name->sun_path[i] ? u->addr->name->sun_path[i] : '@';
	buf[len-1] = 0;
	return susfs_is_sus_proc_net_unix(buf);
}
#endif

HELPEREOF

    # Insert helper before unix_seq_show
    LINE=$(grep -n "^static int unix_seq_show" net/unix/af_unix.c | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        head -n $((LINE - 1)) net/unix/af_unix.c > /tmp/af_unix.c.tmp
        cat /tmp/sus_unix_helper.txt >> /tmp/af_unix.c.tmp
        tail -n +$LINE net/unix/af_unix.c >> /tmp/af_unix.c.tmp
        mv /tmp/af_unix.c.tmp net/unix/af_unix.c
    fi

    # Add check inside unix_seq_show after unix_state_lock
    sed -i '/unix_state_lock(s);/a \\t\t#ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX\n\t\tif (susfs_should_hide_unix_socket(u)) { unix_state_unlock(s); return 0; }\n\t\t#endif' net/unix/af_unix.c
    echo "✓ Hook added to net/unix/af_unix.c"
fi

# 6. Add command handler to supercalls.c
if [ -n "$KSU_DIR" ] && [ -f "$KSU_DIR/kernel/supercalls.c" ]; then
    SUPERCALLS="$KSU_DIR/kernel/supercalls.c"
    if ! grep -q "CMD_SUSFS_ADD_SUS_PROC_NET_UNIX" "$SUPERCALLS"; then
        # Insert after CMD_SUSFS_ADD_SUS_MAP handler
        sed -i '/CMD_SUSFS_ADD_SUS_MAP/,/return 0;/{/return 0;/a #ifdef CONFIG_KSU_SUSFS_SUS_PROC_NET_UNIX\n        if (cmd == CMD_SUSFS_ADD_SUS_PROC_NET_UNIX) { susfs_add_sus_proc_net_unix(arg); return 0; }\n#endif
        }' "$SUPERCALLS"
        echo "✓ Command handler added to supercalls.c"
    fi
fi

echo "=== sus_proc_net_unix injection complete ==="
