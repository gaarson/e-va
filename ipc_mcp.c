#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <string.h>
#include <sys/select.h>
#include <fcntl.h>
#include <time.h>

#if LUA_VERSION_NUM < 502
#define luaL_newlib(L, l) (lua_newtable(L), luaL_register(L, NULL, l))
#endif

#define MCP_PROC_MT "MCP_Process_Meta"

typedef struct {
    int in_fd;
    int out_fd;
    pid_t pid;
    // Внутренний буфер для чтения строк (защита от partial reads)
    char *buf;
    size_t buf_len;
    size_t buf_cap;
} MCP_Process;

static int l_spawn_mcp(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);

    int pipe_in[2];
    int pipe_out[2];

    if (pipe(pipe_in) < 0 || pipe(pipe_out) < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "System Error: Failed to create pipes");
        return 2;
    }

    pid_t pid = fork();
    if (pid < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "System Error: Fork failed");
        return 2;
    }

    if (pid == 0) {
        // --- CHILD PROCESS ---
        // Создаем новую сессию, чтобы kill(-pid) убил ВСЕ дерево процессов (sh -> node -> mcp)
        setsid(); 
        
        close(pipe_in[1]);
        close(pipe_out[0]);
        
        dup2(pipe_in[0], STDIN_FILENO);
        dup2(pipe_out[1], STDOUT_FILENO);
        dup2(pipe_out[1], STDERR_FILENO); // ВАЖНО: Пробрасываем ошибки MCP в stdout!
        
        close(pipe_in[0]);
        close(pipe_out[1]);

        execl("/bin/sh", "sh", "-c", cmd, NULL);
        _exit(127);
    }

    // --- PARENT PROCESS ---
    close(pipe_in[0]);
    close(pipe_out[1]);

    MCP_Process *proc = (MCP_Process*)lua_newuserdata(L, sizeof(MCP_Process));
    proc->pid = pid;
    proc->in_fd = pipe_in[1];
    proc->out_fd = pipe_out[0];
    
    // Инициализация буфера
    proc->buf_cap = 8192;
    proc->buf = (char*)malloc(proc->buf_cap);
    proc->buf_len = 0;

    luaL_getmetatable(L, MCP_PROC_MT);
    lua_setmetatable(L, -2);

    return 1;
}

static int l_mcp_write(lua_State *L) {
    MCP_Process *proc = (MCP_Process*)luaL_checkudata(L, 1, MCP_PROC_MT);
    size_t len;
    const char *payload = luaL_checklstring(L, 2, &len);

    if (proc->in_fd >= 0) {
        // Пишем и добавляем \n (MCP stdio transport)
        write(proc->in_fd, payload, len);
        write(proc->in_fd, "\n", 1);
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushnil(L);
    lua_pushstring(L, "Pipe is closed");
    return 2;
}

static int l_mcp_read(lua_State *L) {
    MCP_Process *proc = (MCP_Process*)luaL_checkudata(L, 1, MCP_PROC_MT);
    if (!proc || proc->out_fd < 0) {
        lua_pushnil(L);
        return 1;
    }

    time_t start_time = time(NULL);
    int timeout_sec = 30;

    while (1) {
        // 1. Ищем \n в уже накопленном буфере
        char *nl = memchr(proc->buf, '\n', proc->buf_len);
        if (nl) {
            size_t line_len = nl - proc->buf + 1;
            lua_pushlstring(L, proc->buf, line_len);
            
            // Сдвигаем остаток буфера в начало
            memmove(proc->buf, nl + 1, proc->buf_len - line_len);
            proc->buf_len -= line_len;
            return 1;
        }

        // 2. Проверяем таймаут
        time_t now = time(NULL);
        int elapsed = difftime(now, start_time);
        if (elapsed >= timeout_sec) {
            lua_pushnil(L);
            lua_pushstring(L, "MCP Read Timeout (30s)");
            return 2;
        }

        // 3. Ждем данные через select
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(proc->out_fd, &fds);
        struct timeval tv = { .tv_sec = timeout_sec - elapsed, .tv_usec = 0 };

        int sel = select(proc->out_fd + 1, &fds, NULL, NULL, &tv);
        if (sel <= 0) {
            lua_pushnil(L);
            lua_pushstring(L, sel == 0 ? "Timeout" : "Select Error");
            return 2;
        }

        // 4. Читаем доступные данные в буфер
        if (proc->buf_len >= proc->buf_cap - 1) {
            // Реаллокация, если буфер переполнен (защита от огромных JSON)
            proc->buf_cap *= 2;
            proc->buf = (char*)realloc(proc->buf, proc->buf_cap);
        }

        ssize_t n = read(proc->out_fd, proc->buf + proc->buf_len, proc->buf_cap - proc->buf_len - 1);
        if (n <= 0) {
            lua_pushnil(L);
            if (n == 0) lua_pushstring(L, "EOF (MCP server died)");
            else lua_pushstring(L, "Read Error");
            return 2;
        }
        proc->buf_len += n;
    }
}

static int l_mcp_gc(lua_State *L) {
    MCP_Process *proc = (MCP_Process*)luaL_checkudata(L, 1, MCP_PROC_MT);
    if (proc->in_fd >= 0) { close(proc->in_fd); proc->in_fd = -1; }
    if (proc->out_fd >= 0) { close(proc->out_fd); proc->out_fd = -1; }
    
    if (proc->buf) { free(proc->buf); proc->buf = NULL; }
    
    if (proc->pid > 0) {
        // Убиваем ВСЮ группу процессов (благодаря setsid)
        kill(-proc->pid, SIGTERM); 
        waitpid(proc->pid, NULL, WNOHANG);
        proc->pid = -1;
    }
    return 0;
}

static const struct luaL_Reg ipc_funcs[] = {
    {"spawn_mcp", l_spawn_mcp},
    {"mcp_write", l_mcp_write},
    {"mcp_read", l_mcp_read},
    {NULL, NULL}
};

int luaopen_ipc_mcp(lua_State *L) {
    signal(SIGPIPE, SIG_IGN);
    luaL_newmetatable(L, MCP_PROC_MT);
    lua_pushcfunction(L, l_mcp_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
    luaL_newlib(L, ipc_funcs);
    return 1;
}
