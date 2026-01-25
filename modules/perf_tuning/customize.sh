#!/system/bin/sh
# Performance Tuning - Installation Script
# Runs during module installation via KernelSU/Magisk manager

SKIPUNZIP=1

ui_print "=========================================="
ui_print " Performance Tuning Module v1.2.0"
ui_print "=========================================="
ui_print ""
ui_print " SurfaceFlinger (early boot):"
ui_print "   - touch_timer_ms = 250"
ui_print "   - idle_timer_ms = 3000"
ui_print "   - skiaglthreaded backend"
ui_print "   - max_events_per_sec = 90"
ui_print ""
ui_print " BFQ I/O Scheduler Tuning:"
ui_print "   - slice_idle = 0"
ui_print "   - fifo_expire_sync = 80"
ui_print "   - fifo_expire_async = 150"
ui_print ""
ui_print " Memory Optimizations:"
ui_print "   - swappiness = 100 (aggressive ZRAM)"
ui_print "   - vfs_cache_pressure = 50"
ui_print "   - page-cluster = 0"
ui_print ""

ui_print "[*] Extracting module files..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

if [ ! -f "$MODPATH/module.prop" ]; then
    ui_print "[!] Installation failed - module.prop missing"
    exit 1
fi

ui_print "[*] Setting permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755

ui_print ""
ui_print "[+] Installation complete!"
ui_print "[*] Tuning will apply on next boot"
ui_print "[*] Logs: (module)/tuning.log"
ui_print ""

# Clean up old files from previous versions
rm -f /data/local/tmp/perf_tuning* 2>/dev/null
