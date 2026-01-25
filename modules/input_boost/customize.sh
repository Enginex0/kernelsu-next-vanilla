#!/system/bin/sh
# Input Boost Daemon - Installation Script

SKIPUNZIP=1

ui_print "- Installing Input Boost Daemon"

# Extract module files
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

# Validate required files
for f in module.prop service.sh input_boost_daemon.sh config.conf; do
    if [ ! -f "$MODPATH/$f" ]; then
        ui_print "! Missing required file: $f"
        abort "Installation failed"
    fi
done

# Set permissions
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/input_boost_daemon.sh" 0 0 0755
# Set execute permission on binary daemon if present
if [ -f "$MODPATH/input_boost_daemon" ]; then
    set_perm "$MODPATH/input_boost_daemon" 0 0 0755
    ui_print "- Native binary daemon found"
fi

# Check for cpufreq support
CPUFREQ_PATH="/sys/devices/system/cpu/cpu0/cpufreq"
if [ ! -d "$CPUFREQ_PATH" ]; then
    ui_print "! Warning: cpufreq interface not found"
    ui_print "  Module may not function on this device"
fi

# Check for input devices
if [ ! -d "/sys/class/input" ]; then
    ui_print "! Warning: input subsystem not found"
    ui_print "  Module may not function on this device"
fi

# Config is now self-contained in module directory
ui_print "- Config: $MODPATH/config.conf"
ui_print "- Logs: $MODPATH/daemon.log"

# Clean up old files from previous versions
rm -f /data/local/tmp/input_boost* 2>/dev/null

ui_print "- Installation complete"
ui_print "- Reboot to activate input boost daemon"
