# Performance Tuning Module

A Magisk/KernelSU module that applies BFQ I/O scheduler tuning and memory optimizations at boot for improved system responsiveness.

## Features

### BFQ I/O Scheduler Tuning
Optimizes the BFQ (Budget Fair Queueing) I/O scheduler for low-latency workloads:

| Parameter | Value | Effect |
|-----------|-------|--------|
| slice_idle | 0 | Disables idling between I/O slices for faster throughput |
| fifo_expire_sync | 80ms | Reduces synchronous request expiration for quicker response |
| fifo_expire_async | 150ms | Balances async I/O expiration |
| back_seek_max | 32768 | Increases backward seek allowance |
| back_seek_penalty | 1 | Removes penalty for backward seeks |

### Memory Optimizations

| Parameter | Value | Effect |
|-----------|-------|--------|
| swappiness | 100 | Aggressive ZRAM usage for better memory management |
| vfs_cache_pressure | 50 | Retains inode/dentry caches longer |
| page-cluster | 0 | Single-page ZRAM reads for lower latency |
| dirty_ratio | 30 | Allows 30% of memory for dirty pages before forced writeback |
| dirty_background_ratio | 5 | Background writeback starts at 5% dirty memory |

## Installation

1. Download the ZIP file
2. Flash via Magisk Manager, KernelSU Manager, or recovery
3. Reboot

## Requirements

- Magisk v20.4+ or KernelSU
- Kernel with BFQ scheduler compiled in (for I/O tuning)
- ZRAM configured (for optimal swappiness benefits)

## Logs

The module logs its activity to:
```
/data/local/tmp/perf_tuning.log
```

Check this file to verify which tunables were applied successfully.

## Uninstallation

Remove the module via Magisk/KernelSU Manager, or delete:
```
/data/adb/modules/perf_tuning
```

## Compatibility

- Targets block devices: sda, sdb, sdc, nvme0n1, mmcblk0, mmcblk1
- Works with any kernel that has BFQ enabled
- Memory tunings apply universally

## Version

- Version: 1.0.0
- Author: KernelSU-Next
