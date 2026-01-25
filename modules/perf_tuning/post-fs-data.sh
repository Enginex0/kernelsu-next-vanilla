#!/system/bin/sh
# Performance Tuning - Early Boot Properties
# Runs BEFORE most services start - critical for SurfaceFlinger props

MODDIR="${0%/*}"

# SurfaceFlinger timing (must be set before SF starts)
resetprop ro.surface_flinger.set_touch_timer_ms 250
resetprop ro.surface_flinger.set_idle_timer_ms 3000
resetprop ro.surface_flinger.set_display_power_timer_ms 1000
resetprop ro.surface_flinger.use_content_detection_for_refresh_rate true

# Input event throughput
resetprop windowsmgr.max_events_per_sec 90
resetprop ro.min_pointer_dur 1

# Rendering engine
resetprop debug.renderengine.backend skiaglthreaded
resetprop debug.hwui.renderer skiagl
resetprop ro.config.enable.hw_accel true

# Disable scrolling cache (fresher scrolling)
resetprop persist.sys.scrollingcache 0

# SystemUI/SystemServer compiler optimization
resetprop dalvik.vm.systemuicompilerfilter speed-profile
resetprop dalvik.vm.systemservercompilerfilter speed-profile

# HWUI optimizations
resetprop debug.hwui.disable_vsync true
resetprop debug.sf.disable_client_composition_cache 1
resetprop debug.hwui.skia_atrace_enabled false
