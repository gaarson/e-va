#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <termios.h>
#include <fcntl.h>
#include <sys/ioctl.h>

#if LUA_VERSION_NUM < 502

#define lua_rawlen lua_objlen
#define luaL_newlib(L, l) (lua_newtable(L), luaL_register(L, NULL, l))
#endif

typedef struct {
    const char *str;
    size_t len;
} StringRef;

static int fuzzy_streq(const char *s1, size_t len1, const char *s2, size_t len2) {
    size_t i = 0, j = 0;
    while (i < len1 && j < len2) {
        while (i < len1 && isspace((unsigned char)s1[i])) i++;
        while (j < len2 && isspace((unsigned char)s2[j])) j++;

        if (i == len1 || j == len2) break;
        if (s1[i] != s2[j]) return 0;
        i++; j++;
    }

    while (i < len1 && isspace((unsigned char)s1[i])) i++;
    while (j < len2 && isspace((unsigned char)s2[j])) j++;

    return (i == len1 && j == len2);
}

static StringRef* extract_string_array(lua_State *L, int index, size_t *count) {
    *count = lua_rawlen(L, index);
    if (*count == 0) return NULL;

    StringRef *arr = (StringRef*)malloc(*count * sizeof(StringRef));
    if (!arr) return NULL;

    for (size_t i = 0; i < *count; i++) {
        lua_rawgeti(L, index, i + 1); /* Lua arrays are 1-indexed */
        arr[i].str = lua_tolstring(L, -1, &arr[i].len);
        lua_pop(L, 1);
    }
    return arr;
}

static int l_find_unique_fuzzy_block(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TTABLE);

    size_t content_count = 0, search_count = 0;

    StringRef *content = extract_string_array(L, 1, &content_count);
    StringRef *search = extract_string_array(L, 2, &search_count);

    if (!content || !search || search_count == 0) {
        if (content) free(content);
        if (search) free(search);
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, "Empty search block");
        return 3;
    }

    if (content_count < search_count) {
        if (content) free(content);
        free(search);
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, "File shorter than search block");
        return 3;
    }

    size_t match_start = 0;
    int match_count = 0;

    for (size_t i = 0; i <= content_count - search_count; i++) {
        int is_match = 1;
        for (size_t j = 0; j < search_count; j++) {
            if (!fuzzy_streq(content[i + j].str, content[i + j].len, 
                             search[j].str, search[j].len)) {
                is_match = 0;
                break;
            }
        }
        if (is_match) {
            match_start = i;
            match_count++;
        }
    }

    free(content);
    free(search);

    if (match_count == 0) {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, "Block not found");
        return 3;
    } else if (match_count > 1) {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, "AMBIGUOUS MATCH: Found multiple occurrences of this block.");
        return 3;
    }

    lua_pushinteger(L, match_start + 1);
    lua_pushinteger(L, match_start + search_count);
    return 2;
}

/* --- POSIX SIGNAL HANDLING --- */
static volatile sig_atomic_t sigint_flag = 0;
static struct timespec last_sigint_ts = {0, 0};

static void handle_sigint(int sig) {
    (void)sig;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    if (last_sigint_ts.tv_sec != 0 || last_sigint_ts.tv_nsec != 0) {
        long diff_ms = (long)(now.tv_sec - last_sigint_ts.tv_sec) * 1000 +
                       (long)((now.tv_nsec - last_sigint_ts.tv_nsec) / 1000000);
        if (diff_ms < 500) {
            _exit(1);
        }
    }

    last_sigint_ts = now;
    sigint_flag = 1;
}

static int l_setup_sigint() {
    struct sigaction sa;
    sa.sa_handler = handle_sigint;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0; 
    sigaction(SIGINT, &sa, NULL);
    return 0;
}

static int l_consume_sigint(lua_State *L) {
    lua_pushboolean(L, sigint_flag);
    sigint_flag = 0; 
    return 1;
}

/* --- ESC KEY MONITOR THREAD --- */
static volatile sig_atomic_t esc_flag = 0;
static pthread_t esc_thread_id;
static volatile int esc_monitor_active = 0;
static int esc_tty_fd = -1;

static void handle_sigusr1(int sig) {
    (void)sig;
    /* No-op handler just to wake the thread from pause/select if needed */
}

static void *esc_monitor_routine(void *arg) {
    (void)arg;
    
    /* Open /dev/tty for direct terminal access, fallback to stdin */
    esc_tty_fd = open("/dev/tty", O_RDONLY);
    if (esc_tty_fd < 0) {
        esc_tty_fd = dup(STDIN_FILENO);
    }
    
    if (esc_tty_fd < 0 || !isatty(esc_tty_fd)) {
        /* Not a terminal, nothing to monitor */
        if (esc_tty_fd >= 0) close(esc_tty_fd);
        esc_tty_fd = -1;
        return NULL;
    }

    /* Set non-blocking mode via fcntl */
    int flags = fcntl(esc_tty_fd, F_GETFL, 0);
    fcntl(esc_tty_fd, F_SETFL, flags | O_NONBLOCK);

    /* Monitor loop: poll with select() every 100ms */
    while (esc_monitor_active) {
        fd_set rfds;
        struct timeval tv;
        FD_ZERO(&rfds);
        FD_SET(esc_tty_fd, &rfds);
        tv.tv_sec = 0;
        tv.tv_usec = 100000; // poll every 100ms

        int ret = select(esc_tty_fd + 1, &rfds, NULL, NULL, &tv);
        if (ret > 0) {
            unsigned char buf[16];
            ssize_t n = read(esc_tty_fd, buf, sizeof(buf));
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == 0x1B) {
                    /* ESC key detected */
                    esc_flag = 1;
                    kill(getpid(), SIGUSR1);
                    goto done;
                }
            }
        }
    }
done:
    
    if (esc_tty_fd >= 0) {
        close(esc_tty_fd);
        esc_tty_fd = -1;
    }
    
    return NULL;
}

static int l_setup_esc_monitor(lua_State *L) {
    /* Setup SIGUSR1 handler */
    struct sigaction sa;
    sa.sa_handler = handle_sigusr1;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGUSR1, &sa, NULL);
    
    /* Start the ESC monitor thread */
    esc_flag = 0;
    esc_monitor_active = 1;
    
    int rc = pthread_create(&esc_thread_id, NULL, esc_monitor_routine, NULL);
    if (rc != 0) {
        esc_monitor_active = 0;
        lua_pushboolean(L, 0);
        return 1;
    }
    
    lua_pushboolean(L, 1);
    return 1;
}

static int l_consume_esc(lua_State *L) {
    lua_pushboolean(L, esc_flag);
    esc_flag = 0;
    return 1;
}

static int l_teardown_esc_monitor(lua_State *L) {
    (void)L;
    esc_monitor_active = 0;
    
    /* Wake the thread if it's blocked on read */
    if (esc_tty_fd >= 0) {
        pthread_kill(esc_thread_id, SIGUSR1);
    }
    
    /* Wait for thread to finish */
    pthread_join(esc_thread_id, NULL);
    
    return 0;
}

static const struct luaL_Reg patcher_core_funcs[] = {
    {"find_unique_fuzzy_block", l_find_unique_fuzzy_block},
    {"setup_sigint", l_setup_sigint},
    {"consume_sigint", l_consume_sigint},
    {"setup_esc_monitor", l_setup_esc_monitor},
    {"consume_esc", l_consume_esc},
    {"teardown_esc_monitor", l_teardown_esc_monitor},
    {NULL, NULL}
};

int luaopen_patcher_core(lua_State *L) {
    luaL_newlib(L, patcher_core_funcs);
    return 1;
}