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

#if LUA_VERSION_NUM < 502
#define luaL_newlib(L, l) (lua_newtable(L), luaL_register(L, NULL, l))
#endif

#define MCP_PROC_MT "MCP_Process_Meta"

typedef struct {
    FILE *in;
    FILE *out;
    pid_t pid;
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
        close(pipe_in[1]);
        close(pipe_out[0]);
        dup2(pipe_in[0], STDIN_FILENO);
        dup2(pipe_out[1], STDOUT_FILENO);
        close(pipe_in[0]);
        close(pipe_out[1]);
        
        execl("/bin/sh", "sh", "-c", cmd, NULL);
        _exit(127);
    }

    close(pipe_in[0]);
    close(pipe_out[1]);

    MCP_Process *proc = (MCP_Process*)lua_newuserdata(L, sizeof(MCP_Process));
    proc->pid = pid;
    proc->in = fdopen(pipe_in[1], "w");
    proc->out = fdopen(pipe_out[0], "r");

    luaL_getmetatable(L, MCP_PROC_MT);
    lua_setmetatable(L, -2);

    return 1;
}

static int l_mcp_write(lua_State *L) {
    MCP_Process *proc = (MCP_Process*)luaL_checkudata(L, 1, MCP_PROC_MT);
    const char *payload = luaL_checkstring(L, 2);
    
    if (proc->in) {
        fprintf(proc->in, "%s\n", payload);
        fflush(proc->in);
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushnil(L);
    lua_pushstring(L, "Pipe is closed");
    return 2;
}

static int l_mcp_read(lua_State *L) {
    MCP_Process *proc = (MCP_Process*)luaL_checkudata(L, 1, MCP_PROC_MT);
    if (!proc || !proc->out) {
        lua_pushnil(L);
        return 1;
    }

    char *line = NULL;
    size_t len = 0;
    
    ssize_t read_bytes = getline(&line, &len, proc->out);
    
    if (read_bytes != -1) {
        lua_pushlstring(L, line, read_bytes);
        free(line);
        return 1;
    }

    if (line) free(line);
    lua_pushnil(L);
    return 1;
}

static int l_mcp_gc(lua_State *L) {
    MCP_Process *proc = (MCP_Process*)luaL_checkudata(L, 1, MCP_PROC_MT);
    if (proc->in) { fclose(proc->in); proc->in = NULL; }
    if (proc->out) { fclose(proc->out); proc->out = NULL; }
    if (proc->pid > 0) {
        kill(proc->pid, SIGTERM);
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
