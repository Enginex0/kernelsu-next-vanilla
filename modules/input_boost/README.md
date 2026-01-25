# Input Boost Daemon

A Magisk/KernelSU module that boosts CPU frequency on touch input for improved UI responsiveness.

## How It Works

The daemon monitors touchscreen events via `/dev/input/eventN` and temporarily raises the CPU's minimum frequency when touch activity is detected. This reduces input latency and makes the UI feel more responsive.

## Features

- Automatic touchscreen detection (supports goodix, synaptics, fts, atmel, himax, nvt, ilitek)
- Configurable boost frequency, duration, and cooldown
- Supports big.LITTLE CPU architectures (can target big, little, or all cores)
- Crash recovery with frequency restoration
- Multiple monitoring backends (getevent, hexdump, cat fallback)
- Singleton daemon with proper locking

## Installation

1. Download the ZIP file
2. Flash via Magisk Manager, KernelSU Manager, or recovery
3. Reboot

## Configuration

Edit the config file at:
```
/data/local/tmp/input_boost.conf
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| BOOST_FREQ | 0 | Boost frequency in kHz (0 = use max available) |
| DURATION_MS | 500 | How long to maintain the boost (milliseconds) |
| COOLDOWN_MS | 100 | Minimum time between boosts (milliseconds) |
| TARGET_CPUS | big | Which CPUs to boost: `big`, `little`, `all`, or comma-separated list (e.g., `4,5,6,7`) |
| LOG_LEVEL | info | Logging verbosity: `error`, `info`, `debug` |
| ENABLED | 1 | Enable/disable daemon (1=enabled, 0=disabled) |
| INPUT_DEVICE | (auto) | Force specific input device (e.g., `/dev/input/event2`) |

### Example Configuration

```
BOOST_FREQ=0
DURATION_MS=300
COOLDOWN_MS=50
TARGET_CPUS=big
LOG_LEVEL=info
ENABLED=1
```

## Logs

The daemon logs to:
```
/data/local/tmp/input_boost.log
```

## Files

| File | Purpose |
|------|---------|
| /data/local/tmp/input_boost.conf | Configuration file |
| /data/local/tmp/input_boost.log | Log file |
| /data/local/tmp/input_boost.pid | Daemon PID file |
| /data/local/tmp/input_boost.lock | Singleton lock file |

## Requirements

- Magisk v20.4+ or KernelSU
- Kernel with cpufreq support
- Device with touchscreen input

## Uninstallation

Remove the module via Magisk/KernelSU Manager, or delete:
```
/data/adb/modules/input_boost
```

The daemon will restore original CPU frequencies on shutdown.

## Troubleshooting

**Daemon not starting:**
- Check log file for errors
- Verify touchscreen is detected: `ls /sys/class/input/`
- Ensure cpufreq is available: `ls /sys/devices/system/cpu/cpu0/cpufreq/`

**No boost effect:**
- Set LOG_LEVEL=debug and check logs
- Verify TARGET_CPUS matches your device's CPU topology
- Try setting explicit INPUT_DEVICE if auto-detection fails

## Version

- Version: 1.0.0
- Author: KernelSU-Next
