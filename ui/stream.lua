local tty = require('ui.tty')
local M = {}
local _is_tty = tty.is_tty

-- ============================================================================
-- CENTRALIZED STREAM TOKEN PRINTER (TTY-AWARE)
-- ============================================================================
function M.stream_token_printer(agent_cfg)
    local print_buf = ""
    local in_thought = (agent_cfg and agent_cfg.is_reasoning) or false
    local tag_open = "<thinking>"
    local tag_close = "</thinking>"

    -- Helper: strip ANSI escape codes if not TTY
    local function strip_ansi(text)
        if _is_tty then
            return text
        end
        return (text:gsub("\27%[[^%a]*%a", ""))
    end
    -- Initial color setup
    if in_thought and _is_tty then
        io.write("\27[90m")
    end

    local function flush_remaining()
        if #print_buf > 0 then
            local output = print_buf
            if _is_tty then
                if in_thought then
                    output = output .. "\27[0m"
                end
            else
                output = strip_ansi(output)
            end
            io.write(output)
            print_buf = ""
        end
        io.write("\n")
        io.stdout:flush()
    end

    local FLUSH_THRESHOLD = 100
    local chars_since_flush = 0

    local function on_token(t)
        print_buf = print_buf .. t
        chars_since_flush = chars_since_flush + #t

        while #print_buf > 0 do
            if not in_thought then
                local s, e = print_buf:find(tag_open)
                if s then
                    local prefix = print_buf:sub(1, s - 1)
                    if _is_tty then
                        io.write(prefix .. "\27[90m" .. tag_open)
                    else
                        io.write(prefix .. tag_open)
                    end
                    io.stdout:flush()
                    print_buf = print_buf:sub(e + 1)
                    chars_since_flush = chars_since_flush - (s - 1 + #tag_open)
                    in_thought = true
                elseif chars_since_flush >= FLUSH_THRESHOLD or #print_buf > #tag_open then
                    local safe_len = math.min(#print_buf, #print_buf - #tag_open)
                    if safe_len <= 0 then safe_len = #print_buf end
                    
                    local chunk = print_buf:sub(1, safe_len)
                    if not _is_tty then
                        chunk = strip_ansi(chunk)
                    end
                    io.write(chunk)
                    io.stdout:flush()
                    chars_since_flush = chars_since_flush - safe_len
                    print_buf = print_buf:sub(safe_len + 1)
                else
                    break
                end
            else
                local s, e = print_buf:find(tag_close)
                if s then
                    local prefix = print_buf:sub(1, s - 1)
                    if _is_tty then
                        io.write(prefix .. tag_close .. "\27[0m")
                    else
                        io.write(prefix .. tag_close)
                    end
                    io.stdout:flush()
                    print_buf = print_buf:sub(e + 1)
                    chars_since_flush = chars_since_flush - (s - 1 + #tag_close)
                    in_thought = false
                elseif chars_since_flush >= FLUSH_THRESHOLD or #print_buf > #tag_close then
                    local safe_len = math.min(#print_buf, #print_buf - #tag_close)
                    if safe_len <= 0 then safe_len = #print_buf end

                    local chunk = print_buf:sub(1, safe_len)
                    if not _is_tty then
                        chunk = strip_ansi(chunk)
                    end
                    io.write(chunk)
                    io.stdout:flush()
                    chars_since_flush = chars_since_flush - safe_len
                    print_buf = print_buf:sub(safe_len + 1)
                else
                    break
                end
            end
        end
    end

    local printer = {
        on_token = on_token,
        flush = flush_remaining,
    }
    setmetatable(printer, { __call = function(_, t) on_token(t) end })
    return printer
end

-- Flush any remaining buffered text after streaming completes.
local _last_printer = nil
function M.flush_stream_buffer(printer_or_buf, in_thought_flag)
    if type(printer_or_buf) == "table" and type(printer_or_buf.flush) == "function" then
        _last_printer = printer_or_buf
        printer_or_buf:flush()
        return "", false
    end
    if type(printer_or_buf) == "string" and #printer_or_buf > 0 then
        local output = printer_or_buf
        if not _is_tty then
            output = (output:gsub("\27%[[^%a]*%a", ""))
        else
            if in_thought_flag then
                output = output .. "\27[0m\n"
            else
                output = output .. "\n"
            end
        end
        io.write(output)
        io.stdout:flush()
        return printer_or_buf, in_thought_flag
    end
    if _last_printer and type(_last_printer.flush) == "function" then
        _last_printer:flush()
        return "", false
    end
    io.write("\n")
    io.stdout:flush()
    return "", false
end

return M