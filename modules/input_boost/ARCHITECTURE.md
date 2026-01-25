# Input Boost Daemon Architecture

**Target:** Android 12+ with GKI Kernel 5.10+
**Deployment:** KernelSU Module
**Approach:** Userspace daemon with sysfs frequency control (no kernel patches)

---

## Component Diagram

```
+------------------------------------------------------------------+
|                         KernelSU Module                           |
+------------------------------------------------------------------+
|                                                                    |
|  +--------------------+     +----------------------------------+   |
|  |   service.sh       |---->|         input_boost.sh           |   |
|  | (boot trigger)     |     |       (main daemon)              |   |
|  +--------------------+     +----------------------------------+   |
|                                        |                           |
|                                        v                           |
|  +------------------------------------------------------------------+
|  |                        DAEMON COMPONENTS                         |
|  +------------------------------------------------------------------+
|  |                                                                  |
|  |  +------------------+    +------------------+    +-------------+ |
|  |  |    DETECTOR      |    |     BOOSTER      |    |   CONFIG    | |
|  |  +------------------+    +------------------+    +-------------+ |
|  |  | - Scan input devs|    | - Read max freqs |    | - Load conf | |
|  |  | - Identify touch |    | - Write min_freq |    | - Defaults  | |
|  |  | - Monitor events |    | - Track originals|    | - Validate  | |
|  |  +--------+---------+    +--------+---------+    +------+------+ |
|  |           |                       |                     |        |
|  |           v                       v                     v        |
|  |  +------------------+    +------------------+    +-------------+ |
|  |  |     TIMER        |    |     LOGGER       |    |   SIGNALS   | |
|  |  +------------------+    +------------------+    +-------------+ |
|  |  | - Boost duration |    | - Rotate logs    |    | - SIGTERM   | |
|  |  | - Cooldown mgmt  |    | - Logcat fallback|    | - SIGINT    | |
|  |  | - Decay handling |    | - Debug levels   |    | - Cleanup   | |
|  |  +------------------+    +------------------+    +-------------+ |
|  |                                                                  |
|  +------------------------------------------------------------------+
|                                                                    |
+------------------------------------------------------------------+

                              KERNEL INTERFACES
+------------------------------------------------------------------+
|                                                                    |
|  /dev/input/event*           /sys/devices/system/cpu/             |
|  +------------------+        +----------------------------------+  |
|  | eventX (touch)   |        | cpu0/cpufreq/scaling_min_freq   |  |
|  | eventY (buttons) |        | cpu0/cpufreq/scaling_max_freq   |  |
|  | eventZ (sensors) |        | cpu0/cpufreq/cpuinfo_max_freq   |  |
|  +------------------+        | cpu0/cpufreq/scaling_governor   |  |
|                              | ...                              |  |
|  /sys/class/input/           | cpu7/cpufreq/...                |  |
|  +------------------+        +----------------------------------+  |
|  | input0/name      |                                              |
|  | input0/caps/abs  |                                              |
|  +------------------+                                              |
|                                                                    |
+------------------------------------------------------------------+
```

---

## Event Flow

```
                                    BOOT
                                      |
                                      v
                           +-------------------+
                           |   service.sh      |
                           | (KernelSU boot)   |
                           +--------+----------+
                                    |
                                    v
                           +-------------------+
                           |  Load config      |
                           |  /data/local/tmp/ |
                           |  input_boost.conf |
                           +--------+----------+
                                    |
                                    v
                           +-------------------+
                           |  Detect touch     |
                           |  input devices    |
                           +--------+----------+
                                    |
                 +------------------+------------------+
                 |                                     |
                 v                                     v
        +----------------+                    +----------------+
        | Found touch    |                    | No touch found |
        | /dev/input/X   |                    +-------+--------+
        +-------+--------+                            |
                |                                     v
                v                             +----------------+
        +----------------+                    | Log warning    |
        | Save original  |                    | Retry or exit  |
        | min_freq values|                    +----------------+
        +-------+--------+
                |
                v
        +----------------+
        | Enter monitor  |<-----------------------------------------+
        | loop (poll)    |                                          |
        +-------+--------+                                          |
                |                                                   |
                v                                                   |
        +----------------+     No      +----------------+           |
        | Event received?|------------>| Sleep interval |---------->|
        +-------+--------+             +----------------+           |
                | Yes                                               |
                v                                                   |
        +----------------+     Yes     +----------------+           |
        | In cooldown?   |------------>| Skip boost     |---------->|
        +-------+--------+             +----------------+           |
                | No                                                |
                v                                                   |
        +----------------+                                          |
        | BOOST: Write   |                                          |
        | target freq to |                                          |
        | scaling_min_freq|                                         |
        +-------+--------+                                          |
                |                                                   |
                v                                                   |
        +----------------+                                          |
        | Start timer    |                                          |
        | (boost_duration)|                                         |
        +-------+--------+                                          |
                |                                                   |
                v                                                   |
        +----------------+                                          |
        | Timer expires  |                                          |
        +-------+--------+                                          |
                |                                                   |
                v                                                   |
        +----------------+                                          |
        | RESTORE:       |                                          |
        | Original freq  |                                          |
        +-------+--------+                                          |
                |                                                   |
                v                                                   |
        +----------------+                                          |
        | Start cooldown |------------------------------------------+
        +----------------+


                            SIGNAL HANDLER
        +----------------------------------------------------------------+
        |                                                                |
        |   SIGTERM/SIGINT received                                      |
        |         |                                                      |
        |         v                                                      |
        |   +----------------+                                           |
        |   | Restore all    |                                           |
        |   | original freqs |                                           |
        |   +-------+--------+                                           |
        |           |                                                    |
        |           v                                                    |
        |   +----------------+                                           |
        |   | Remove PID file|                                           |
        |   +-------+--------+                                           |
        |           |                                                    |
        |           v                                                    |
        |   +----------------+                                           |
        |   | Log shutdown   |                                           |
        |   | Exit 0         |                                           |
        |   +----------------+                                           |
        |                                                                |
        +----------------------------------------------------------------+
```

---

## Sysfs Paths and Interfaces

### Input Device Detection

| Path | Purpose | Usage |
|------|---------|-------|
| `/dev/input/event*` | Raw input events | Read with poll/select |
| `/sys/class/input/input*/name` | Device name | Check for "touch", "touchscreen" |
| `/sys/class/input/event*/device/name` | Alternate name path | Same as above |
| `/sys/class/input/input*/capabilities/abs` | ABS capabilities bitmap | Check for MT support |
| `/proc/bus/input/devices` | All input devices | Comprehensive device info |

**Touchscreen Identification Algorithm:**
```
1. List /sys/class/input/input*/name
2. grep -i "touch\|screen\|panel\|fts\|goodix\|synaptics\|atmel"
3. Verify ABS_MT_* capability: capabilities/abs bitmap has bit 0x35 (53)
4. Map inputN -> eventN via /sys/class/input/inputN/eventN
```

### CPU Frequency Control

| Path | Purpose | R/W | Notes |
|------|---------|-----|-------|
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq` | Min frequency | RW | Primary boost target |
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq` | Max frequency | RW | Reference only |
| `/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq` | Hardware max | R | Boost target value |
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_available_frequencies` | Valid frequencies | R | Validation |
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | Current governor | RW | Must not be "performance" |
| `/sys/devices/system/cpu/cpu*/online` | CPU online status | R | Skip offline CPUs |

### Big/LITTLE Core Detection

```
# Big cores typically have higher max frequencies
# Example: Snapdragon 888
#   CPU 0-3: LITTLE (1.8GHz)
#   CPU 4-6: big (2.4GHz)
#   CPU 7: prime (2.84GHz)

for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
    max=$(cat $cpu/cpuinfo_max_freq)
    # big cores: max > 2000000 (2GHz)
done
```

### Alternative Boost Methods (Research Notes)

| Method | Path | Effectiveness | Availability |
|--------|------|---------------|--------------|
| PM-QoS Latency | `/dev/cpu_dma_latency` | Indirect (affects idle states) | Most kernels |
| Interactive Boost | `/sys/devices/system/cpu/cpufreq/interactive/boost` | Direct | Deprecated governor |
| Schedutil Hispeed | `/sys/devices/system/cpu/cpufreq/schedutil/hispeed_freq` | Direct | Schedutil only |
| Devfreq Boost | `/sys/class/devfreq/*/min_freq` | GPU/Memory | Device specific |

---

## Implementation Approach

### Primary: Shell Script Daemon

**Rationale:** Portability, no compilation, easy debugging, sufficient for most users.

**Components:**
- `service.sh` - Boot trigger, starts daemon
- `input_boost.sh` - Main daemon logic
- `input_boost.conf` - User configuration

**Event Monitoring (Shell):**
```bash
# Option 1: cat with timeout (simple, higher latency ~100ms)
while true; do
    timeout 0.1 cat /dev/input/event2 > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        apply_boost
    fi
done

# Option 2: Using getevent (better, ~50ms)
getevent -q /dev/input/event2 | while read line; do
    case "$line" in
        *"EV_ABS"*"ABS_MT"*) apply_boost ;;
    esac
done

# Option 3: Using inotifywait (event-driven, requires inotify-tools)
inotifywait -m -e access /dev/input/event2 | while read; do
    apply_boost
done
```

**Boost Function:**
```bash
apply_boost() {
    local now=$(date +%s%N)
    local cooldown_ns=$((COOLDOWN_MS * 1000000))

    # Cooldown check
    if [ $((now - LAST_BOOST)) -lt $cooldown_ns ]; then
        return
    fi
    LAST_BOOST=$now

    # Apply boost to target CPUs
    for cpu in $TARGET_CPUS; do
        echo "$BOOST_FREQ" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq
    done

    # Schedule restore (background subshell)
    (
        sleep_ms $DURATION_MS
        for cpu in $TARGET_CPUS; do
            echo "${ORIG_FREQ[$cpu]}" > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq
        done
    ) &
}
```

### Optional: C Binary Daemon

**Rationale:** <10ms latency, lower CPU overhead, better for gaming/demanding apps.

**Build Requirements:**
- Android NDK or musl cross-compiler
- Static linking for portability
- Target: aarch64-linux-android

**Core Loop:**
```c
#include <linux/input.h>
#include <poll.h>

struct pollfd fds[MAX_INPUT_DEVICES];
int nfds = 0;

// Populate fds with open input device fds

while (1) {
    int ret = poll(fds, nfds, -1);  // Block until event
    if (ret > 0) {
        for (int i = 0; i < nfds; i++) {
            if (fds[i].revents & POLLIN) {
                struct input_event ev;
                read(fds[i].fd, &ev, sizeof(ev));
                if (ev.type == EV_ABS && is_touch_event(ev.code)) {
                    apply_boost();
                }
            }
        }
    }
}
```

---

## Configuration File Format

**Path:** `/data/local/tmp/input_boost.conf`

```ini
# Input Boost Daemon Configuration
# Lines starting with # are comments

# Boost frequency in kHz (default: max available)
# Use "max" for maximum available frequency
BOOST_FREQ=max

# Boost duration in milliseconds
DURATION_MS=500

# Cooldown between boosts in milliseconds
COOLDOWN_MS=100

# Target CPUs: "all", "big", or comma-separated list
# "big" = cores with max_freq > 2GHz
TARGET_CPUS=big

# Input device override (auto-detected if empty)
# INPUT_DEVICE=/dev/input/event2

# Log level: 0=errors, 1=info, 2=debug
LOG_LEVEL=1

# Enable/disable daemon (for easy toggle without uninstalling)
ENABLED=1
```

**Parsing Logic:**
```bash
load_config() {
    local conf="/data/local/tmp/input_boost.conf"
    [ -f "$conf" ] || return

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        case "$key" in
            \#*|"") continue ;;
        esac
        # Strip whitespace
        value=$(echo "$value" | tr -d ' ')
        case "$key" in
            BOOST_FREQ)    BOOST_FREQ="$value" ;;
            DURATION_MS)   DURATION_MS="$value" ;;
            COOLDOWN_MS)   COOLDOWN_MS="$value" ;;
            TARGET_CPUS)   TARGET_CPUS="$value" ;;
            INPUT_DEVICE)  INPUT_DEVICE="$value" ;;
            LOG_LEVEL)     LOG_LEVEL="$value" ;;
            ENABLED)       ENABLED="$value" ;;
        esac
    done < "$conf"
}
```

---

## Error Handling Strategy

### Startup Errors

| Error | Detection | Response |
|-------|-----------|----------|
| No touchscreen found | Empty device list after scan | Log warning, retry every 30s |
| Cannot open /dev/input/event* | `open()` returns -1 | Check permissions, try next device |
| scaling_min_freq not writable | `echo` fails | Check governor, check SELinux |
| Config file invalid | Parse error | Use defaults, log warning |

### Runtime Errors

| Error | Detection | Response |
|-------|-----------|----------|
| Input device disconnected | `read()` returns 0 or ENODEV | Re-scan input devices |
| CPU goes offline | `/sys/*/online` = 0 | Skip that CPU, no error |
| Write to min_freq fails | `echo` returns error | Log, continue with others |
| Out of memory | Unlikely for shell | N/A |

### Cleanup Protocol

```bash
cleanup() {
    log "Shutting down..."

    # Restore all original frequencies
    for cpu in $TARGET_CPUS; do
        if [ -n "${ORIG_FREQ[$cpu]}" ]; then
            echo "${ORIG_FREQ[$cpu]}" > \
                /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq 2>/dev/null
        fi
    done

    # Remove PID file
    rm -f /data/local/tmp/input_boost.pid

    # Kill any background restore processes
    jobs -p | xargs -r kill 2>/dev/null

    log "Cleanup complete"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP
```

### SELinux Considerations

On enforcing SELinux, the daemon may need:
- Read access to `/dev/input/event*` (usually granted to shell)
- Write access to `/sys/devices/system/cpu/*/cpufreq/*` (may be denied)

**Workarounds:**
1. KernelSU's root context usually bypasses SELinux
2. If issues persist, add sepolicy rules in module
3. Last resort: `setenforce 0` (not recommended)

---

## Module File Structure

```
input_boost/
├── META-INF/
│   └── com/google/android/
│       ├── update-binary      # Magisk/KernelSU installer
│       └── updater-script     # Dummy (required)
├── module.prop                 # Module metadata
├── customize.sh                # Installation script
├── service.sh                  # Boot service (starts daemon)
├── input_boost.sh              # Main daemon script
├── uninstall.sh                # Cleanup on uninstall
└── system/                     # (empty, no system modifications)
```

---

## Performance Characteristics

### Shell Implementation

| Metric | Value | Notes |
|--------|-------|-------|
| Event-to-boost latency | 50-100ms | Depends on polling method |
| CPU overhead (idle) | ~0.1% | Polling interval dependent |
| CPU overhead (active) | ~0.5% | During boost operations |
| Memory footprint | ~2MB | Shell process + subshells |

### C Binary Implementation

| Metric | Value | Notes |
|--------|-------|-------|
| Event-to-boost latency | <10ms | poll() based |
| CPU overhead (idle) | ~0.01% | Blocked on poll() |
| CPU overhead (active) | ~0.05% | Minimal processing |
| Memory footprint | ~500KB | Static binary |

---

## Future Enhancements

1. **Adaptive Boost**: Adjust boost frequency based on current load
2. **App-aware Boost**: Higher boost for specific apps (games)
3. **GPU Boost**: Integrate devfreq boost for GPU-bound workloads
4. **Battery Awareness**: Disable boost below certain battery levels
5. **Thermal Awareness**: Reduce boost under thermal throttling
6. **Statistics**: Track boost counts, durations for analysis

---

## References

- [Android Input Architecture](https://newandroidbook.com/Book/Input.html)
- [getevent Tool - AOSP](https://source.android.com/docs/core/interaction/input/getevent)
- [Touch Devices - AOSP](https://source.android.com/docs/core/interaction/input/touch-devices)
- [Linux Input Subsystem](https://www.kernel.org/doc/html/v4.10/driver-api/input.html)
- [PM QoS Interface](https://www.kernel.org/doc/html/latest/power/pm_qos_interface.html)
- [CPU Frequency Scaling - ArchWiki](https://wiki.archlinux.org/title/CPU_frequency_scaling)
- [evtest Manual](https://manpages.ubuntu.com/manpages/trusty/man1/evtest.1.html)
- [AKTune - Android Kernel Tweaker](https://github.com/iodn/android-kernel-tweaker)
