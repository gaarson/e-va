-- ui/input.lua
local colors  = require('ui.colors')
local strings = require('utils.strings')
local tty     = require('ui.tty')
local M = {}

-- ============================================================================
-- UTF-8 HELPERS
-- ============================================================================
M._utf8 = {}
function M._utf8.char_len_at(s, pos)
    if pos > #s then return 0 end
    local c = s:byte(pos)
    if c < 0x80 then return 1
    elseif c < 0xE0 then return 2
    elseif c < 0xF0 then return 3
    else return 4 end
end
function M._utf8.char_count(s)
    local count, i = 0, 1
    while i <= #s do
        count = count + 1
        i = i + M._utf8.char_len_at(s, i)
    end
    return count
end
function M._utf8.visible_len(s)
    return M._utf8.char_count(s)
end
function M._utf8.byte_pos_of_char(s, char_idx)
    local bpos, cidx = 1, 1
    while cidx < char_idx and bpos <= #s do
        bpos = bpos + M._utf8.char_len_at(s, bpos)
        cidx = cidx + 1
    end
    return bpos
end
function M._utf8.remove_char_at(s, char_idx)
    local bpos = M._utf8.byte_pos_of_char(s, char_idx)
    local clen = M._utf8.char_len_at(s, bpos)
    if clen == 0 then return s end
    return s:sub(1, bpos - 1) .. s:sub(bpos + clen)
end
function M._utf8.insert_char_at(s, char_idx, char_bytes)
    local bpos = M._utf8.byte_pos_of_char(s, char_idx)
    return s:sub(1, bpos - 1) .. char_bytes .. s:sub(bpos)
end

-- ============================================================================
-- INPUT HISTORY
-- ============================================================================
M._history_module = {
    items = {},
    cap = 50,
}
function M._history_module.save(text)
    if not text or strings.trim(text) == '' then return end
    local last = M._history_module.items[#M._history_module.items]
    if last ~= text then
        table.insert(M._history_module.items, text)
        while #M._history_module.items > M._history_module.cap do
            table.remove(M._history_module.items, 1)
        end
    end
end
function M._history_module.clear()
    M._history_module.items = {}
end

-- ============================================================================
-- TTY CONTROL
-- ============================================================================
local function _tty_raw_enable()
    os.execute('stty raw -echo -icanon min 1 time 0 2>/dev/null')
end
local function _tty_restore()
    os.execute('stty sane 2>/dev/null')
end
--- Drains any pending bytes from the stdin buffer.
-- In non-TTY mode this is a no-op. In TTY mode, temporarily sets
-- the terminal to non-blocking mode, reads and discards all pending
-- bytes, then restores the terminal settings.
function M.flush_input()
    if not tty.is_tty then return end
    pcall(function()
        os.execute('stty raw -echo -icanon min 0 time 0 2>/dev/null')
        -- Drain stdin via shell to bypass Lua stdio buffer caching
        os.execute('while IFS= read -r -n1 -t 0.05 ch; do :; done 2>/dev/null')
        -- Also drain any bytes cached in Lua's internal stdio buffer
        while true do
            local ch = io.read(1)
            if ch == nil then break end
        end
        os.execute('stty sane 2>/dev/null')
    end)
end
local function _get_term_size()
    local f = io.popen('stty size 2>/dev/null')
    if f then
        local sz = f:read('*l')
        f:close()
        if sz then
            local rows, cols = sz:match('(%d+)%s+(%d+)')
            if rows and cols and tonumber(cols) > 0 and tonumber(rows) > 0 then
                return tonumber(cols), tonumber(rows)
            end
        end
    end
    return 80, 24
end

-- ============================================================================
-- REDRAW HELPERS (RELATIVE COORDINATES)
-- ============================================================================
local function _full_redraw(state, term_width, term_height)
    local utf8 = M._utf8
    
    local all_lines = {}
    for _, l in ipairs(state.lines) do table.insert(all_lines, l) end
    local cur_line_idx = #all_lines + 1
    table.insert(all_lines, state.cur_line)
    for _, l in ipairs(state.lines_below) do table.insert(all_lines, l) end

    local screen_lines = {}
    local cursor_screen_row = 1
    local cursor_screen_col = 1
    
    for i, line in ipairs(all_lines) do
        local chars = {}
        local bpos = 1
        while bpos <= #line do
            local clen = utf8.char_len_at(line, bpos)
            table.insert(chars, line:sub(bpos, bpos + clen - 1))
            bpos = bpos + clen
        end
        
        if #chars == 0 then
            table.insert(screen_lines, "")
            if i == cur_line_idx then
                cursor_screen_row = #screen_lines
                cursor_screen_col = 1
            end
        else
            local current_chunk = ""
            local chunk_len = 0
            
            for c_idx = 1, #chars + 1 do
                if i == cur_line_idx and c_idx == state.cur_pos then
                    cursor_screen_row = #screen_lines + 1
                    cursor_screen_col = chunk_len + 1
                end
                
                if c_idx <= #chars then
                    current_chunk = current_chunk .. chars[c_idx]
                    chunk_len = chunk_len + 1
                    
                    if chunk_len == term_width then
                        table.insert(screen_lines, current_chunk)
                        current_chunk = ""
                        chunk_len = 0
                    end
                end
            end
            
            if chunk_len > 0 then
                table.insert(screen_lines, current_chunk)
            elseif current_chunk == "" and (i == cur_line_idx and state.cur_pos == #chars + 1) then
                 table.insert(screen_lines, "")
            end
        end
    end

    local total_rows = #screen_lines
    state.scroll_top = state.scroll_top or 1

    if total_rows <= term_height then
        state.scroll_top = 1
    else
        if cursor_screen_row < state.scroll_top then
            state.scroll_top = cursor_screen_row
        elseif cursor_screen_row >= state.scroll_top + term_height then
            state.scroll_top = cursor_screen_row - term_height + 1
        end
    end

    local start_idx = state.scroll_top
    local end_idx = math.min(total_rows, state.scroll_top + term_height - 1)
    
    local visible_rows = end_idx - start_idx + 1
    local visible_cursor_row = cursor_screen_row - state.scroll_top + 1

    io.write('\27[?25l') -- Прячем курсор от мерцания
    
    -- Поднимаемся к началу области отрисовки (относительное перемещение)
    if state.drawn_cursor_row and state.drawn_cursor_row > 1 then
        io.write(string.format('\27[%dA', state.drawn_cursor_row - 1))
    end
    io.write('\r') -- В первую колонку
    
    -- Рисуем все строки окна
    for i = start_idx, end_idx do
        io.write(screen_lines[i])
        io.write('\27[K') -- Очищаем хвост строки
        if i < end_idx then
            io.write('\r\n')
        end
    end
    
    -- Зачищаем весь мусор ниже нашей рабочей области
    io.write('\27[J')
    
    -- Курсор сейчас на последней отрисованной строке. Поднимаем его на нужное место
    local move_up = visible_rows - visible_cursor_row
    if move_up > 0 then
        io.write(string.format('\27[%dA', move_up))
    end
    
    -- Двигаем вправо
    if cursor_screen_col > 1 then
        io.write(string.format('\27[%dG', cursor_screen_col))
    else
        io.write('\r')
    end
    
    io.write('\27[?25h') -- Возвращаем курсор
    io.stdout:flush()

    -- Запоминаем текущее состояние для следующей перерисовки
    state.drawn_rows = visible_rows
    state.drawn_cursor_row = visible_cursor_row
end

-- ============================================================================
-- BYTE PROCESSOR 
-- ============================================================================
function M._process_byte(state, b, utf8, term_width)
    state.print_char = nil
    state.result = nil

    local lines       = state.lines
    local lines_below = state.lines_below
    local cur_line    = state.cur_line
    local cur_pos     = state.cur_pos
    local esc_state   = state.esc_state
    local esc_buf     = state.esc_buf

    local last_b = state.last_byte
    state.last_byte = b

    if esc_state == 3 then
        if b == 126 then  -- '~'
            local code = esc_buf
            state.esc_state = 0
            state.esc_buf = ""
            
            if code == "200" then return 'start_paste'
            elseif code == "201" then return 'end_paste'
            elseif code == "1" or code == "7" then
                state.cur_pos = 1
                return 'redraw'
            elseif code == "4" or code == "8" then
                state.cur_pos = utf8.char_count(cur_line) + 1
                return 'redraw'
            elseif code == "3" then  -- Delete
                if cur_pos <= utf8.char_count(cur_line) then
                    state.cur_line = utf8.remove_char_at(cur_line, cur_pos)
                    return 'redraw'
                elseif #lines_below > 0 then
                    local next_line = table.remove(lines_below, 1)
                    state.cur_line = cur_line .. next_line
                    return 'redraw'
                end
            end
        elseif b >= 48 and b <= 59 then
            state.esc_buf = esc_buf .. string.char(b)
        else
            state.esc_state = 0
            state.esc_buf = ""
        end
        return nil
    end

    if esc_state == 2 then
        state.esc_state = 0
        if b == 65 then  -- Up
            if #lines > 0 then
                table.insert(lines_below, 1, cur_line)
                state.cur_line = table.remove(lines)
                local ccount = utf8.char_count(state.cur_line)
                if state.cur_pos > ccount + 1 then state.cur_pos = ccount + 1 end
                return 'redraw'
            else
                if state.hist_idx == 0 then
                    state.hist_branch = cur_line
                    state.hist_branch_lines = {}
                    for _, l in ipairs(lines) do table.insert(state.hist_branch_lines, l) end
                    state.hist_branch_below = {}
                    for _, l in ipairs(lines_below) do table.insert(state.hist_branch_below, l) end
                    state.hist_idx = #M._history_module.items
                elseif state.hist_idx > 1 then
                    state.hist_idx = state.hist_idx - 1
                end
                
                if state.hist_idx > 0 and state.hist_idx <= #M._history_module.items then
                    local hist_str = M._history_module.items[state.hist_idx]
                    state.lines = {}
                    local start = 1
                    while true do
                        local pos = string.find(hist_str, '\n', start, true)
                        if not pos then
                            table.insert(state.lines, string.sub(hist_str, start))
                            break
                        end
                        table.insert(state.lines, string.sub(hist_str, start, pos - 1))
                        start = pos + 1
                    end
                    if #state.lines > 0 then state.cur_line = table.remove(state.lines) else state.cur_line = "" end
                    state.lines_below = {}
                    state.cur_pos  = utf8.char_count(state.cur_line) + 1
                end
                return 'redraw'
            end
        elseif b == 66 then  -- Down
            if #lines_below > 0 then
                table.insert(lines, cur_line)
                state.cur_line = table.remove(lines_below, 1)
                local ccount = utf8.char_count(state.cur_line)
                if state.cur_pos > ccount + 1 then state.cur_pos = ccount + 1 end
                return 'redraw'
            else
                if state.hist_idx > 0 then
                    if state.hist_idx < #M._history_module.items then
                        state.hist_idx = state.hist_idx + 1
                        local hist_str = M._history_module.items[state.hist_idx]
                        state.lines = {}
                        local start = 1
                        while true do
                            local pos = string.find(hist_str, '\n', start, true)
                            if not pos then table.insert(state.lines, string.sub(hist_str, start)); break end
                            table.insert(state.lines, string.sub(hist_str, start, pos - 1))
                            start = pos + 1
                        end
                        if #state.lines > 0 then state.cur_line = table.remove(state.lines) else state.cur_line = "" end
                        state.lines_below = {}
                        state.cur_pos  = utf8.char_count(state.cur_line) + 1
                    else
                        state.hist_idx = 0
                        state.cur_line = state.hist_branch or ""
                        state.lines = state.hist_branch_lines or {}
                        state.lines_below = state.hist_branch_below or {}
                        state.cur_pos  = utf8.char_count(state.cur_line) + 1
                    end
                    return 'redraw'
                end
            end
        elseif b == 67 then  -- Right
            if cur_pos <= utf8.char_count(cur_line) then
                state.cur_pos = cur_pos + 1
                return 'redraw'
            elseif #lines_below > 0 then
                table.insert(lines, cur_line)
                state.cur_line = table.remove(lines_below, 1)
                state.cur_pos = 1
                return 'redraw'
            end
        elseif b == 68 then  -- Left
            if cur_pos > 1 then
                state.cur_pos = cur_pos - 1
                return 'redraw'
            elseif #lines > 0 then
                table.insert(lines_below, 1, cur_line)
                state.cur_line = table.remove(lines)
                state.cur_pos = utf8.char_count(state.cur_line) + 1
                return 'redraw'
            end
        elseif b == 72 then  -- Home
            state.cur_pos = 1
            return 'redraw'
        elseif b == 70 then  -- End
            state.cur_pos = utf8.char_count(cur_line) + 1
            return 'redraw'
        elseif b >= 48 and b <= 57 then
            state.esc_state = 3
            state.esc_buf = string.char(b)
        elseif b == 91 then
            state.esc_state = 2
        end
        return nil
    end

    if esc_state == 1 then
        state.esc_state = 0
        if b == 91 then state.esc_state = 2
        elseif b == 79 then state.esc_state = 2 end
        return nil
    end

    if b == 27 then  -- ESC
        state.esc_state = 1
        return nil
    elseif b == 3 then  -- Ctrl+C
        return 'cancel'
    elseif b == 4 then  -- Ctrl+D: submit
        if state.cur_line ~= "" then table.insert(lines, state.cur_line) end
        state.cur_line = ""
        for _, l in ipairs(lines_below) do table.insert(lines, l) end
        state.lines_below = {}
        state.result = table.concat(lines, '\n')
        local trimmed = strings.trim(state.result)
        if trimmed ~= '' then M._history_module.save(state.result) end
        return 'submit'
    elseif b == 13 or b == 10 then  -- Enter
        if b == 10 and last_b == 13 then return nil end
        
        local prefix = string.sub(cur_line, 1, utf8.byte_pos_of_char(cur_line, cur_pos) - 1)
        local suffix = string.sub(cur_line, utf8.byte_pos_of_char(cur_line, cur_pos))
        
        table.insert(lines, prefix)
        state.cur_line = suffix
        state.cur_pos  = 1
        state.hist_idx = 0
        state.hist_branch = nil
        return 'redraw'
    elseif b == 127 or b == 8 then  -- Backspace
        if cur_pos > 1 then
            state.cur_line = utf8.remove_char_at(cur_line, cur_pos - 1)
            state.cur_pos  = cur_pos - 1
            return 'redraw'
        elseif #lines > 0 then
            local prev = table.remove(lines)
            state.cur_pos = utf8.char_count(prev) + 1
            state.cur_line = prev .. cur_line
            return 'redraw'
        end
        return nil
    elseif b >= 32 and b < 127 then
        if state.hist_idx > 0 then state.hist_idx = 0; state.hist_branch = nil end
        state.cur_line = utf8.insert_char_at(cur_line, cur_pos, string.char(b))
        state.cur_pos = cur_pos + 1
        return 'redraw'
    elseif b >= 128 then
        return 'multibyte_pending'
    end
    return nil
end

function M._process_sequence(state, bytes, utf8, term_width)
    if #bytes > 0 and bytes:byte(1) >= 128 then
        if state.hist_idx > 0 then state.hist_idx = 0; state.hist_branch = nil end
        state.cur_line = utf8.insert_char_at(state.cur_line, state.cur_pos, bytes)
        state.cur_pos = state.cur_pos + 1
        return 'redraw'
    end
    local last_action = nil
    for i = 1, #bytes do
        last_action = M._process_byte(state, bytes:byte(i), utf8, term_width)
    end
    return last_action
end

-- ============================================================================
-- READ TEXT
-- ============================================================================
function M.read_text(prompt, prompt_color)
    prompt_color = prompt_color or colors.cyan
    local utf8 = M._utf8

    if not tty.is_tty then
        io.write(prompt_color .. prompt .. colors.reset)
        io.write(colors.dim .. ' (Ctrl+D submit, Ctrl+C cancel)' .. colors.reset .. '\n')
        io.stdout:flush()
        local lines = {}
        while true do
            local line = io.read('*l')
            if line == nil then break end
            table.insert(lines, line)
        end
        local result = table.concat(lines, '\n')
        local trimmed = strings.trim(result)
        if trimmed ~= '' then
            M._history_module.save(result)
            return result
        end
        return ""  
    end

    _tty_raw_enable()
    local ok, result = pcall(function()
        io.write('\27[?2004h')
        io.write(prompt_color .. prompt .. colors.reset)
        io.write(colors.dim .. ' (Ctrl+D submit, Ctrl+C cancel)' .. colors.reset .. '\r\n')
        io.stdout:flush()

        local term_width, term_height = _get_term_size()

        local state = {
            lines       = {},
            lines_below = {},
            cur_line    = "",
            cur_pos     = 1,
            esc_state   = 0,
            esc_buf     = "",
            hist_idx    = 0,
            hist_branch = nil,
            scroll_top  = 1,
            last_byte   = nil,
            is_pasting  = false,
            drawn_rows  = 0,
            drawn_cursor_row = 1,
        }

        -- Первичная отрисовка пустой строки ввода
        _full_redraw(state, term_width, term_height)

        while true do
            local ch = io.read(1)
            if ch == nil then break end
            if ch == '' then
                -- empty read, skip
            else
                local b = ch:byte(1)
                if b then
                    if b >= 128 then
                        local expected_len
                        if b < 0xE0 then expected_len = 2
                        elseif b < 0xF0 then expected_len = 3
                        else expected_len = 4 end
                        local char_bytes = string.char(b)
                        for i = 2, expected_len do
                            local nb = io.read(1)
                            if nb then char_bytes = char_bytes .. nb else break end
                        end
                        local action = M._process_sequence(state, char_bytes, utf8, term_width)
                        if not state.is_pasting and action == 'redraw' then
                            _full_redraw(state, term_width, term_height)
                        end
                    else
                        local action = M._process_byte(state, b, utf8, term_width)
                        if action == 'submit' then
                            if state.cur_line ~= "" then table.insert(state.lines, state.cur_line) end
                            for _, l in ipairs(state.lines_below) do table.insert(state.lines, l) end
                            local result = table.concat(state.lines, '\n')
                            local trimmed = strings.trim(result)
                            if trimmed ~= '' then M._history_module.save(result) end
                            return result
                        elseif action == 'cancel' then
                            io.write('\r\n')
                            return nil
                        elseif action == 'start_paste' then
                            state.is_pasting = true
                        elseif action == 'end_paste' then
                            state.is_pasting = false
                            _full_redraw(state, term_width, term_height)
                        elseif not state.is_pasting and action == 'redraw' then
                            _full_redraw(state, term_width, term_height)
                        end
                    end
                end
            end
        end

        if state.cur_line ~= "" then table.insert(state.lines, state.cur_line) end
        for _, l in ipairs(state.lines_below) do table.insert(state.lines, l) end
        local result = table.concat(state.lines, '\n')
        local trimmed = strings.trim(result)
        if trimmed ~= '' then
            M._history_module.save(result)
            return result
        end
        return ""
    end)
    
    _tty_restore()
    io.write('\27[?2004l') 
    io.stdout:flush()
    
    if ok then
        return result
    else
        io.write('\r\n' .. colors.red .. '[INPUT ERROR] ' .. tostring(result) .. colors.reset .. '\r\n')
        return nil
    end
end

-- ============================================================================
-- ОСТАЛЬНЫЕ ФУНКЦИИ БЕЗ ИЗМЕНЕНИЙ
-- ============================================================================
function M.read_line(prompt, prompt_color)
    M.flush_input()
    prompt_color = prompt_color or colors.cyan
    io.write(prompt_color .. prompt .. colors.reset)
    io.stdout:flush()
    local line = io.read('*l')
    if line and strings.trim(line) ~= '' then M._history_module.save(line) end
    return line
end

function M.read_non_empty(prompt, prompt_color)
    prompt_color = prompt_color or colors.cyan
    local result
    repeat
        result = M.read_line(prompt, prompt_color)
        if not result or strings.trim(result) == '' then return nil end
    until strings.trim(result) ~= ''
    return result
end

function M.confirm(prompt, default)
    M.flush_input()
    if tty.is_tty then os.execute('stty icanon echo min 1 time 0 2>/dev/null') end
    default = default or 'n'
    local choices = default == 'y' and '[Y/n]' or '[y/N]'
    io.write(colors.cyan .. prompt .. ' ' .. choices .. ': ' .. colors.reset)
    io.stdout:flush()
    local ans = io.read('*l')
    if ans then
        -- Strip control characters (backspace 0x7F, DEL, etc.) that may leak from stdio buffer
        ans = ans:gsub('%c', '')
    end
    if not ans or strings.trim(ans) == '' then ans = default end
    return ans:lower():sub(1, 1) == 'y'
end
function M.confirm_with_reason(prompt, default)
    M.flush_input()
    if tty.is_tty then os.execute('stty icanon echo min 1 time 0 2>/dev/null') end
    default = default or 'n'
    local choices = default == 'y' and '[Y/n]' or '[y/N]'
    io.write(colors.cyan .. prompt .. ' ' .. choices .. ' (or type reason to deny): ' .. colors.reset)
    io.stdout:flush()
    local ans = io.read('*l')
    if ans then
        ans = ans:gsub('%c', '')
    end
    if not ans or strings.trim(ans) == '' then ans = default end
    local lower = ans:lower()
    if lower == 'y' or lower == 'yes' then
        return {allowed = true, reason = nil}
    elseif lower == 'n' or lower == 'no' then
        return {allowed = false, reason = 'User declined'}
    else
        return {allowed = false, reason = strings.trim(ans)}
    end
end
function M.select_from_options(prompt, options)
    print(colors.cyan .. prompt .. colors.reset)
    for i, opt in ipairs(options) do print(string.format('  %d. %s', i, opt)) end
    local choice = M.read_line('Select option number: ')
    local idx = tonumber(choice)
    if idx and idx >= 1 and idx <= #options then return idx, options[idx] end
    return nil, nil
end

return M