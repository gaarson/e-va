-- test_shim.lua
-- Lua 5.4 compatibility shim for busted.
-- Добавляет метод :isatty() к io.stdout, io.stdin, io.stderr.
-- Использует luaposix если доступен, иначе fallback на os.execute.

local function _make_isatty(fd)
    -- Попытка 1: использовать luaposix (быстро, надёжно)
    local ok_posix, posix = pcall(require, 'posix')
    if ok_posix and posix and type(posix.isatty) == 'function' then
        return function()
            local ok, result = pcall(posix.isatty, fd)
            if ok then return result == true or result == 1 end
            return false
        end
    end

    -- Попытка 2: использовать luaposix.unistd (альтернативный путь)
    local ok_unistd, unistd = pcall(require, 'posix.unistd')
    if ok_unistd and unistd and type(unistd.isatty) == 'function' then
        return function()
            local ok, result = pcall(unistd.isatty, fd)
            if ok then return result == true or result == 1 end
            return false
        end
    end

    -- Попытка 3: shell fallback (работает всегда, но медленнее)
    return function()
        local result = os.execute(string.format('test -t %d 2>/dev/null', fd))
        if type(result) == 'boolean' then
            return result
        elseif type(result) == 'number' then
            return result == 0
        end
        return false
    end
end

-- Global fallback tables for Lua 5.4 (where FILE* userdata cannot be monkey-patched)
-- Tests can use _isatty.stdout(), _isatty.stdin(), _isatty.stderr()
-- and _fileno.stdout(), _fileno.stdin(), _fileno.stderr()
_G._isatty = {}
_G._fileno = {}
local function _make_fileno(fd)
    return function() return fd end
end
-- Attempt to monkey-patch io streams (works in LuaJIT, fails in Lua 5.4)
local function _try_patch(name, stream, fd)
    if not stream then return end
    -- Try isatty
    local ok_isatty = pcall(function()
        if not stream.isatty then
            stream.isatty = _make_isatty(fd)
        end
    end)
    -- Try fileno
    local ok_fileno = pcall(function()
        if not stream.fileno then
            stream.fileno = _make_fileno(fd)
        end
    end)
    -- If either failed, populate the global fallback tables
    if not ok_isatty or not ok_fileno then
        _isatty[name] = _make_isatty(fd)
        _fileno[name] = _make_fileno(fd)
    end
end
_try_patch('stdout', io.stdout, 1)
_try_patch('stderr', io.stderr, 2)
_try_patch('stdin', io.stdin, 0)
-- Ensure fallback tables are populated even if patching succeeded partially
if not _isatty.stdout and io.stdout then _isatty.stdout = _make_isatty(1) end
if not _isatty.stderr and io.stderr then _isatty.stderr = _make_isatty(2) end
if not _isatty.stdin and io.stdin then _isatty.stdin = _make_isatty(0) end
if not _fileno.stdout and io.stdout then _fileno.stdout = _make_fileno(1) end
if not _fileno.stderr and io.stderr then _fileno.stderr = _make_fileno(2) end
if not _fileno.stdin and io.stdin then _fileno.stdin = _make_fileno(0) end