#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <signal.h>

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

    if (!search || search_count == 0) {
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

static void handle_sigint(int sig) {
    (void)sig;
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

static const struct luaL_Reg patcher_core_funcs[] = {
    {"find_unique_fuzzy_block", l_find_unique_fuzzy_block},
    {"setup_sigint", l_setup_sigint},
    {"consume_sigint", l_consume_sigint},
    {NULL, NULL}
};

int luaopen_patcher_core(lua_State *L) {
    luaL_newlib(L, patcher_core_funcs);
    return 1;
}
