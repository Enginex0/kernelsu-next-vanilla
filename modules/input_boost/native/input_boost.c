/*
 * Input Boost Daemon for Android
 * High-performance C implementation using epoll/timerfd/signalfd
 * Boosts CPU frequency on touch input for improved responsiveness
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <dirent.h>
#include <time.h>
#include <stdarg.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <linux/input.h>

#define MAX_CPUS 32
#define MAX_PATH 256
#define MAX_LINE 512
#define MAX_EVENTS 4
#define MAX_LOG_SIZE 102400
#define BIG_LITTLE_THRESHOLD 2000000

#define LOG_ERROR 0
#define LOG_INFO  1
#define LOG_DEBUG 2

static const char *MODULE_DIR = "/data/adb/modules/input_boost";
static const char *CONFIG_FILE = "/data/adb/modules/input_boost/config.conf";
static const char *LOG_FILE = "/data/adb/modules/input_boost/daemon.log";
static const char *PID_FILE = "/data/adb/modules/input_boost/daemon.pid";
static const char *ORIG_FREQ_FILE = "/data/adb/modules/input_boost/.orig_freqs";

struct config {
    int boost_freq;
    int duration_ms;
    int cooldown_ms;
    char target_cpus[32];
    int enabled;
    int log_level;
};

struct cpu_info {
    int cpu_id;
    int orig_min_freq;
    int max_freq;
    int is_big;
    int is_online;
    int is_target;
};

static struct config g_config = {
    .boost_freq = 0,
    .duration_ms = 500,
    .cooldown_ms = 100,
    .target_cpus = "big",
    .enabled = 1,
    .log_level = LOG_INFO
};

static struct cpu_info g_cpus[MAX_CPUS];
static int g_cpu_count = 0;
static int g_epoll_fd = -1;
static int g_input_fd = -1;
static int g_timer_fd = -1;
static int g_signal_fd = -1;
static int g_log_fd = -1;
static int g_lock_fd = -1;
static volatile int g_running = 1;
static struct timespec g_last_boost = {0, 0};

static void log_rotate(void)
{
    struct stat st;
    char old_path[MAX_PATH];

    if (fstat(g_log_fd, &st) == 0 && st.st_size > MAX_LOG_SIZE) {
        snprintf(old_path, sizeof(old_path), "%s.old", LOG_FILE);
        close(g_log_fd);
        g_log_fd = -1;
        rename(LOG_FILE, old_path);
        g_log_fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    }
}

static void log_msg(int level, const char *fmt, ...)
{
    if (level < 0 || level > LOG_DEBUG)
        return;

    if (level > g_config.log_level || g_log_fd < 0)
        return;

    log_rotate();

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    if (!tm)
        return;

    char buf[MAX_LINE];
    int len;
    va_list ap;

    static const char *level_str[] = {"error", "info", "debug"};
    len = snprintf(buf, sizeof(buf), "[%04d-%02d-%02d %02d:%02d:%02d] [%s] ",
                   tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
                   tm->tm_hour, tm->tm_min, tm->tm_sec, level_str[level]);

    va_start(ap, fmt);
    len += vsnprintf(buf + len, sizeof(buf) - len - 1, fmt, ap);
    va_end(ap);

    if (len < (int)sizeof(buf) - 1) {
        buf[len++] = '\n';
        buf[len] = '\0';
    }

    write(g_log_fd, buf, len);
}

static int read_int_file(const char *path, int *value)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;

    char buf[32];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);

    if (n <= 0)
        return -1;

    buf[n] = '\0';
    *value = atoi(buf);
    return 0;
}

static int write_int_file(const char *path, int value)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0)
        return -1;

    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d", value);
    ssize_t n = write(fd, buf, len);
    close(fd);

    return (n == len) ? 0 : -1;
}

static int read_string_file(const char *path, char *buf, size_t size)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;

    ssize_t n = read(fd, buf, size - 1);
    close(fd);

    if (n <= 0)
        return -1;

    buf[n] = '\0';
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r'))
        buf[--n] = '\0';

    return 0;
}

static void parse_config(void)
{
    FILE *fp = fopen(CONFIG_FILE, "r");
    if (!fp)
        return;

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0')
            continue;

        char *eq = strchr(p, '=');
        if (!eq)
            continue;

        *eq = '\0';
        char *key = p;
        char *value = eq + 1;

        while (*value == ' ' || *value == '\t') value++;
        char *end = value + strlen(value) - 1;
        while (end > value && (*end == '\n' || *end == '\r' || *end == ' '))
            *end-- = '\0';

        if (strcmp(key, "BOOST_FREQ") == 0) {
            g_config.boost_freq = atoi(value);
        } else if (strcmp(key, "DURATION_MS") == 0) {
            g_config.duration_ms = atoi(value);
        } else if (strcmp(key, "COOLDOWN_MS") == 0) {
            g_config.cooldown_ms = atoi(value);
        } else if (strcmp(key, "TARGET_CPUS") == 0) {
            strncpy(g_config.target_cpus, value, sizeof(g_config.target_cpus) - 1);
            g_config.target_cpus[sizeof(g_config.target_cpus) - 1] = '\0';
        } else if (strcmp(key, "LOG_LEVEL") == 0) {
            if (strcmp(value, "error") == 0 || strcmp(value, "0") == 0)
                g_config.log_level = LOG_ERROR;
            else if (strcmp(value, "info") == 0 || strcmp(value, "1") == 0)
                g_config.log_level = LOG_INFO;
            else if (strcmp(value, "debug") == 0 || strcmp(value, "2") == 0)
                g_config.log_level = LOG_DEBUG;
        } else if (strcmp(key, "ENABLED") == 0) {
            g_config.enabled = atoi(value);
        }
    }

    fclose(fp);

    if (g_config.duration_ms <= 0) g_config.duration_ms = 500;
    if (g_config.cooldown_ms < 0) g_config.cooldown_ms = 100;
    if (g_config.boost_freq < 0) g_config.boost_freq = 0;

    log_msg(LOG_INFO, "Config: BOOST_FREQ=%d DURATION_MS=%d COOLDOWN_MS=%d TARGET_CPUS=%s",
            g_config.boost_freq, g_config.duration_ms, g_config.cooldown_ms, g_config.target_cpus);
}

static int find_touchscreen(char *device_path, size_t size)
{
    DIR *dir = opendir("/sys/class/input");
    if (!dir) {
        log_msg(LOG_ERROR, "Cannot open /sys/class/input: %s", strerror(errno));
        return -1;
    }

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (strncmp(ent->d_name, "input", 5) != 0)
            continue;

        char name_path[MAX_PATH], name[128];
        snprintf(name_path, sizeof(name_path), "/sys/class/input/%s/name", ent->d_name);

        if (read_string_file(name_path, name, sizeof(name)) < 0)
            continue;

        int is_touch = (strcasestr(name, "touch") != NULL ||
                        strcasestr(name, "screen") != NULL ||
                        strcasestr(name, "panel") != NULL ||
                        strstr(name, "fts") != NULL ||
                        strstr(name, "goodix") != NULL ||
                        strstr(name, "synaptics") != NULL ||
                        strstr(name, "atmel") != NULL ||
                        strstr(name, "himax") != NULL ||
                        strstr(name, "nvt") != NULL ||
                        strstr(name, "ilitek") != NULL);

        if (!is_touch)
            continue;

        int input_num = atoi(ent->d_name + 5);
        DIR *input_dir = opendir("/sys/class/input");
        if (!input_dir)
            continue;

        struct dirent *event_ent;
        while ((event_ent = readdir(input_dir)) != NULL) {
            if (strncmp(event_ent->d_name, "event", 5) != 0)
                continue;

            char link_path[MAX_PATH], real_path[MAX_PATH], input_real[MAX_PATH];
            snprintf(link_path, sizeof(link_path), "/sys/class/input/%s/device", event_ent->d_name);

            if (realpath(link_path, real_path) == NULL)
                continue;

            snprintf(link_path, sizeof(link_path), "/sys/class/input/%s", ent->d_name);
            if (realpath(link_path, input_real) == NULL)
                continue;

            if (strcmp(real_path, input_real) == 0) {
                int event_num = atoi(event_ent->d_name + 5);
                snprintf(device_path, size, "/dev/input/event%d", event_num);
                closedir(input_dir);
                closedir(dir);
                log_msg(LOG_INFO, "Detected touchscreen: %s -> %s", name, device_path);
                return 0;
            }
        }
        closedir(input_dir);

        snprintf(device_path, size, "/dev/input/event%d", input_num);
        if (access(device_path, R_OK) == 0) {
            closedir(dir);
            log_msg(LOG_INFO, "Detected touchscreen (fallback): %s -> %s", name, device_path);
            return 0;
        }
    }

    closedir(dir);
    log_msg(LOG_ERROR, "No touchscreen found");
    return -1;
}

static int detect_cpus(void)
{
    int max_freq_global = 0;
    int has_little = 0;

    for (int i = 0; i < MAX_CPUS; i++) {
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);

        int max_freq;
        if (read_int_file(path, &max_freq) < 0)
            continue;

        g_cpus[g_cpu_count].cpu_id = i;
        g_cpus[g_cpu_count].max_freq = max_freq;
        g_cpus[g_cpu_count].is_online = 1;
        g_cpus[g_cpu_count].is_target = 0;

        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq", i);
        read_int_file(path, &g_cpus[g_cpu_count].orig_min_freq);

        if (max_freq > max_freq_global)
            max_freq_global = max_freq;

        if (max_freq < BIG_LITTLE_THRESHOLD)
            has_little = 1;

        g_cpu_count++;
    }

    if (g_cpu_count == 0) {
        log_msg(LOG_ERROR, "No CPUs with cpufreq support found");
        return -1;
    }

    int threshold = has_little ? BIG_LITTLE_THRESHOLD : 0;
    for (int i = 0; i < g_cpu_count; i++) {
        g_cpus[i].is_big = (g_cpus[i].max_freq >= threshold);
    }

    if (strcmp(g_config.target_cpus, "all") == 0) {
        for (int i = 0; i < g_cpu_count; i++)
            g_cpus[i].is_target = 1;
    } else if (strcmp(g_config.target_cpus, "big") == 0) {
        for (int i = 0; i < g_cpu_count; i++)
            g_cpus[i].is_target = g_cpus[i].is_big;
    } else if (strcmp(g_config.target_cpus, "little") == 0) {
        for (int i = 0; i < g_cpu_count; i++)
            g_cpus[i].is_target = !g_cpus[i].is_big;
    } else {
        char buf[32];
        strncpy(buf, g_config.target_cpus, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        char *saveptr;
        char *tok = strtok_r(buf, ",", &saveptr);
        while (tok) {
            int cpu_id = atoi(tok);
            for (int i = 0; i < g_cpu_count; i++) {
                if (g_cpus[i].cpu_id == cpu_id)
                    g_cpus[i].is_target = 1;
            }
            tok = strtok_r(NULL, ",", &saveptr);
        }
    }

    int target_count = 0;
    for (int i = 0; i < g_cpu_count; i++) {
        if (g_cpus[i].is_target) {
            log_msg(LOG_DEBUG, "Target CPU%d: max=%d orig_min=%d big=%d",
                    g_cpus[i].cpu_id, g_cpus[i].max_freq, g_cpus[i].orig_min_freq, g_cpus[i].is_big);
            target_count++;
        }
    }

    log_msg(LOG_INFO, "Detected %d CPUs, %d targets (%s)", g_cpu_count, target_count, g_config.target_cpus);
    return (target_count > 0) ? 0 : -1;
}

static void save_original_freqs(void)
{
    FILE *fp = fopen(ORIG_FREQ_FILE, "w");
    if (!fp) {
        log_msg(LOG_ERROR, "Cannot save original frequencies: %s", strerror(errno));
        return;
    }

    for (int i = 0; i < g_cpu_count; i++) {
        if (g_cpus[i].is_target)
            fprintf(fp, "%d:%d\n", g_cpus[i].cpu_id, g_cpus[i].orig_min_freq);
    }

    fclose(fp);
    log_msg(LOG_DEBUG, "Saved original frequencies");
}

static void restore_original_freqs(void)
{
    for (int i = 0; i < g_cpu_count; i++) {
        if (!g_cpus[i].is_target)
            continue;

        char path[MAX_PATH];
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq",
                 g_cpus[i].cpu_id);

        if (write_int_file(path, g_cpus[i].orig_min_freq) < 0) {
            log_msg(LOG_ERROR, "Failed to restore freq for cpu%d: %s",
                    g_cpus[i].cpu_id, strerror(errno));
        }
    }
    log_msg(LOG_DEBUG, "Restored original frequencies");
}

static void apply_boost(void)
{
    for (int i = 0; i < g_cpu_count; i++) {
        if (!g_cpus[i].is_target)
            continue;

        char online_path[MAX_PATH];
        snprintf(online_path, sizeof(online_path), "/sys/devices/system/cpu/cpu%d/online",
                 g_cpus[i].cpu_id);

        int online = 1;
        read_int_file(online_path, &online);
        if (online == 0)
            continue;

        int boost_freq = (g_config.boost_freq == 0) ? g_cpus[i].max_freq : g_config.boost_freq;

        char path[MAX_PATH];
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq",
                 g_cpus[i].cpu_id);

        if (write_int_file(path, boost_freq) < 0) {
            log_msg(LOG_ERROR, "Failed to boost cpu%d: %s", g_cpus[i].cpu_id, strerror(errno));
        }
    }
    log_msg(LOG_DEBUG, "Applied boost");
}

static int arm_timer(int timer_fd, int ms)
{
    struct itimerspec ts = {
        .it_value = {
            .tv_sec = ms / 1000,
            .tv_nsec = (ms % 1000) * 1000000
        },
        .it_interval = {0, 0}
    };

    if (timerfd_settime(timer_fd, 0, &ts, NULL) < 0) {
        log_msg(LOG_ERROR, "timerfd_settime failed: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int check_cooldown(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    long elapsed_ms = (now.tv_sec - g_last_boost.tv_sec) * 1000 +
                      (now.tv_nsec - g_last_boost.tv_nsec) / 1000000;

    if (elapsed_ms < g_config.cooldown_ms)
        return 0;

    g_last_boost = now;
    return 1;
}

static int check_singleton(void)
{
    char lock_path[MAX_PATH];
    snprintf(lock_path, sizeof(lock_path), "%s.lock", PID_FILE);

    g_lock_fd = open(lock_path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
    if (g_lock_fd < 0) {
        fprintf(stderr, "Cannot open lock file: %s\n", strerror(errno));
        return -1;
    }

    if (flock(g_lock_fd, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "Another instance is running\n");
        close(g_lock_fd);
        g_lock_fd = -1;
        return -1;
    }

    FILE *fp = fopen(PID_FILE, "w");
    if (fp) {
        fprintf(fp, "%d\n", getpid());
        fclose(fp);
    }
    return 0;
}

static void recover_from_crash(void)
{
    if (access(ORIG_FREQ_FILE, F_OK) != 0)
        return;

    log_msg(LOG_INFO, "Found stale frequency file - restoring from previous crash");

    FILE *fp = fopen(ORIG_FREQ_FILE, "r");
    if (!fp)
        return;

    char line[64];
    while (fgets(line, sizeof(line), fp)) {
        int cpu_id, freq;
        if (sscanf(line, "%d:%d", &cpu_id, &freq) == 2) {
            char path[MAX_PATH];
            snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq", cpu_id);
            write_int_file(path, freq);
        }
    }

    fclose(fp);
    unlink(ORIG_FREQ_FILE);
}

static void cleanup(void)
{
    log_msg(LOG_INFO, "Shutting down...");

    restore_original_freqs();

    if (g_input_fd >= 0) {
        close(g_input_fd);
        g_input_fd = -1;
    }
    if (g_timer_fd >= 0) {
        close(g_timer_fd);
        g_timer_fd = -1;
    }
    if (g_signal_fd >= 0) {
        close(g_signal_fd);
        g_signal_fd = -1;
    }
    if (g_epoll_fd >= 0) {
        close(g_epoll_fd);
        g_epoll_fd = -1;
    }
    if (g_lock_fd >= 0) {
        close(g_lock_fd);
        g_lock_fd = -1;
    }

    unlink(PID_FILE);
    unlink(ORIG_FREQ_FILE);

    log_msg(LOG_INFO, "Cleanup complete");

    if (g_log_fd >= 0) {
        close(g_log_fd);
        g_log_fd = -1;
    }
}

static int setup_epoll(const char *device_path)
{
    g_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (g_epoll_fd < 0) {
        log_msg(LOG_ERROR, "epoll_create1 failed: %s", strerror(errno));
        return -1;
    }

    g_input_fd = open(device_path, O_RDONLY | O_CLOEXEC);
    if (g_input_fd < 0) {
        log_msg(LOG_ERROR, "Cannot open %s: %s", device_path, strerror(errno));
        return -1;
    }

    g_timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (g_timer_fd < 0) {
        log_msg(LOG_ERROR, "timerfd_create failed: %s", strerror(errno));
        return -1;
    }

    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    sigaddset(&mask, SIGUSR1);
    sigaddset(&mask, SIGUSR2);
    sigaddset(&mask, SIGPIPE);

    if (sigprocmask(SIG_BLOCK, &mask, NULL) < 0) {
        log_msg(LOG_ERROR, "sigprocmask failed: %s", strerror(errno));
        return -1;
    }

    g_signal_fd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (g_signal_fd < 0) {
        log_msg(LOG_ERROR, "signalfd failed: %s", strerror(errno));
        return -1;
    }

    struct epoll_event ev;

    ev.events = EPOLLIN;
    ev.data.fd = g_input_fd;
    if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_input_fd, &ev) < 0) {
        log_msg(LOG_ERROR, "epoll_ctl input_fd failed: %s", strerror(errno));
        return -1;
    }

    ev.events = EPOLLIN;
    ev.data.fd = g_timer_fd;
    if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_timer_fd, &ev) < 0) {
        log_msg(LOG_ERROR, "epoll_ctl timer_fd failed: %s", strerror(errno));
        return -1;
    }

    ev.events = EPOLLIN;
    ev.data.fd = g_signal_fd;
    if (epoll_ctl(g_epoll_fd, EPOLL_CTL_ADD, g_signal_fd, &ev) < 0) {
        log_msg(LOG_ERROR, "epoll_ctl signal_fd failed: %s", strerror(errno));
        return -1;
    }

    return 0;
}

static void event_loop(void)
{
    struct epoll_event events[MAX_EVENTS];
    struct input_event ie;
    struct signalfd_siginfo siginfo;
    uint64_t timer_exp;

    log_msg(LOG_INFO, "Entering event loop");

    while (g_running) {
        int n = epoll_wait(g_epoll_fd, events, MAX_EVENTS, -1);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            log_msg(LOG_ERROR, "epoll_wait failed: %s", strerror(errno));
            break;
        }

        for (int i = 0; i < n; i++) {
            int fd = events[i].data.fd;

            if (events[i].events & (EPOLLERR | EPOLLHUP)) {
                if (fd == g_input_fd) {
                    log_msg(LOG_ERROR, "Input device disconnected, exiting");
                    g_running = 0;
                    break;
                }
            }

            if (fd == g_input_fd) {
                while (read(g_input_fd, &ie, sizeof(ie)) == sizeof(ie)) {
                    if (ie.type == EV_ABS || ie.type == EV_SYN) {
                        if (check_cooldown()) {
                            apply_boost();
                            arm_timer(g_timer_fd, g_config.duration_ms);
                            log_msg(LOG_DEBUG, "Boost triggered");
                        }
                        break;
                    }
                }
            } else if (fd == g_timer_fd) {
                if (read(g_timer_fd, &timer_exp, sizeof(timer_exp)) == sizeof(timer_exp)) {
                    restore_original_freqs();
                }
            } else if (fd == g_signal_fd) {
                if (read(g_signal_fd, &siginfo, sizeof(siginfo)) == sizeof(siginfo)) {
                    int sig = siginfo.ssi_signo;
                    if (sig == SIGTERM || sig == SIGINT || sig == SIGHUP) {
                        log_msg(LOG_INFO, "Received signal %d, shutting down", sig);
                        g_running = 0;
                    } else {
                        log_msg(LOG_DEBUG, "Ignoring signal %d", sig);
                    }
                }
            }
        }
    }
}

int main(void)
{
    g_log_fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_log_fd < 0) {
        fprintf(stderr, "Cannot open log file: %s\n", strerror(errno));
        return 1;
    }

    log_msg(LOG_INFO, "Input Boost Daemon starting");

    if (check_singleton() < 0) {
        close(g_log_fd);
        return 1;
    }
    recover_from_crash();
    parse_config();

    if (!g_config.enabled) {
        log_msg(LOG_INFO, "Daemon disabled in config, exiting");
        unlink(PID_FILE);
        close(g_log_fd);
        return 0;
    }

    char device_path[MAX_PATH];
    int retry;
    for (retry = 0; retry < 6; retry++) {
        if (find_touchscreen(device_path, sizeof(device_path)) == 0)
            break;
        log_msg(LOG_INFO, "No touchscreen found, retrying in 30s (%d/6)", retry + 1);
        sleep(30);
    }

    if (retry >= 6) {
        log_msg(LOG_ERROR, "Failed to detect touchscreen after retries, exiting");
        unlink(PID_FILE);
        close(g_log_fd);
        return 1;
    }

    if (detect_cpus() < 0) {
        log_msg(LOG_ERROR, "Failed to detect target CPUs, exiting");
        unlink(PID_FILE);
        close(g_log_fd);
        return 1;
    }

    save_original_freqs();

    if (setup_epoll(device_path) < 0) {
        log_msg(LOG_ERROR, "Failed to setup epoll, exiting");
        cleanup();
        return 1;
    }

    event_loop();
    cleanup();

    return 0;
}
