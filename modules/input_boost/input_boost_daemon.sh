#!/system/bin/sh
# Input Boost Daemon
# Boosts CPU frequency on touch input for improved responsiveness

MODDIR=${0%/*}
LOGFILE="$MODDIR/daemon.log"
PIDFILE="$MODDIR/daemon.pid"
LOCKFILE="$MODDIR/daemon.lock"
CONFIG_FILE="$MODDIR/config.conf"
ORIG_FREQ_FILE="$MODDIR/.orig_freqs"
FIFO_PATH="$MODDIR/.fifo_$$"
GETEVENT_PID=""
MAX_LOG_SIZE=102400

# Defaults
BOOST_FREQ=0
DURATION_MS=500
COOLDOWN_MS=100
TARGET_CPUS="big"
LOG_LEVEL="info"
ENABLED=1
INPUT_DEVICE=""

LAST_BOOST_S=0
BOOST_ACTIVE=0
BOOST_END_S=0
RUNNING=1

# --- Logging ---

log_rotate() {
    if [ -f "$LOGFILE" ]; then
        size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOGFILE" "${LOGFILE}.old"
        fi
    fi
}

log() {
    local level="$1"
    local msg="$2"

    case "$LOG_LEVEL" in
        error) [ "$level" != "error" ] && return ;;
        info)  [ "$level" = "debug" ] && return ;;
    esac

    log_rotate
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOGFILE"
}

log_error() { log "error" "$1"; }
log_warn()  { log "warn" "$1"; }
log_info()  { log "info" "$1"; }
log_debug() { log "debug" "$1"; }

# --- Configuration ---

load_config() {
    [ -f "$CONFIG_FILE" ] || return

    while IFS='=' read -r key value; do
        case "$key" in
            \#*|"") continue ;;
        esac
        value=$(echo "$value" | tr -d ' \t\r')
        case "$key" in
            BOOST_FREQ)   BOOST_FREQ="$value" ;;
            DURATION_MS)  DURATION_MS="$value" ;;
            COOLDOWN_MS)  COOLDOWN_MS="$value" ;;
            TARGET_CPUS)  TARGET_CPUS="$value" ;;
            INPUT_DEVICE) INPUT_DEVICE="$value" ;;
            LOG_LEVEL)    LOG_LEVEL="$value" ;;
            ENABLED)      ENABLED="$value" ;;
        esac
    done < "$CONFIG_FILE"

    # BUG 5 FIX: Validate INPUT_DEVICE path to prevent injection
    if [ -n "$INPUT_DEVICE" ]; then
        case "$INPUT_DEVICE" in
            /dev/input/event[0-9]|/dev/input/event[0-9][0-9]|/dev/input/event[0-9][0-9][0-9])
                ;; # Valid path
            *)
                log_error "Invalid INPUT_DEVICE path: $INPUT_DEVICE - must be /dev/input/eventN"
                INPUT_DEVICE=""
                ;;
        esac
    fi

    log_info "Config: BOOST_FREQ=$BOOST_FREQ DURATION_MS=$DURATION_MS COOLDOWN_MS=$COOLDOWN_MS TARGET_CPUS=$TARGET_CPUS"
}

# --- Touchscreen Detection ---

detect_touchscreen() {
    local found=""

    # Check configured device first
    if [ -n "$INPUT_DEVICE" ] && [ -e "$INPUT_DEVICE" ]; then
        log_info "Using configured input device: $INPUT_DEVICE"
        echo "$INPUT_DEVICE"
        return 0
    fi

    # Scan /sys/class/input for touchscreen
    for input_path in /sys/class/input/input*; do
        [ -d "$input_path" ] || continue

        name_file="$input_path/name"
        [ -f "$name_file" ] || continue

        name=$(cat "$name_file" 2>/dev/null)
        case "$name" in
            *[Tt]ouch*|*[Ss]creen*|*[Pp]anel*|*fts*|*goodix*|*synaptics*|*atmel*|*himax*|*nvt*|*ilitek*)
                # Found touchscreen, map to event device
                input_num=${input_path##*/input}
                for event_path in /sys/class/input/event*; do
                    [ -d "$event_path" ] || continue
                    if [ -d "$event_path/device" ]; then
                        device_link=$(readlink -f "$event_path/device" 2>/dev/null)
                        if [ "$device_link" = "$(readlink -f "$input_path")" ]; then
                            event_num=${event_path##*/event}
                            found="/dev/input/event$event_num"
                            log_info "Detected touchscreen: $name -> $found"
                            echo "$found"
                            return 0
                        fi
                    fi
                done

                # Fallback: check if eventN exists with same number
                if [ -e "/dev/input/event$input_num" ]; then
                    found="/dev/input/event$input_num"
                    log_info "Detected touchscreen (fallback): $name -> $found"
                    echo "$found"
                    return 0
                fi
                ;;
        esac
    done

    # Last resort: scan /proc/bus/input/devices
    if [ -f "/proc/bus/input/devices" ]; then
        local current_name="" current_handlers=""
        while IFS= read -r line; do
            case "$line" in
                N:\ Name=*)
                    current_name="${line#N: Name=\"}"
                    current_name="${current_name%\"}"
                    ;;
                H:\ Handlers=*)
                    current_handlers="${line#H: Handlers=}"
                    case "$current_name" in
                        *[Tt]ouch*|*[Ss]creen*|*goodix*|*synaptics*|*fts*)
                            for handler in $current_handlers; do
                                case "$handler" in
                                    event*)
                                        found="/dev/input/$handler"
                                        log_info "Detected touchscreen (proc): $current_name -> $found"
                                        echo "$found"
                                        return 0
                                        ;;
                                esac
                            done
                            ;;
                    esac
                    current_name=""
                    current_handlers=""
                    ;;
            esac
        done < "/proc/bus/input/devices"
    fi

    log_error "No touchscreen found"
    return 1
}

# --- CPU Detection ---

get_cpu_list() {
    local mode="$1"
    local cpus=""
    local max_freq=0
    local threshold=2000000

    # First pass: find max frequency
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_path/cpufreq" ] || continue

        freq_file="$cpu_path/cpufreq/cpuinfo_max_freq"
        [ -f "$freq_file" ] || continue

        freq=$(cat "$freq_file" 2>/dev/null)
        [ -n "$freq" ] && [ "$freq" -gt "$max_freq" ] && max_freq=$freq
    done

    # If all CPUs have same max (no big.LITTLE), treat all as big
    local has_little=0
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_path/cpufreq" ] || continue
        freq=$(cat "$cpu_path/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -n "$freq" ] && [ "$freq" -lt "$threshold" ] && has_little=1 && break
    done
    [ $has_little -eq 0 ] && threshold=0

    # Second pass: select CPUs
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_path/cpufreq" ] || continue

        cpu_num=${cpu_path##*/cpu}
        freq=$(cat "$cpu_path/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$freq" ] && continue

        case "$mode" in
            all)
                cpus="$cpus $cpu_num"
                ;;
            big)
                [ "$freq" -ge "$threshold" ] && cpus="$cpus $cpu_num"
                ;;
            little)
                [ "$freq" -lt "$threshold" ] && cpus="$cpus $cpu_num"
                ;;
            *)
                # Comma-separated list
                for target in $(echo "$mode" | tr ',' ' '); do
                    [ "$cpu_num" = "$target" ] && cpus="$cpus $cpu_num"
                done
                ;;
        esac
    done

    echo "$cpus"
}

get_boost_freq() {
    local cpu="$1"
    local freq_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"

    if [ "$BOOST_FREQ" = "0" ] || [ "$BOOST_FREQ" = "max" ]; then
        cat "$freq_path/cpuinfo_max_freq" 2>/dev/null
    else
        echo "$BOOST_FREQ"
    fi
}

# --- Frequency Management ---

save_original_freqs() {
    local cpus="$1"

    rm -f "$ORIG_FREQ_FILE"
    for cpu in $cpus; do
        freq_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq"
        [ -f "$freq_path" ] || continue

        orig=$(cat "$freq_path" 2>/dev/null)
        [ -n "$orig" ] && echo "$cpu:$orig" >> "$ORIG_FREQ_FILE"
    done
    log_debug "Saved original frequencies"
}

restore_original_freqs() {
    [ -f "$ORIG_FREQ_FILE" ] || return

    local write_err=""
    while IFS=':' read -r cpu freq; do
        [ -z "$cpu" ] || [ -z "$freq" ] && continue
        freq_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq"
        write_err=$(echo "$freq" 2>&1 > "$freq_path")
        if [ -n "$write_err" ]; then
            log_error "Failed to restore freq for cpu$cpu: $write_err"
        fi
    done < "$ORIG_FREQ_FILE"
    log_debug "Restored original frequencies"
}

apply_boost() {
    local cpus="$1"
    local write_err=""

    for cpu in $cpus; do
        # Skip offline CPUs
        online_file="/sys/devices/system/cpu/cpu${cpu}/online"
        if [ -f "$online_file" ]; then
            online=$(cat "$online_file" 2>/dev/null)
            [ "$online" = "0" ] && continue
        fi

        freq_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_min_freq"
        [ -f "$freq_path" ] || continue

        boost_freq=$(get_boost_freq "$cpu")
        [ -z "$boost_freq" ] && continue

        write_err=$(echo "$boost_freq" 2>&1 > "$freq_path")
        if [ -n "$write_err" ]; then
            log_error "Failed to boost cpu$cpu: $write_err"
        fi
    done
    log_debug "Applied boost to CPUs: $cpus"
}

# BUG 4 FIX: Track boost timing without background subshells to avoid race conditions
start_boost_timer() {
    BOOST_ACTIVE=1
    BOOST_END_S=$(($(date +%s) + (DURATION_MS / 1000) + 1))
}

check_and_restore() {
    [ "$BOOST_ACTIVE" -eq 0 ] && return
    local now_s=$(date +%s)
    if [ "$now_s" -ge "$BOOST_END_S" ]; then
        restore_original_freqs
        BOOST_ACTIVE=0
    fi
}

# --- Signal Handling ---

cleanup() {
    log_info "Shutting down..."
    RUNNING=0

    # Kill getevent/hexdump background process
    if [ -n "$GETEVENT_PID" ]; then
        kill "$GETEVENT_PID" 2>/dev/null
        wait "$GETEVENT_PID" 2>/dev/null
        GETEVENT_PID=""
    fi

    # Remove FIFO
    rm -f "$FIFO_PATH"

    # Restore original frequencies
    restore_original_freqs

    # Remove files
    rm -f "$PIDFILE"
    rm -f "$ORIG_FREQ_FILE"

    # Kill child processes
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null

    log_info "Cleanup complete"
    exit 0
}

# Handle termination signals gracefully
trap cleanup SIGTERM SIGINT SIGHUP
# Ignore signals that shouldn't kill the daemon
trap '' USR1 USR2 PIPE

# --- Event Monitoring ---

# BUG 1 FIX: Use named pipe (FIFO) instead of process substitution for Android sh compatibility
monitor_events_getevent() {
    local device="$1"
    local cpus="$2"
    local cooldown_s=$((COOLDOWN_MS / 1000))
    [ "$cooldown_s" -lt 1 ] && cooldown_s=1

    log_info "Monitoring via getevent: $device"

    # Create FIFO for Android sh compatibility (no process substitution)
    rm -f "$FIFO_PATH"
    if ! mkfifo "$FIFO_PATH" 2>/dev/null; then
        log_error "Failed to create FIFO at $FIFO_PATH"
        return 1
    fi

    # Start getevent writing to FIFO in background
    getevent -q "$device" > "$FIFO_PATH" 2>/dev/null &
    GETEVENT_PID=$!

    # Read from FIFO in foreground (not in subshell)
    while [ "$RUNNING" -eq 1 ] && IFS=' ' read -r type code value; do
        # Check if boost timer expired
        check_and_restore

        # EV_ABS (0003) or EV_SYN (0000) indicates touch activity
        case "$type" in
            0003|0000)
                local now_s=$(date +%s)
                local elapsed_s=$((now_s - LAST_BOOST_S))

                if [ "$elapsed_s" -ge "$cooldown_s" ]; then
                    LAST_BOOST_S=$now_s
                    apply_boost "$cpus"
                    start_boost_timer
                    log_debug "Boost triggered"
                fi
                ;;
        esac
    done < "$FIFO_PATH"

    # Cleanup background process
    if [ -n "$GETEVENT_PID" ]; then
        kill "$GETEVENT_PID" 2>/dev/null
        wait "$GETEVENT_PID" 2>/dev/null
        GETEVENT_PID=""
    fi
    rm -f "$FIFO_PATH"
}

monitor_events_cat() {
    local device="$1"
    local cpus="$2"
    local cooldown_s=$((COOLDOWN_MS / 1000))
    [ "$cooldown_s" -lt 1 ] && cooldown_s=1

    log_info "Monitoring via timeout cat: $device"

    while [ "$RUNNING" -eq 1 ]; do
        # Check if boost timer expired
        check_and_restore

        # Try to read with short timeout
        if timeout 0.1 cat "$device" > /dev/null 2>&1; then
            local now_s=$(date +%s)
            local elapsed_s=$((now_s - LAST_BOOST_S))

            if [ "$elapsed_s" -ge "$cooldown_s" ]; then
                LAST_BOOST_S=$now_s
                apply_boost "$cpus"
                start_boost_timer
                log_debug "Boost triggered"
            fi
        fi

        # Small sleep to avoid spinning
        sleep 0.05
    done
}

# BUG 1 FIX: Use named pipe (FIFO) instead of process substitution for Android sh compatibility
monitor_events_hexdump() {
    local device="$1"
    local cpus="$2"
    local cooldown_s=$((COOLDOWN_MS / 1000))
    [ "$cooldown_s" -lt 1 ] && cooldown_s=1

    log_info "Monitoring via hexdump: $device"

    # Create FIFO for Android sh compatibility (no process substitution)
    rm -f "$FIFO_PATH"
    if ! mkfifo "$FIFO_PATH" 2>/dev/null; then
        log_error "Failed to create FIFO at $FIFO_PATH"
        return 1
    fi

    # Start hexdump writing to FIFO in background
    # Read input events (struct input_event = 24 bytes on 64-bit)
    hexdump -v -e '1/8 "%d " 1/8 "%d " 1/2 "%d " 1/2 "%d " 1/4 "%d\n"' "$device" > "$FIFO_PATH" 2>/dev/null &
    GETEVENT_PID=$!

    # Read from FIFO in foreground (not in subshell)
    while [ "$RUNNING" -eq 1 ] && read -r sec usec type code value; do
        # Check if boost timer expired
        check_and_restore

        # type 3 = EV_ABS (touch events)
        if [ "$type" = "3" ]; then
            local now_s=$(date +%s)
            local elapsed_s=$((now_s - LAST_BOOST_S))

            if [ "$elapsed_s" -ge "$cooldown_s" ]; then
                LAST_BOOST_S=$now_s
                apply_boost "$cpus"
                start_boost_timer
                log_debug "Boost triggered (EV_ABS code=$code value=$value)"
            fi
        fi
    done < "$FIFO_PATH"

    # Cleanup background process
    if [ -n "$GETEVENT_PID" ]; then
        kill "$GETEVENT_PID" 2>/dev/null
        wait "$GETEVENT_PID" 2>/dev/null
        GETEVENT_PID=""
    fi
    rm -f "$FIFO_PATH"
}

# --- Main ---

main() {
    log_info "Input Boost Daemon starting"

    # BUG 3 FIX: Singleton check using PID file (Android shell compatible)
    if [ -f "$PIDFILE" ]; then
        old_pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log_error "Another instance is already running (PID: $old_pid)"
            exit 1
        fi
        # Stale PID file, remove it
        rm -f "$PIDFILE"
    fi

    # Write PID atomically
    echo $$ > "$PIDFILE.tmp" && mv "$PIDFILE.tmp" "$PIDFILE"

    # Load configuration
    load_config

    # BUG 2 FIX: Restore frequencies from previous crash if stale file exists
    if [ -f "$ORIG_FREQ_FILE" ]; then
        log_warn "Found stale frequency file - restoring from previous crash"
        restore_original_freqs
        rm -f "$ORIG_FREQ_FILE"
    fi

    # Check if enabled
    if [ "$ENABLED" != "1" ]; then
        log_info "Daemon disabled in config, exiting"
        rm -f "$PIDFILE"
        exit 0
    fi

    # Detect touchscreen
    local device=""
    local retry_count=0
    while [ -z "$device" ] && [ $retry_count -lt 6 ]; do
        device=$(detect_touchscreen)
        if [ -z "$device" ]; then
            log_info "No touchscreen found, retrying in 30s ($retry_count/6)"
            retry_count=$((retry_count + 1))
            sleep 30
        fi
    done

    if [ -z "$device" ]; then
        log_error "Failed to detect touchscreen after retries, exiting"
        rm -f "$PIDFILE"
        exit 1
    fi

    # Verify device exists
    if [ ! -e "$device" ]; then
        log_error "Input device does not exist: $device"
        rm -f "$PIDFILE"
        exit 1
    fi

    # Get target CPUs
    local cpus=$(get_cpu_list "$TARGET_CPUS")
    if [ -z "$cpus" ]; then
        log_error "No CPUs found for TARGET_CPUS=$TARGET_CPUS"
        rm -f "$PIDFILE"
        exit 1
    fi
    log_info "Target CPUs: $cpus"

    # Save original frequencies
    save_original_freqs "$cpus"

    # Select monitoring method
    if command -v getevent > /dev/null 2>&1; then
        monitor_events_getevent "$device" "$cpus"
    elif command -v hexdump > /dev/null 2>&1; then
        monitor_events_hexdump "$device" "$cpus"
    else
        monitor_events_cat "$device" "$cpus"
    fi

    cleanup
}

main "$@"
