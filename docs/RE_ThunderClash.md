# ThunderClash Next Gen v1.41 - Reverse Engineering Intelligence Report

**Module:** ThunderClash Next Gen
**Version:** v1.41-release (versionCode 20)
**Author:** kaminarich
**Analysis Date:** 2026-01-23
**Target Platform:** Android (Magisk/KernelSU module)

---

## Executive Summary

ThunderClash is a performance tuning Magisk module with:
- **Three power profiles** (Powersave, Balance, Performance)
- **Game detection daemon** (Rust binary) for automatic mode switching
- **Rendering mode toggles** (SkiaGL, Vulkan)
- **Color boost** via SurfaceFlinger
- **Memory management** (RAM cleaning, ZRAM reset)
- **Web UI** for configuration via KernelSU WebUI

The core mode binaries are compiled native code (ARM64 NDK), obfuscated and stripped. The main `thunder` daemon is a UPX-packed Rust binary.

---

## File Structure

```
thunderclash/
├── META-INF/com/google/android/
│   ├── update-binary          # Magisk installer (612 B)
│   └── updater-script         # Placeholder
├── Toast.apk                  # Notification toast app (113 KB)
├── action.sh                  # RAM cleaner script (1.8 KB)
├── compress.sh                # Memory compression/reclaim (6.5 KB)
├── gamelist.txt               # Games to boost (package names)
├── install.sh                 # Installation logic (3.3 KB)
├── module.prop                # Module metadata
├── priority.sh                # Foreground app priority booster (1.1 KB)
├── service.sh                 # Boot service (4.4 KB)
├── soc.sh                     # SoC detection (1.5 KB)
├── thunder                    # Main daemon (UPX packed Rust, 170 KB)
├── uninstall.sh               # Cleanup script
├── verify.sh                  # SHA256 integrity verification
├── whitelist.txt              # Apps protected from RAM cleaning
├── webroot/                   # KernelSU WebUI
│   ├── index.html
│   ├── info.html
│   ├── script.js
│   ├── style.css
│   └── assets/bg.png
└── mode/
    ├── normal                 # Balance mode (28 KB, ELF ARM64)
    ├── perf                   # Performance mode (25 KB, ELF ARM64)
    ├── perf2                  # Alt performance mode (25 KB, ELF ARM64)
    ├── powersave              # Powersave mode (22 KB, ELF ARM64)
    ├── reset                  # Color reset (shell script, 583 B)
    ├── color                  # Color boost (13 KB, ELF ARM64)
    ├── skiagl                 # SkiaGL renderer (12 KB, ELF ARM64)
    └── vulkan                 # Vulkan renderer (12 KB, ELF ARM64)
```

---

## Key Components Analysis

### 1. service.sh - Boot Service

```bash
# Key paths and techniques:

# sysfs paths for kernel tracing cleanup
/sys/kernel/tracing/options/overwrite
/sys/kernel/tracing/options/record-tgid
/sys/kernel/tracing/instances/mmstat/trace
/sys/kernel/tracing/trace
/sys/kernel/tracing/per_cpu/*/trace
/sys/kernel/tracing/tracing_on
/sys/kernel/tracing/buffer_size_kb

# MediaTek GPU fast DVFS paths
/sys/kernel/ged/hal/fast_dvfs
/sys/kernel/ged/hal/fdvfs
/sys/kernel/ged/hal/enable_fdvfs
/sys/kernel/ged/hal/boost_gpu_enable

# Texture filtering control (MediaTek)
/sys/kernel/ged/gpu_tuner/custom_hint_set
# Writes: "anisotropic_disable", "trilinear_disable"
```

**Techniques:**
- Disables kernel tracing to reduce overhead
- Enables MediaTek fast DVFS for GPU
- Disables anisotropic/trilinear filtering for performance
- Adaptive heap sizing based on RAM (6GB/8GB/12GB tiers)

**Heap Configuration:**
| RAM      | heapgrowthlimit | heapsize | heapminfree | heapmaxfree |
|----------|-----------------|----------|-------------|-------------|
| 12GB+    | 1024m           | 1536m    | 16m         | 32m         |
| 8GB      | 768m            | 1024m    | 12m         | 24m         |
| 6GB      | 512m            | 768m     | 8m          | 16m         |

**System Properties Set:**
```bash
resetprop debug.cpurend.vsync false
resetprop debug.hwui.disable_vsync true
resetprop debug.sf.disable_client_composition_cache 1
resetprop debug.hwui.skia_atrace_enabled false
resetprop ro.config.enable.hw_accel true
resetprop debug.hwui.render_dirty_regions false
resetprop dalvik.vm.systemuicompilerfilter speed
resetprop dalvik.vm.systemservercompilerfilter speed
resetprop ro.config.low_ram false
```

**Animation Scale Reduction:**
```bash
settings put global window_animation_scale 0.8
settings put global transition_animation_scale 0.8
settings put global animator_duration_scale 0.8
```

---

### 2. soc.sh - SoC Detection

```bash
# Detection order (fallback chain):
1. ro.soc.model
2. ro.soc.manufacturer
3. ro.mediatek.platform
4. ro.board.platform
5. /proc/cpuinfo Hardware line

# SoC ID mapping:
0 = Unknown
1 = MediaTek (mt*, mediatek)
2 = Qualcomm (qcom, sm*, sdm*, msm*, snapdragon)
3 = Samsung Exynos (exynos, erd*, s5e*, universal)
4 = Unisoc (ums*, sp*)
5 = Google Tensor (gs*)
```

Output stored in: `/data/local/tmp/thunder_default/soc`

---

### 3. action.sh - RAM Cleaner

```bash
# Technique:
1. Temporarily lower swappiness to 10
2. Load whitelist.txt and gamelist.txt exclusions
3. Force-stop all user apps (pm list packages -3) except exclusions
4. Compact memory: echo 1 > /proc/sys/vm/compact_memory
5. Drop caches: echo 3 > /proc/sys/vm/drop_caches
6. Reset ZRAM:
   - swapoff /dev/block/zram0
   - echo 1 > /sys/block/zram0/reset
   - Restore disksize from original
   - mkswap + swapon
7. Restore original swappiness
8. Run compress.sh for additional reclaim
```

---

### 4. compress.sh - Advanced Memory Reclaim

```bash
# Memory control paths detected:
/sys/fs/cgroup/memory/memory.swappiness
/dev/memcg

# Reclaim tunables:
/proc/sys/vm/extra_free_kbytes  # Preferred if available
/proc/sys/vm/min_free_kbytes    # Fallback

# ZRAM writeback (if backing_dev exists):
/sys/block/zram0/backing_dev
/sys/block/zram0/writeback_limit_enable
/sys/block/zram0/idle
/sys/block/zram0/writeback
# Writeback types: incompressible, huge_idle, idle
# Idle times: 1800, 600, 300, all

# Memory cgroup manipulation:
/sys/fs/cgroup/memory/apps/
/sys/fs/cgroup/memory/system/
/sys/fs/cgroup/memory/scene_idle/
/sys/fs/cgroup/memory/scene_active/
# Controls: memory.use_hierarchy, memory.oom_control,
#           memory.move_charge_at_immigrate, memory.limit_in_bytes

# Reclaim levels:
Level 3: 55% (friendly) / 26% (aggressive)
Level 2: 35% / 18%
Level 0: 14% / 10%
Default: 20% / 12%
```

---

### 5. priority.sh - Foreground App Booster

```bash
# Foreground detection methods (fallback chain):
1. dumpsys activity activities | grep mResumedActivity
2. dumpsys window windows | grep mCurrentFocus
3. dumpsys activity top | grep ACTIVITY
4. dumpsys activity recents | grep 'Recent #0'

# Priority boosting:
renice -n -20 -p $PID          # Max CPU priority
ionice -c1 -n0 -p $PID         # Realtime I/O class

# CPU affinity for all threads:
for TID in /proc/$PID/task/*; do
    taskset -p ff $TID         # All CPUs
done
```

---

### 6. thunder - Game Detection Daemon

**Binary Type:** Rust, UPX packed (32.26% compression)
**Unpacked Size:** 536 KB

**Behavior (from string analysis):**
```
Tracking game $PKG (pid $PID)
performance/mode/normal
/priority.txt
1/mode/perf
0/priority
pidof
/data/adb/modules/thunderclash/gamelist.txt
/current_mode
/data/local/tmp/thunder_default
normal sudah mati, reset tracking
```

**Workflow:**
1. Monitors foreground app via pidof
2. Checks if foreground app is in gamelist.txt
3. If game detected: executes mode/perf for performance boost
4. If game exits: reverts to mode/normal
5. Writes current mode to /data/adb/modules/thunderclash/current_mode

---

### 7. mode/reset - Color Reset Script

```bash
# SurfaceFlinger color matrix reset via binder
service call SurfaceFlinger 1022 f 1.25          # Saturation
service call SurfaceFlinger 1015 i32 1 \         # Color matrix
  f 1.00 f 0   f 0   f 0 \    # Red
  f 0   f 1.00 f 0   f 0 \    # Green
  f 0   f 0   f 1.00 f 0 \    # Blue
  f 0   f 0   f 0   f 1       # Alpha
```

This is the **only readable mode script**. Other mode binaries (normal, perf, powersave, color, skiagl, vulkan) are compiled and obfuscated.

---

## Techniques Worth Adopting

### 1. Foreground App Detection (priority.sh)
Multi-method fallback for reliable foreground detection across Android versions.

### 2. SoC Detection (soc.sh)
Robust platform detection with comprehensive fallback chain.

### 3. ZRAM Writeback (compress.sh)
Sophisticated ZRAM management with backing device writeback support.

### 4. Memory Cgroup Manipulation (compress.sh)
Advanced memory reclaim using cgroup limits.

### 5. Kernel Trace Cleanup (service.sh)
Reduces system overhead by disabling unused tracing.

### 6. MediaTek GPU DVFS (service.sh)
Direct sysfs control for GPU frequency scaling.

### 7. Adaptive Heap Sizing (service.sh)
RAM-based Dalvik heap configuration.

### 8. SurfaceFlinger Color Matrix (mode/reset)
Direct binder calls for display color manipulation.

---

## Configuration Options

### User-Configurable via WebUI:
- **Mode Selection:** Powersave / Balance / Performance
- **Rendering:** SkiaGL / SkiaVK
- **Color:** Boost / Default
- **Whitelist:** Apps protected from RAM cleaning
- **Gamelist:** Apps that trigger performance mode
- **Background:** Custom WebUI background image

### Files for Customization:
- `/data/adb/modules/thunderclash/whitelist.txt`
- `/data/adb/modules/thunderclash/gamelist.txt`
- `/data/adb/modules/thunderclash/current_mode`

---

## Notable sysfs/procfs Paths

### Kernel Tracing
```
/sys/kernel/tracing/tracing_on
/sys/kernel/tracing/buffer_size_kb
/sys/kernel/tracing/trace
/sys/kernel/tracing/per_cpu/*/trace
/sys/kernel/tracing/instances/*/trace
```

### MediaTek GPU
```
/sys/kernel/ged/hal/fast_dvfs
/sys/kernel/ged/hal/fdvfs
/sys/kernel/ged/hal/enable_fdvfs
/sys/kernel/ged/hal/boost_gpu_enable
/sys/kernel/ged/gpu_tuner/custom_hint_set
```

### Memory Management
```
/proc/sys/vm/swappiness
/proc/sys/vm/compact_memory
/proc/sys/vm/drop_caches
/proc/sys/vm/extra_free_kbytes
/proc/sys/vm/min_free_kbytes
/sys/block/zram0/disksize
/sys/block/zram0/reset
/sys/block/zram0/backing_dev
/sys/block/zram0/writeback
/sys/block/zram0/idle
```

### Memory Cgroups
```
/sys/fs/cgroup/memory/memory.swappiness
/dev/memcg/apps/memory.limit_in_bytes
/dev/memcg/system/memory.limit_in_bytes
```

### CPU Governor
```
/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

---

## Code Snippets Worth Borrowing

### Safe Echo Function
```bash
safe_echo() {
    local value="$1"
    local file="$2"
    [ -w "$file" ] && echo "$value" > "$file"
}
```

### SoC Detection
```bash
get_cpu_name() {
    local codename=$(getprop ro.soc.model)
    [ -z "$codename" ] && codename=$(getprop ro.soc.manufacturer)
    [ -z "$codename" ] && codename=$(getprop ro.mediatek.platform)
    [ -z "$codename" ] && codename=$(getprop ro.board.platform)
    [ -z "$codename" ] && codename=$(grep -m1 'Hardware' /proc/cpuinfo | cut -d ':' -f2 | sed 's/^[ \t]*//')
    echo "${codename:-unknown}" | tr '[:upper:]' '[:lower:]'
}
```

### Foreground App Detection
```bash
methods=(
    "dumpsys activity activities 2>/dev/null | grep -m 1 'mResumedActivity' | sed -E 's/.* ([^ ]+)\/.*/\1/'"
    "dumpsys window windows 2>/dev/null | grep -m 1 'mCurrentFocus' | sed -E 's/.* ([^ ]+)\/.*/\1/'"
    "dumpsys activity top 2>/dev/null | grep -m 1 'ACTIVITY' | awk '{print \$2}' | cut -d/ -f1"
    "dumpsys activity recents 2>/dev/null | grep -m 1 'Recent #0' | sed -E 's/.*A=([^ ]+).*/\1/'"
)

PKG=""
for cmd in "${methods[@]}"; do
    PKG=$(eval "$cmd")
    [ -n "$PKG" ] && break
done
```

### Memory Cgroup Path Detection
```bash
if [[ -e /sys/fs/cgroup/memory/memory.swappiness ]]; then
    scene_memcg="/sys/fs/cgroup/memory"
elif [[ -d /dev/memcg ]]; then
    scene_memcg="/dev/memcg"
fi
```

### ZRAM Reset
```bash
ZRAM=$(cat /sys/block/zram0/disksize)
swapoff /dev/block/zram0
echo 1 > /sys/block/zram0/reset
echo "$ZRAM" > /sys/block/zram0/disksize
mkswap /dev/block/zram0
swapon /dev/block/zram0
```

---

## Limitations

1. **Core mode binaries are obfuscated** - Cannot extract exact tuning values from normal/perf/powersave modes
2. **thunder daemon requires Rust reverse engineering** - Would need binary analysis to understand full logic
3. **No kernel module** - All tuning is userspace sysfs manipulation
4. **MediaTek-focused** - GPU DVFS paths are MediaTek-specific

---

## Conclusions

ThunderClash is a well-structured performance module with:
- Clean separation of concerns (detection, modes, UI)
- Multiple fallback strategies for compatibility
- Sophisticated memory management techniques
- Good use of Android system services (SurfaceFlinger, dumpsys)

The shell scripts provide valuable reference implementations for:
- SoC detection
- Foreground app monitoring
- Memory reclaim strategies
- System property manipulation

The compiled binaries likely contain additional CPU/GPU tuning that would require decompilation to extract.
