# Reverse Engineering Report: Another Smooth UI (ASU) v6.2

**Analysis Date:** 2026-01-23
**Author:** Ghost
**Module Version:** v6.2 (kaminarich)
**Source:** `/home/president/Pictures/zip-up/+Hacking Toolbox/Miscellenous/Another Smooth UI (ASU) 6.2.zip`

---

## 1. Module Overview

ASU (Another Smooth UI) is a Magisk module focused on UI smoothness and responsiveness optimization. It uses a multi-layer approach:
1. System properties via `system.prop`
2. Runtime property overrides via `resetprop` in `post-fs-data.sh`
3. Runtime settings via `settings` command in `service.sh`
4. Obfuscated shell scripts compiled with `shc` (ASU/ASU2 binaries)

**Key Finding:** The local v6.2 zip differs significantly from the GitHub repository's main branch. The author appears to use shc (shell script compiler) to obfuscate the core logic in the distributed zip files while keeping plaintext versions on GitHub.

---

## 2. File Structure

```
Another Smooth UI (ASU) 6.2/
├── META-INF/
│   └── com/google/android/
│       ├── update-binary        (613 bytes) - Standard Magisk installer
│       └── updater-script       (8 bytes)   - "#MAGISK"
├── customize.sh                 (2.4 KB)    - Install-time info display
├── module.prop                  (216 bytes) - Module metadata
├── post-fs-data.sh              (715 bytes) - Early boot resetprop calls
├── service.sh                   (93 bytes)  - Launches ASU2 daemon
├── system.prop                  (724 bytes) - Build-time system properties
├── system/bin/
│   ├── ASU                      (14 KB)     - shc-compiled binary (stripped)
│   └── ASU2                     (14 KB)     - shc-compiled binary (symbols)
└── uninstall.sh                 (401 bytes) - Cleanup script
```

---

## 3. System Properties (system.prop)

### Local v6.2 Version (Different from GitHub)

```ini
# SurfaceFlinger Timing
ro.surface_flinger.set_idle_timer_ms=3000
ro.surface_flinger.set_touch_timer_ms=250
ro.surface_flinger.set_display_power_timer_ms=1000
ro.surface_flinger.use_content_detection_for_refresh_rate=true
ro.surface_flinger.force_hwc_copy_for_virtual_displays=false
ro.surface_flinger.enable_present_time_offset=true

# Dalvik/ART Runtime
dalvik.vm.usejit=true
dalvik.vm.usejitprofiles=true
dalvik.vm.dex2oat-threads=6
dalvik.vm.image-dex2oat-threads=6
dalvik.vm.boot-dex2oat-threads=6
dalvik.vm.dexopt.secondary=true
dalvik.vm.appimageformat=lz4
dalvik.vm.minidebuginfo=true
dalvik.vm.dex2oat-resolve-startup-strings=true
dalvik.vm.dex2oat-minidebuginfo=true
```

### GitHub Main Branch Version

```ini
# Render Engine & UI Pipeline
debug.hwui.skip_empty_damage=true
hwui.disable_scissor_opt=true
debug.hwui.disable_blur=false
debug.hwui.render_dirty_regions=false
vendor.debug.renderengine.backend=skiaglthreaded

# GPU / OpenGL
persist.sys.ui.hw=true
persist.sys.gpu.disable_ubwc=1
persist.sys.force_sw_gles=0
persist.graphics.vulkan.disable=true

# Dalvik VM / Heap Management
dalvik.vm.heapstartsize=16m
dalvik.vm.heapgrowthlimit=256m
dalvik.vm.heapsize=512m
dalvik.vm.heaputilization=0.75
dalvik.vm.minfree=8m
dalvik.vm.maxfree=32m
dalvik.vm.dex2oat-filter=speed

# Scrolling & Touch Response
persist.sys.scrollingcache=3
ro.min_pointer_dur=1
view.scroll_friction=10
windowsmgr.max_events_per_sec=90

# Display Boost
persist.sys.sf.native_mode=2
persist.sys.sf.color_mode=1
```

---

## 4. Post-FS-Data Tweaks (resetprop)

```sh
# Rendering Engine
resetprop ro.config.enable.hw_accel true
resetprop debug.hwui.renderer skiagl
resetprop debug.renderengine.backend skiaglthreaded

# Compiler Optimization
resetprop dalvik.vm.systemuicompilerfilter speed-profile
resetprop dalvik.vm.systemservercompilerfilter speed-profile

# SurfaceFlinger
resetprop debug.sf.hw 1
resetprop debug.hwui.disable_vsync true
resetprop debug.sf.disable_client_composition_cache 1
resetprop debug.hwui.disable_blur true
resetprop -p persist.sys.scrollingcache disabled
```

---

## 5. Service Script (service.sh)

The service script simply executes the obfuscated ASU2 binary:

```sh
#!/system/bin/sh
chmod 0755 data/adb/modules/asu/system/bin/ASU2
ASU2
```

---

## 6. GitHub Service.sh (Unobfuscated Version)

```sh
#!/system/bin/sh

sleep 10

# Animation Scale Reduction
settings put global window_animation_scale 0.5
settings put global transition_animation_scale 0.5
settings put global animator_duration_scale 0.5

# HWUI Dirty Region
setprop persist.sys.hwui.render_dirty_regions true

# LCD/Gesture Features
setprop persist.service.lcd.ledcover_enable 1
setprop persist.service.lcd.ledcover_gesture 1

# GPU Optimizations
setprop persist.service.gfx.enable 1
setprop persist.service.gfx.enable_early_boost 1
setprop persist.service.gfx.gpu_optimize 1
setprop persist.service.gfx.renderthread 1
setprop persist.service.gfx.gpu_usage_limit 100
setprop persist.service.gfx.gpu_rendering_priority 1
setprop persist.service.gfx.gpu_boost 1
setprop persist.service.gfx.force_gpu 1

# RAM/Storage Optimization
setprop persist.service.lmk.kill_heaviest_task 1
setprop persist.service.storage_optimize 1
```

---

## 7. UI Smoothness Techniques Analysis

### What ASU Does

| Category | Technique | Purpose |
|----------|-----------|---------|
| **Graphics** | `skiaglthreaded` backend | Multithreaded GPU rendering |
| **Graphics** | Disable blur | Reduces GPU load |
| **Graphics** | Skip empty damage | Avoids unnecessary redraws |
| **Compilation** | 6 dex2oat threads | Faster app optimization |
| **Compilation** | `speed-profile` filter | Better SystemUI/SystemServer perf |
| **Animation** | 0.5x animation scale | Faster perceived UI |
| **Display** | Touch timer 250ms | Faster refresh rate on touch |
| **Display** | Disable client composition cache | Fresher frames |
| **Scrolling** | Disable scrolling cache | Reduces memory, fresher scroll |
| **Touch** | `ro.min_pointer_dur=1` | Minimum touch duration |
| **Touch** | `windowsmgr.max_events_per_sec=90` | Higher input event rate |

### Key SurfaceFlinger Tunables

```
set_idle_timer_ms=3000      # 3s before dropping to idle refresh rate
set_touch_timer_ms=250      # 250ms after touch to maintain high refresh
enable_present_time_offset  # Better frame timing
```

---

## 8. Comparison with Our Input Boost Module

| Feature | ASU | Our Input Boost |
|---------|-----|-----------------|
| **Approach** | System properties + runtime setprop | Kernel sysfs manipulation |
| **Input Detection** | None (static props) | Active getevent monitoring |
| **CPU Boost** | None | Yes, scaling_min_freq boost |
| **Scheduler** | None | None |
| **Animation** | Reduces scale | No |
| **Graphics** | Skia/GPU tweaks | No |
| **Memory** | Heap tuning | No |
| **Refresh Rate** | SurfaceFlinger timers | No |

### What ASU Does That We Don't

1. **SurfaceFlinger timing control** - Touch-triggered refresh rate boost
2. **Skia threaded backend** - GPU rendering optimization
3. **dex2oat threading** - Faster app compilation
4. **Animation scale reduction** - Perceived responsiveness
5. **Scrolling cache disable** - Memory efficiency
6. **Input event rate boost** - `windowsmgr.max_events_per_sec=90`

### What We Do That ASU Doesn't

1. **Active CPU frequency boost** on touch detection
2. **Event-driven** rather than static properties
3. **Configurable boost duration/cooldown**
4. **Big.LITTLE aware** CPU targeting

---

## 9. Techniques Worth Adopting

### High Value (Should Implement)

```sh
# SurfaceFlinger touch timer - immediate win
resetprop ro.surface_flinger.set_touch_timer_ms 250

# Input event rate boost
resetprop windowsmgr.max_events_per_sec 90

# Disable scrolling cache
resetprop persist.sys.scrollingcache 0
```

### Medium Value (Consider)

```sh
# Skia threaded rendering (device-dependent)
resetprop debug.renderengine.backend skiaglthreaded
resetprop debug.hwui.renderer skiagl

# SystemUI/SystemServer compiler optimization
resetprop dalvik.vm.systemuicompilerfilter speed-profile
resetprop dalvik.vm.systemservercompilerfilter speed-profile
```

### Lower Priority (Device-Specific)

```sh
# GPU properties (may not exist on all devices)
setprop persist.service.gfx.gpu_boost 1
setprop persist.service.gfx.force_gpu 1
```

---

## 10. Comparison with Other Modules

### YAKT (Yet Another Kernel Tweaker)

YAKT focuses on **kernel tunables** rather than system properties:

```sh
# Scheduler Latency Reduction
sched_migration_cost_ns=50000
sched_min_granularity_ns=1000000
sched_wakeup_granularity_ns=1500000
sched_child_runs_first=1
sched_autogroup_enabled=0

# Schedutil Rate Limits
up_rate_limit_us=10000
down_rate_limit_us=20000

# Memory
vfs_cache_pressure=50
stat_interval=30
swappiness=0 (8GB+) / 60 (<8GB)
dirty_ratio=60
compaction_proactiveness=0
page-cluster=0

# UCLAMP (if available)
top-app: uclamp.max=max, uclamp.min=10, latency_sensitive=1
foreground: uclamp.max=50, uclamp.min=0
background: uclamp.max=max, uclamp.min=20

# I/O
iostats=0
nr_requests=64

# Network
tcp_timestamps=0
tcp_low_latency=1
```

### AKTune (Android Kernel Tweaker)

AKTune uses **dynamic profiles** (AUTO/AGGRESSIVE/STRICT):
- CPU scheduling per cluster tier
- VM dirty ratios tuning
- GPU frequency anti-downclocking
- I/O read-ahead configuration
- UCLAMP/cpuset protection for foreground apps

---

## 11. Recommendations for Input Boost Module

### Immediate Additions

Add to `post-fs-data.sh`:

```sh
# SurfaceFlinger touch responsiveness
resetprop ro.surface_flinger.set_touch_timer_ms 250
resetprop ro.surface_flinger.set_idle_timer_ms 3000

# Input event throughput
resetprop windowsmgr.max_events_per_sec 90
resetprop ro.min_pointer_dur 1

# Rendering optimization
resetprop debug.renderengine.backend skiaglthreaded
```

### Consider Adding (service.sh)

```sh
# YAKT-style scheduler tweaks
echo 50000 > /proc/sys/kernel/sched_migration_cost_ns
echo 1000000 > /proc/sys/kernel/sched_min_granularity_ns
echo 1500000 > /proc/sys/kernel/sched_wakeup_granularity_ns
echo 1 > /proc/sys/kernel/sched_child_runs_first

# Schedutil rate limits (if using schedutil governor)
for cpu in /sys/devices/system/cpu/*/cpufreq/schedutil; do
    [ -d "$cpu" ] || continue
    echo 10000 > "$cpu/up_rate_limit_us" 2>/dev/null
    echo 20000 > "$cpu/down_rate_limit_us" 2>/dev/null
done
```

---

## 12. Conclusion

ASU takes a **property-based approach** to UI smoothness, focusing on:
- SurfaceFlinger/display timing
- Skia rendering backend
- ART/Dalvik compilation optimization
- Animation scaling

Our Input Boost module takes a **kernel-based approach** with active touch detection and CPU frequency boosting.

**The ideal solution combines both approaches:**
1. Static property optimizations from ASU for baseline smoothness
2. Dynamic CPU boosting from Input Boost for touch responsiveness
3. YAKT-style scheduler tunables for reduced latency

The modules are **complementary**, not competing. Users would benefit from running both together.

---

## References

- ASU GitHub: https://github.com/kaminarich/asu
- YAKT GitHub: https://github.com/NotZeetaa/YAKT
- AKTune GitHub: https://github.com/iodn/android-kernel-tweaker
