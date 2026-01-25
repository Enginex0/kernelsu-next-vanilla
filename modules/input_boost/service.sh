#!/system/bin/sh
# Input Boost Daemon - Boot Service
# Starts the input boost daemon at boot

MODDIR=${0%/*}
LOGFILE="$MODDIR/daemon.log"
PIDFILE="$MODDIR/daemon.pid"
LOOPPIDFILE="$MODDIR/.watchdog.pid"
# Use binary daemon if available, fallback to shell script
if [ -x "$MODDIR/input_boost_daemon" ]; then
    DAEMON="$MODDIR/input_boost_daemon"
    DAEMON_TYPE="binary"
else
    DAEMON="$MODDIR/input_boost_daemon.sh"
    DAEMON_TYPE="shell"
fi

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] service.sh: $1" >> "$LOGFILE"
}

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done
sleep 10

log_msg "Boot completed, starting input boost daemon"

# BUG 7 FIX: Kill any existing restart loop to prevent orphans
if [ -f "$LOOPPIDFILE" ]; then
    old_loop_pid=$(cat "$LOOPPIDFILE" 2>/dev/null)
    if [ -n "$old_loop_pid" ] && kill -0 "$old_loop_pid" 2>/dev/null; then
        log_msg "Killing existing restart loop (PID: $old_loop_pid)"
        kill "$old_loop_pid" 2>/dev/null
        sleep 1
    fi
    rm -f "$LOOPPIDFILE"
fi

# Kill any existing daemon instance
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        log_msg "Killing existing daemon (PID: $old_pid)"
        kill "$old_pid" 2>/dev/null
        sleep 1
    fi
    rm -f "$PIDFILE"
fi

# Start daemon with watchdog monitoring
(
    # Track the watchdog loop PID
    echo $$ > "$LOOPPIDFILE"

    MAX_RESTARTS=10
    RESTART_COUNT=0
    RESTART_WINDOW=300  # Reset counter after 5 minutes of stability
    LAST_START=0

    start_daemon() {
        log_msg "Starting daemon ($DAEMON_TYPE): $DAEMON"
        if [ "$DAEMON_TYPE" = "binary" ]; then
            "$DAEMON" &
        else
            sh "$DAEMON" &
        fi
        DAEMON_PID=$!
        echo $DAEMON_PID > "$PIDFILE"
        LAST_START=$(date +%s)
        log_msg "Daemon started with PID: $DAEMON_PID"
    }

    # Initial start
    start_daemon

    # Watchdog loop - monitors daemon and restarts if needed
    while true; do
        sleep 10

        # Check if daemon is still running
        if [ -f "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                # Daemon is alive, reset restart counter if stable for RESTART_WINDOW
                now=$(date +%s)
                elapsed=$((now - LAST_START))
                if [ $elapsed -ge $RESTART_WINDOW ] && [ $RESTART_COUNT -gt 0 ]; then
                    log_msg "Daemon stable for ${RESTART_WINDOW}s, resetting restart counter"
                    RESTART_COUNT=0
                fi
                continue
            fi
        fi

        # Daemon is dead
        log_msg "Daemon not running, checking restart limit"

        RESTART_COUNT=$((RESTART_COUNT + 1))
        if [ $RESTART_COUNT -gt $MAX_RESTARTS ]; then
            log_msg "Max restarts ($MAX_RESTARTS) exceeded, giving up"
            break
        fi

        log_msg "Restarting daemon (attempt $RESTART_COUNT/$MAX_RESTARTS)"
        sleep 2
        start_daemon
    done

    rm -f "$LOOPPIDFILE"
) &
