#!/system/bin/sh
# Performance Tuning - Boot Service
# BFQ I/O scheduler + Memory optimizations

MODDIR=${0%/*}
LOGFILE="$MODDIR/tuning.log"
LOG_MAX_SIZE=102400  # 100KB

SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

rotate_log() {
    if [ -f "$LOGFILE" ]; then
        local size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
            mv "$LOGFILE" "${LOGFILE}.old" 2>/dev/null
        fi
    fi
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    rotate_log
    if ! echo "$msg" >> "$LOGFILE" 2>/dev/null; then
        log_logcat "$msg"
    fi
}

log_logcat() {
    /system/bin/log -t "PerfTuning" "$1" 2>/dev/null || true
}

write_tunable() {
    local path="$1"
    local value="$2"
    local name="$3"

    if [ ! -f "$path" ]; then
        log "[SKIP] $name - path does not exist: $path"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return 1
    fi

    local stderr
    stderr=$(echo "$value" 2>&1 > "$path")
    local rc=$?

    if [ $rc -eq 0 ]; then
        log "[SUCCESS] $name=$value"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        return 0
    else
        if echo "$stderr" | grep -qE "Permission denied|Operation not permitted"; then
            log "[FAIL] $name=$value - SELinux/permission denied"
        else
            log "[FAIL] $name=$value - write failed (read-only or invalid)"
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

tune_bfq() {
    local block_dev="$1"
    local iosched_dir="/sys/block/$block_dev/queue/iosched"
    local scheduler_file="/sys/block/$block_dev/queue/scheduler"

    if [ ! -d "/sys/block/$block_dev" ]; then
        return 1
    fi

    if [ ! -f "$scheduler_file" ]; then
        log "[SKIP] $block_dev - no scheduler file"
        return 1
    fi

    # Set BFQ scheduler if available
    if grep -q 'bfq' "$scheduler_file" 2>/dev/null; then
        if ! grep -q '\[bfq\]' "$scheduler_file" 2>/dev/null; then
            echo bfq > "$scheduler_file" 2>/dev/null
            if grep -q '\[bfq\]' "$scheduler_file" 2>/dev/null; then
                log "[SUCCESS] $block_dev scheduler=bfq"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                log "[FAIL] $block_dev - could not set BFQ"
                return 1
            fi
        fi
    else
        log "[SKIP] $block_dev - BFQ not available"
        return 1
    fi

    if [ ! -d "$iosched_dir" ]; then
        log "[SKIP] $block_dev - iosched directory missing"
        return 1
    fi

    log "[INFO] Tuning BFQ on $block_dev"

    write_tunable "$iosched_dir/slice_idle" "0" "bfq/$block_dev/slice_idle"
    write_tunable "$iosched_dir/fifo_expire_sync" "80" "bfq/$block_dev/fifo_expire_sync"
    write_tunable "$iosched_dir/fifo_expire_async" "150" "bfq/$block_dev/fifo_expire_async"
    write_tunable "$iosched_dir/back_seek_max" "32768" "bfq/$block_dev/back_seek_max"
    write_tunable "$iosched_dir/back_seek_penalty" "1" "bfq/$block_dev/back_seek_penalty"

    return 0
}

tune_memory() {
    local vm_dir="/proc/sys/vm"

    if [ ! -d "$vm_dir" ]; then
        log "[FAIL] /proc/sys/vm does not exist"
        return 1
    fi

    log "[INFO] Applying memory tuning"

    write_tunable "$vm_dir/swappiness" "100" "vm/swappiness"
    write_tunable "$vm_dir/vfs_cache_pressure" "50" "vm/vfs_cache_pressure"
    write_tunable "$vm_dir/page-cluster" "0" "vm/page-cluster"
    write_tunable "$vm_dir/dirty_ratio" "30" "vm/dirty_ratio"
    write_tunable "$vm_dir/dirty_background_ratio" "5" "vm/dirty_background_ratio"

    return 0
}

main() {
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null

    log "=========================================="
    log "[START] Performance Tuning Module v1.2.0"
    log "=========================================="

    local bfq_tuned=0

    for block_dev in sda sdb sdc nvme0n1 mmcblk0 mmcblk1; do
        if tune_bfq "$block_dev"; then
            bfq_tuned=$((bfq_tuned + 1))
        fi
    done

    if [ "$bfq_tuned" -eq 0 ]; then
        log "[WARN] No block devices with BFQ found"
    else
        log "[INFO] BFQ tuned on $bfq_tuned device(s)"
    fi

    tune_memory

    log "[END] Performance Tuning completed"
    log "[SUMMARY] success=$SUCCESS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
    log ""
}

main

exit 0
