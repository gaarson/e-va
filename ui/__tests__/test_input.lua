-- ui/__tests__/test_input.lua
-- Comprehensive tests for ui/input.lua pure/logical functions.
-- M.read_text requires a real TTY and is NOT tested here.
local assert = require('luassert')
local input  = require('ui.input')
local tty    = require('ui.tty')
local orig_is_tty = tty.is_tty
-- ============================================================================
-- UTF-8 HELPERS
-- ============================================================================
describe('ui/input.lua — UTF-8 helpers', function()
    describe('M._utf8.char_len_at(s, pos)', function()
        it('returns 1 for ASCII characters', function()
            assert.equals(1, input._utf8.char_len_at('Hello', 1))
            assert.equals(1, input._utf8.char_len_at('Hello', 5))
        end)
        it('returns 2 for 2-byte UTF-8 characters', function()
            assert.equals(2, input._utf8.char_len_at('é', 1))
        end)
        it('returns 3 for 3-byte UTF-8 characters', function()
            assert.equals(3, input._utf8.char_len_at('中', 1))
        end)
        it('returns 4 for 4-byte UTF-8 characters', function()
            assert.equals(4, input._utf8.char_len_at('🌍', 1))
        end)
        it('returns 0 when pos > #s', function()
            assert.equals(0, input._utf8.char_len_at('Hi', 5))
            assert.equals(0, input._utf8.char_len_at('', 1))
        end)
    end)
    describe('M._utf8.char_count(s)', function()
        it('returns 0 for empty string', function()
            assert.equals(0, input._utf8.char_count(''))
        end)
        it('counts ASCII characters correctly', function()
            assert.equals(5, input._utf8.char_count('Hello'))
        end)
        it('counts mixed UTF-8 characters correctly', function()
            assert.equals(11, input._utf8.char_count('Hello мир 🌍'))
        end)
        it('counts single multi-byte chars', function()
            assert.equals(1, input._utf8.char_count('🌍'))
            assert.equals(1, input._utf8.char_count('中'))
        end)
    end)
    describe('M._utf8.visible_len(s)', function()
        it('equals char_count for various strings', function()
            assert.equals(input._utf8.char_count('Hello'), input._utf8.visible_len('Hello'))
            assert.equals(input._utf8.char_count('Hello мир 🌍'), input._utf8.visible_len('Hello мир 🌍'))
            assert.equals(input._utf8.char_count(''), input._utf8.visible_len(''))
        end)
    end)
    describe('M._utf8.byte_pos_of_char(s, char_idx)', function()
        it('returns 1 for char_idx=1', function()
            assert.equals(1, input._utf8.byte_pos_of_char('Hello', 1))
            assert.equals(1, input._utf8.byte_pos_of_char('🌍', 1))
        end)
        it('finds byte position of middle character in mixed string', function()
            local s = 'Héllo'
            assert.equals(1, input._utf8.byte_pos_of_char(s, 1))
            assert.equals(2, input._utf8.byte_pos_of_char(s, 2))
            assert.equals(4, input._utf8.byte_pos_of_char(s, 3))
        end)
        it('handles beyond string length gracefully', function()
            local pos = input._utf8.byte_pos_of_char('Hi', 10)
            assert.is_true(pos > 2 or pos == 3)
        end)
    end)
    describe('M._utf8.remove_char_at(s, char_idx)', function()
        it('removes ASCII character from middle', function()
            assert.equals('Helo', input._utf8.remove_char_at('Hello', 3))
        end)
        it('removes ASCII character from beginning', function()
            assert.equals('ello', input._utf8.remove_char_at('Hello', 1))
        end)
        it('removes ASCII character from end', function()
            assert.equals('Hell', input._utf8.remove_char_at('Hello', 5))
        end)
        it('removes multi-byte character correctly', function()
            assert.equals('првет', input._utf8.remove_char_at('привет', 3))
        end)
        it('removes emoji correctly', function()
            assert.equals('AB', input._utf8.remove_char_at('A🌍B', 2))
        end)
    end)
    describe('M._utf8.insert_char_at(s, char_idx, char_bytes)', function()
        it('inserts ASCII char at beginning', function()
            assert.equals('XHello', input._utf8.insert_char_at('Hello', 1, 'X'))
        end)
        it('inserts ASCII char at end', function()
            assert.equals('HelloX', input._utf8.insert_char_at('Hello', 6, 'X'))
        end)
        it('inserts ASCII char in middle', function()
            assert.equals('HeXllo', input._utf8.insert_char_at('Hello', 3, 'X'))
        end)
        it('inserts multi-byte char correctly', function()
            assert.equals('A🌍B', input._utf8.insert_char_at('AB', 2, '🌍'))
        end)
    end)
end)
-- ============================================================================
-- HISTORY MODULE
-- ============================================================================
describe('ui/input.lua — History module', function()
    before_each(function() input._history_module.clear() end)
    describe('M._history_module.save(text)', function()
        it('saves non-empty text', function()
            input._history_module.save('hello')
            assert.equals(1, #input._history_module.items)
            assert.equals('hello', input._history_module.items[1])
        end)
        it('skips empty text', function()
            input._history_module.save('')
            assert.equals(0, #input._history_module.items)
        end)
        it('skips whitespace-only text', function()
            input._history_module.save('   ')
            assert.equals(0, #input._history_module.items)
        end)
        it('skips duplicate consecutive entries', function()
            input._history_module.save('hello')
            input._history_module.save('hello')
            assert.equals(1, #input._history_module.items)
        end)
        it('allows non-consecutive duplicates', function()
            input._history_module.save('hello')
            input._history_module.save('world')
            input._history_module.save('hello')
            assert.equals(3, #input._history_module.items)
        end)
        it('respects capacity limit (cap=50)', function()
            for i = 1, 51 do input._history_module.save('item_' .. i) end
            assert.equals(50, #input._history_module.items)
            assert.equals('item_2', input._history_module.items[1])
            assert.equals('item_51', input._history_module.items[50])
        end)
    end)
    describe('M._history_module.clear()', function()
        it('clears all items', function()
            input._history_module.save('hello')
            input._history_module.save('world')
            input._history_module.clear()
            assert.equals(0, #input._history_module.items)
        end)
    end)
end)
-- ============================================================================
-- NON-TTY INPUT FUNCTIONS
-- ============================================================================
describe('ui/input.lua — Non-TTY input functions', function()
    before_each(function()
        tty.is_tty = false
        input._history_module.clear()
    end)
    after_each(function() tty.is_tty = orig_is_tty end)
    describe('M.read_line(prompt)', function()
        it('reads a line and saves to history', function()
            local orig = io.read
            io.read = function(_) return 'test_line' end
            local result = input.read_line('Prompt: ')
            assert.equals('test_line', result)
            assert.equals(1, #input._history_module.items)
            io.read = orig
        end)
        it('does not save empty lines to history', function()
            local orig = io.read
            io.read = function(_) return '' end
            local result = input.read_line('Prompt: ')
            assert.equals('', result)
            assert.equals(0, #input._history_module.items)
            io.read = orig
        end)
    end)
    describe('M.read_non_empty(prompt)', function()
        it('returns nil for empty input', function()
            local orig = io.read
            io.read = function(_) return '' end
            assert.is_nil(input.read_non_empty('Prompt: '))
            io.read = orig
        end)
        it('returns nil for whitespace-only input', function()
            local orig = io.read
            io.read = function(_) return '   ' end
            assert.is_nil(input.read_non_empty('Prompt: '))
            io.read = orig
        end)
        it('returns valid non-empty input', function()
            local orig = io.read
            io.read = function(_) return 'valid_input' end
            assert.equals('valid_input', input.read_non_empty('Prompt: '))
            io.read = orig
        end)
    end)
    describe('M.confirm(prompt, default)', function()
        it('returns true for "y"', function()
            local orig = io.read; io.read = function(_) return 'y' end
            assert.is_true(input.confirm('Confirm?', 'n')); io.read = orig
        end)
        it('returns true for "Y"', function()
            local orig = io.read; io.read = function(_) return 'Y' end
            assert.is_true(input.confirm('Confirm?', 'n')); io.read = orig
        end)
        it('returns false for "n"', function()
            local orig = io.read; io.read = function(_) return 'n' end
            assert.is_false(input.confirm('Confirm?', 'n')); io.read = orig
        end)
        it('uses default when input is empty (default=n)', function()
            local orig = io.read; io.read = function(_) return '' end
            assert.is_false(input.confirm('Confirm?', 'n')); io.read = orig
        end)
        it('uses default when input is empty (default=y)', function()
            local orig = io.read; io.read = function(_) return '' end
            assert.is_true(input.confirm('Confirm?', 'y')); io.read = orig
        end)
    end)
    describe('M.select_from_options(prompt, options)', function()
        it('returns valid selection', function()
            local orig = io.read; io.read = function(_) return '2' end
            local idx, val = input.select_from_options('Choose:', {'a', 'b', 'c'})
            assert.equals(2, idx); assert.equals('b', val); io.read = orig
        end)
        it('returns nil for out-of-range selection', function()
            local orig = io.read; io.read = function(_) return '5' end
            local idx, val = input.select_from_options('Choose:', {'a', 'b', 'c'})
            assert.is_nil(idx); assert.is_nil(val); io.read = orig
        end)
        it('returns nil for non-number selection', function()
            local orig = io.read; io.read = function(_) return 'abc' end
            local idx, val = input.select_from_options('Choose:', {'a', 'b', 'c'})
            assert.is_nil(idx); assert.is_nil(val); io.read = orig
        end)
        it('returns nil for zero selection', function()
            local orig = io.read; io.read = function(_) return '0' end
            local idx, val = input.select_from_options('Choose:', {'a', 'b', 'c'})
            assert.is_nil(idx); assert.is_nil(val); io.read = orig
        end)
    end)
end)
-- ============================================================================
-- RAW INPUT LOOP EMULATION
-- ============================================================================
describe('ui/input.lua — Raw input loop emulation', function()
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    before_each(function() input._history_module.clear() end)
    -- Deep table equality helper
    local function tables_equal(t1, t2)
        if type(t1) ~= 'table' or type(t2) ~= 'table' then return t1 == t2 end
        if #t1 ~= #t2 then return false end
        for i = 1, #t1 do
            if not tables_equal(t1[i], t2[i]) then return false end
        end
        return true
    end
    local function assert_lines_equal(expected, actual)
        assert.is_true(tables_equal(expected, actual),
            string.format("Lines mismatch: expected [%s], got [%s]",
                table.concat(expected, ']['), table.concat(actual, '][')))
    end
    -- Feed a full string through _process_sequence
    local function feed(state, bytes)
        input._process_sequence(state, bytes, utf8, 80, 1)
        return state
    end
    -- Feed individual bytes, properly handling UTF-8 multi-byte sequences
    local function feed_bytes(state, ...)
        local bytes = {...}
        local i = 1
        while i <= #bytes do
            local b = bytes[i]
            if b >= 128 then
                local expected_len
                if b < 0xE0 then expected_len = 2
                elseif b < 0xF0 then expected_len = 3
                else expected_len = 4 end
                local seq = string.char(b)
                for j = 1, expected_len - 1 do
                    i = i + 1
                    if i <= #bytes then
                        seq = seq .. string.char(bytes[i])
                    end
                end
                input._process_sequence(state, seq, utf8, 80, 1)
            else
                input._process_byte(state, b, utf8, 80, 1)
            end
            i = i + 1
        end
        return state
    end
    -- Type a full UTF-8 string character by character
    local function type_string(state, str)
        local i = 1
        while i <= #str do
            local b = str:byte(i)
            if b < 128 then
                input._process_byte(state, b, utf8, 80, 1)
                i = i + 1
            elseif b < 0xE0 then
                input._process_sequence(state, str:sub(i, i + 1), utf8, 80, 1)
                i = i + 2
            elseif b < 0xF0 then
                input._process_sequence(state, str:sub(i, i + 2), utf8, 80, 1)
                i = i + 3
            else
                input._process_sequence(state, str:sub(i, i + 3), utf8, 80, 1)
                i = i + 4
            end
        end
        return state
    end
    -- =========================================================================
    -- ENTER KEY TESTS
    -- =========================================================================
    describe('M._process_byte — Enter key behavior', function()
        it('CR (13) alone: inserts exactly ONE line break', function()
            local s = new_state()
            s.cur_line = "hello"
            s.cur_pos = 6
            feed_bytes(s, 13)
            assert_lines_equal({"hello"}, s.lines)
            assert.equals("", s.cur_line)
            assert.equals(1, s.cur_pos)
        end)
        it('LF (10) alone: creates a line break (same as CR)', function()
            local s = new_state()
            s.cur_line = "hello"
            s.cur_pos = 6
            feed_bytes(s, 10)
            assert_lines_equal({"hello"}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('CR+LF (13,10): produces exactly ONE line break (not two)', function()
            local s = new_state()
            s.cur_line = "hello"
            s.cur_pos = 6
            feed_bytes(s, 13, 10)
            assert_lines_equal({"hello"}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('LF+CR (10,13): LF creates line break, CR creates second', function()
            local s = new_state()
            s.cur_line = "hello"
            s.cur_pos = 6
            feed_bytes(s, 10, 13)
            -- LF at cur_pos=6: pushes "hello" to lines, cur_line=""
            -- CR at cur_pos=1: pushes "" to lines, cur_line=""
            assert_lines_equal({"hello", ""}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('rapid double CR (13,13): produces TWO line breaks', function()
            local s = new_state()
            s.cur_line = "line1"
            s.cur_pos = 6
            feed_bytes(s, 13)
            s.cur_line = "line2"
            s.cur_pos = 6
            feed_bytes(s, 13)
            assert_lines_equal({"line1", "line2"}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('multiple CR+LF sequences produce correct line count', function()
            local s = new_state()
            s.cur_line = "line1"
            s.cur_pos = 6
            feed_bytes(s, 13, 10)
            s.cur_line = "line2"
            s.cur_pos = 6
            feed_bytes(s, 13, 10)
            assert_lines_equal({"line1", "line2"}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('Enter on empty line inserts empty string into lines', function()
            local s = new_state()
            s.cur_line = ""
            feed_bytes(s, 13)
            assert_lines_equal({""}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('Enter with text preserves text in lines array', function()
            local s = new_state()
            s.cur_line = "preserved text"
            s.cur_pos = 16
            feed_bytes(s, 13)
            assert_lines_equal({"preserved text"}, s.lines)
            assert.equals("", s.cur_line)
        end)
        it('multiple Enters create correct number of lines', function()
            local s = new_state()
            s.cur_line = "a"; s.cur_pos = 2; feed_bytes(s, 13)
            s.cur_line = "b"; s.cur_pos = 2; feed_bytes(s, 13)
            s.cur_line = "c"; s.cur_pos = 2; feed_bytes(s, 13)
            assert_lines_equal({"a", "b", "c"}, s.lines)
            assert.equals(3, #s.lines)
        end)
        it('Enter resets cur_pos to 1 and cur_line to ""', function()
            local s = new_state()
            s.cur_line = "hello"
            s.cur_pos = 6
            feed_bytes(s, 13)
            assert.equals("", s.cur_line)
            assert.equals(1, s.cur_pos)
        end)
        it('Enter resets hist_idx and hist_branch', function()
            local s = new_state()
            s.cur_line = "hello"
            s.cur_pos = 6
            s.hist_idx = 5
            s.hist_branch = "old_branch"
            feed_bytes(s, 13)
            assert.equals(0, s.hist_idx)
            assert.is_nil(s.hist_branch)
        end)
        it('REGRESSION: pressing Enter does NOT add multiple lines', function()
            local s = new_state()
            s.cur_line = "single"
            s.cur_pos = 7
            feed_bytes(s, 13)
            assert.equals(1, #s.lines, "Enter must produce exactly 1 line")
            assert.equals("single", s.lines[1])
        end)
    end)
    -- =========================================================================
    -- BACKSPACE TESTS
    -- =========================================================================
    describe('M._process_byte — Backspace basic deletion', function()
        it('types "Hello" then backspace 3 times => "He"', function()
            local s = new_state()
            feed_bytes(s, 72, 101, 108, 108, 111)
            assert.equals("Hello", s.cur_line)
            assert.equals(6, s.cur_pos)
            feed_bytes(s, 127, 127, 127)
            assert.equals("He", s.cur_line)
            assert.equals(3, s.cur_pos)
        end)
        it('backspace(127) deletes last character', function()
            local s = new_state()
            s.cur_line = "abc"
            s.cur_pos = 4
            feed_bytes(s, 127)
            assert.equals("ab", s.cur_line)
            assert.equals(3, s.cur_pos)
        end)
        it('backspace(8) also deletes last character (BS key)', function()
            local s = new_state()
            s.cur_line = "abc"
            s.cur_pos = 4
            feed_bytes(s, 8)
            assert.equals("ab", s.cur_line)
            assert.equals(3, s.cur_pos)
        end)
        it('backspace at cur_pos=1 with no lines is no-op', function()
            local s = new_state()
            s.cur_line = ""
            s.cur_pos = 1
            feed_bytes(s, 127)
            assert_lines_equal({}, s.lines)
            assert.equals("", s.cur_line)
            assert.equals(1, s.cur_pos)
        end)
        it('backspace at cur_pos=1 with lines merges with previous line', function()
            local s = new_state()
            s.lines = {"prev"}
            s.cur_line = "curr"
            s.cur_pos = 1
            feed_bytes(s, 127)
            assert_lines_equal({}, s.lines)
            assert.equals("prevcurr", s.cur_line)
            assert.equals(5, s.cur_pos)
        end)
        it('REGRESSION: backspace does NOT add lines when empty', function()
            local s = new_state()
            s.cur_line = ""
            s.cur_pos = 1
            feed_bytes(s, 127)
            assert.equals(0, #s.lines, "Backspace on empty must NOT add lines")
        end)
        it('REGRESSION: backspace deletes characters, does NOT add lines', function()
            local s = new_state()
            s.cur_line = "abcdef"
            s.cur_pos = 7
            local lines_before = #s.lines
            feed_bytes(s, 127)
            assert.equals("abcde", s.cur_line)
            assert.equals(lines_before, #s.lines, "Backspace must NOT change line count")
        end)
        it('rapid backspaces delete correct number of characters', function()
            local s = new_state()
            s.cur_line = "abcdefghij"
            s.cur_pos = 11
            feed_bytes(s, 127, 127, 127, 127, 127)
            assert.equals("abcde", s.cur_line)
            assert.equals(6, s.cur_pos)
        end)
        it('backspace in middle of line (move cursor left then backspace)', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 6
            feed_bytes(s, 27, 91, 68)  -- Left: pos 5
            feed_bytes(s, 27, 91, 68)  -- Left: pos 4
            assert.equals(4, s.cur_pos)
            feed_bytes(s, 127)  -- Remove char at pos 3 ('l')
            assert.equals("Helo", s.cur_line)
            assert.equals(3, s.cur_pos)  -- cur_pos decremented from 4 to 3
        end)
        it('backspace after Enter correctly merges lines', function()
            local s = new_state()
            type_string(s, "line1")
            feed_bytes(s, 13)
            assert_lines_equal({"line1"}, s.lines)
            type_string(s, "line2")
            assert.equals("line2", s.cur_line)
            -- Move cursor to start of "line2"
            for _ = 1, 5 do feed_bytes(s, 27, 91, 68) end
            assert.equals(1, s.cur_pos)
            feed_bytes(s, 127)  -- Merge
            assert_lines_equal({}, s.lines)
            assert.equals("line1line2", s.cur_line)
        end)
        it('backspace on empty current line at position 1 merges with previous', function()
            local s = new_state()
            s.lines = {"previous"}
            s.cur_line = ""
            s.cur_pos = 1
            feed_bytes(s, 127)
            assert_lines_equal({}, s.lines)
            assert.equals("previous", s.cur_line)
            -- "previous" has 8 chars, so cur_pos = 8 + 1 = 9
            assert.equals(9, s.cur_pos)
        end)
    end)
    -- =========================================================================
    -- BACKSPACE WITH UTF-8
    -- =========================================================================
    describe('M._process_byte — Backspace with UTF-8', function()
        it('types "Привет" then backspace removes "т"', function()
            local s = new_state()
            type_string(s, "Привет")
            assert.equals("Привет", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("Приве", s.cur_line)
        end)
        it('backspace removes 3-byte char (Chinese)', function()
            local s = new_state()
            type_string(s, "A中B")
            assert.equals("A中B", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("A中", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("A", s.cur_line)
        end)
        it('backspace removes 4-byte char (emoji)', function()
            local s = new_state()
            type_string(s, "Hi🌍!")
            assert.equals("Hi🌍!", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("Hi🌍", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("Hi", s.cur_line)
        end)
        it('backspace removes multi-byte char in middle', function()
            local s = new_state()
            type_string(s, "A中B")
            assert.equals("A中B", s.cur_line)
            feed_bytes(s, 27, 91, 68)  -- Left arrow
            assert.equals(3, s.cur_pos)
            feed_bytes(s, 127)
            assert.equals("AB", s.cur_line)
        end)
        it('backspace on Cyrillic string step by step', function()
            local s = new_state()
            type_string(s, "мир")
            assert.equals("мир", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("ми", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("м", s.cur_line)
            feed_bytes(s, 127)
            assert.equals("", s.cur_line)
        end)
    end)
    -- =========================================================================
    -- MIXED ENTER/BACKSPACE
    -- =========================================================================
    describe('M._process_byte — Mixed Enter/Backspace', function()
        it('type "line1", Enter, type "line2", backspace 3x', function()
            local s = new_state()
            type_string(s, "line1")
            feed_bytes(s, 13)
            assert_lines_equal({"line1"}, s.lines)
            type_string(s, "line2")
            assert.equals("line2", s.cur_line)
            feed_bytes(s, 127, 127, 127)
            assert.equals("li", s.cur_line)  -- "line2" minus 3 = "li"
            assert_lines_equal({"line1"}, s.lines)
        end)
        it('type multi-line, edit last line with backspace', function()
            local s = new_state()
            type_string(s, "first")
            feed_bytes(s, 13)
            type_string(s, "second")
            feed_bytes(s, 13)
            type_string(s, "third")
            assert_lines_equal({"first", "second"}, s.lines)
            assert.equals("third", s.cur_line)
            feed_bytes(s, 127, 127, 127, 127)
            assert.equals("t", s.cur_line)
            assert_lines_equal({"first", "second"}, s.lines)
        end)
        it('backspace across line boundary after Enter', function()
            local s = new_state()
            type_string(s, "hello")
            feed_bytes(s, 13)
            type_string(s, "world")
            for _ = 1, 5 do feed_bytes(s, 27, 91, 68) end
            assert.equals(1, s.cur_pos)
            feed_bytes(s, 127)
            assert_lines_equal({}, s.lines)
            assert.equals("helloworld", s.cur_line)
        end)
    end)
    -- =========================================================================
    -- INTEGRATION SIMULATIONS
    -- =========================================================================
    describe('Integration — simulated user input scenarios', function()
        it('Simulate: type "hello", Enter, type "world", Backspace 3x', function()
            local s = new_state()
            type_string(s, "hello")
            feed_bytes(s, 13)
            type_string(s, "world")
            feed_bytes(s, 127, 127, 127)
            assert_lines_equal({"hello"}, s.lines)
            assert.equals("wo", s.cur_line)
            assert.equals(3, s.cur_pos)
        end)
        it('Simulate: type multi-line text, edit with backspace', function()
            local s = new_state()
            type_string(s, "line one")
            feed_bytes(s, 13)
            type_string(s, "line two")
            feed_bytes(s, 13)
            type_string(s, "line three")
            for _ = 1, 5 do feed_bytes(s, 127) end
            assert_lines_equal({"line one", "line two"}, s.lines)
            assert.equals("line ", s.cur_line)
        end)
        it('REGRESSION: Backspace should delete, not add lines', function()
            local s = new_state()
            type_string(s, "test")
            local initial_lines = #s.lines
            feed_bytes(s, 127)
            assert.equals(initial_lines, #s.lines, "Backspace must NOT add lines")
            assert.equals("tes", s.cur_line)
            feed_bytes(s, 127)
            assert.equals(initial_lines, #s.lines, "Second backspace must NOT add lines")
            assert.equals("te", s.cur_line)
        end)
        it('REGRESSION: Enter should add exactly one line, not multiple', function()
            local s = new_state()
            type_string(s, "one line")
            feed_bytes(s, 13)
            assert.equals(1, #s.lines, "Single Enter must add exactly 1 line")
            assert.equals("one line", s.lines[1])
            local s2 = new_state()
            type_string(s2, "another")
            feed_bytes(s2, 13, 10)
            assert.equals(1, #s2.lines, "CR+LF must add exactly 1 line")
        end)
        it('Simulate: type, backspace all, type again', function()
            local s = new_state()
            type_string(s, "abc")
            feed_bytes(s, 127, 127, 127)
            assert.equals("", s.cur_line)
            assert.equals(1, s.cur_pos)
            type_string(s, "xyz")
            assert.equals("xyz", s.cur_line)
        end)
        it('Simulate: Enter, backspace to merge, type more', function()
            local s = new_state()
            type_string(s, "part1")
            feed_bytes(s, 13)
            type_string(s, "part2")
            -- Go to start of "part2" and merge
            for _ = 1, 5 do feed_bytes(s, 27, 91, 68) end
            feed_bytes(s, 127)
            assert.equals("part1part2", s.cur_line)
            -- Now type "-done" at cursor position 6 (between part1|part2)
            type_string(s, "-done")
            assert.equals("part1-donepart2", s.cur_line)
        end)
    end)
    -- =========================================================================
    -- DELETE KEY
    -- =========================================================================
    describe('M._process_byte — Delete key (ESC [ 3 ~)', function()
        it('deletes character forward (not backward)', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 3
            feed_bytes(s, 27, 91, 51, 126)
            assert.equals("Helo", s.cur_line)
            assert.equals(3, s.cur_pos)
        end)
        it('delete at end of line: no-op', function()
            local s = new_state()
            s.cur_line = "Hi"
            s.cur_pos = 3
            feed_bytes(s, 27, 91, 51, 126)
            assert.equals("Hi", s.cur_line)
        end)
    end)
    -- =========================================================================
    -- HOME/END KEYS
    -- =========================================================================
    describe('M._process_byte — Home/End keys', function()
        it('Home (ESC [ H) sets cur_pos to 1', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 5
            feed_bytes(s, 27, 91, 72)
            assert.equals(1, s.cur_pos)
        end)
        it('End (ESC [ F) sets cur_pos to end+1', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 1
            feed_bytes(s, 27, 91, 70)
            assert.equals(6, s.cur_pos)
        end)
        it('Alt+Home (ESC [ 7 ~) sets cur_pos to 1', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 5
            feed_bytes(s, 27, 91, 55, 126)
            assert.equals(1, s.cur_pos)
        end)
        it('Alt+End (ESC [ 8 ~) sets cur_pos to end+1', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 1
            feed_bytes(s, 27, 91, 56, 126)
            assert.equals(6, s.cur_pos)
        end)
    end)
    -- =========================================================================
    -- ARROW KEYS
    -- =========================================================================
    describe('M._process_byte — Arrow keys', function()
        it('Right arrow moves cursor right', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 1
            feed_bytes(s, 27, 91, 67)
            assert.equals(2, s.cur_pos)
        end)
        it('Left arrow moves cursor left', function()
            local s = new_state()
            s.cur_line = "Hello"
            s.cur_pos = 3
            feed_bytes(s, 27, 91, 68)
            assert.equals(2, s.cur_pos)
        end)
        it('Right arrow at end: no-op', function()
            local s = new_state()
            s.cur_line = "Hi"
            s.cur_pos = 3
            feed_bytes(s, 27, 91, 67)
            assert.equals(3, s.cur_pos)
        end)
        it('Left arrow at start: no-op', function()
            local s = new_state()
            s.cur_line = "Hi"
            s.cur_pos = 1
            feed_bytes(s, 27, 91, 68)
            assert.equals(1, s.cur_pos)
        end)
    end)
    -- =========================================================================
    -- PRINTABLE ASCII
    -- =========================================================================
    describe('M._process_byte — Printable ASCII', function()
        it('appends char at end of line', function()
            local s = new_state()
            feed_bytes(s, 65)
            assert.equals("A", s.cur_line)
            assert.equals(2, s.cur_pos)
        end)
        it('inserts char in middle of line', function()
            local s = new_state()
            s.cur_line = "AC"
            s.cur_pos = 2
            feed_bytes(s, 66)
            assert.equals("ABC", s.cur_line)
            assert.equals(3, s.cur_pos)
        end)
        it('inserting in middle clears history branch', function()
            local s = new_state()
            s.hist_idx = 5
            s.hist_branch = "old"
            s.cur_line = "AC"
            s.cur_pos = 2
            feed_bytes(s, 66)
            assert.equals(0, s.hist_idx)
            assert.is_nil(s.hist_branch)
        end)
    end)
    -- =========================================================================
    -- CTRL+C / CTRL+D
    -- =========================================================================
    describe('M._process_byte — Ctrl+C / Ctrl+D', function()
        it('Ctrl+C (3) returns "cancel"', function()
            local s = new_state()
            assert.equals("cancel", input._process_byte(s, 3, utf8, 80, 1))
        end)
        it('Ctrl+D (4) returns "submit" and sets result', function()
            local s = new_state()
            s.cur_line = "hello"
            local action = input._process_byte(s, 4, utf8, 80, 1)
            assert.equals("submit", action)
            assert.equals("hello", s.result)
        end)
        it('Ctrl+D with empty cur_line and no lines returns empty result', function()
            local s = new_state()
            local action = input._process_byte(s, 4, utf8, 80, 1)
            assert.equals("submit", action)
            assert.equals("", s.result)
        end)
    end)
    -- =========================================================================
    -- HISTORY NAVIGATION
    -- =========================================================================
    describe('M._process_byte — History navigation', function()
        before_each(function()
            input._history_module.clear()
            input._history_module.save("first")
            input._history_module.save("second")
            input._history_module.save("third")
        end)
        it('Up arrow loads most recent history item', function()
            local s = new_state()
            s.cur_line = "new"
            feed_bytes(s, 27, 91, 65)
            assert.equals("third", s.cur_line)
            assert.equals(3, s.hist_idx)
        end)
        it('Down arrow returns to typed text', function()
            local s = new_state()
            s.cur_line = "new"
            feed_bytes(s, 27, 91, 65)
            feed_bytes(s, 27, 91, 66)
            assert.equals("new", s.cur_line)
            assert.equals(0, s.hist_idx)
        end)
    end)
    -- =========================================================================
    -- UTF-8 MULTI-BYTE SEQUENCES
    -- =========================================================================
    describe('M._process_sequence — UTF-8 multi-byte', function()
        it('processes 2-byte UTF-8 character', function()
            local s = new_state()
            feed(s, string.char(0xC3, 0xA9))
            assert.equals("é", s.cur_line)
            assert.equals(2, s.cur_pos)
        end)
        it('processes 3-byte UTF-8 character', function()
            local s = new_state()
            feed(s, string.char(0xE4, 0xB8, 0xAD))
            assert.equals("中", s.cur_line)
            assert.equals(2, s.cur_pos)
        end)
        it('processes 4-byte UTF-8 character (emoji)', function()
            local s = new_state()
            feed(s, string.char(0xF0, 0x9F, 0x8C, 0x8D))
            assert.equals("🌍", s.cur_line)
            assert.equals(2, s.cur_pos)
        end)
        it('mixed ASCII and UTF-8', function()
            local s = new_state()
            feed(s, "A")
            feed(s, string.char(0xE4, 0xB8, 0xAD))
            feed(s, "B")
            assert.equals("A中B", s.cur_line)
        end)
    end)
end)
-- ============================================================================
-- BRACKETED PASTE
-- ============================================================================
describe('ui/input.lua — Bracketed Paste', function()
    local utf8 = require('ui.input')._utf8
    local input = require('ui.input')
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    describe('M._process_byte — Bracketed Paste sequences', function()
        it('ESC[200~ returns start_paste', function()
            local s = new_state()
            input._process_byte(s, 27, utf8, 80, 1)  -- ESC
            input._process_byte(s, 91, utf8, 80, 1)  -- [
            local r1 = input._process_byte(s, 50, utf8, 80, 1)  -- '2'
            local r2 = input._process_byte(s, 48, utf8, 80, 1)  -- '0'
            local r3 = input._process_byte(s, 48, utf8, 80, 1)  -- '0'
            local r4 = input._process_byte(s, 126, utf8, 80, 1) -- '~'
            assert.equals('start_paste', r4)
            assert.equals(0, s.esc_state)
        end)
        it('ESC[201~ returns end_paste', function()
            local s = new_state()
            input._process_byte(s, 27, utf8, 80, 1)  -- ESC
            input._process_byte(s, 91, utf8, 80, 1)  -- [
            input._process_byte(s, 50, utf8, 80, 1)  -- '2'
            input._process_byte(s, 48, utf8, 80, 1)  -- '0'
            input._process_byte(s, 49, utf8, 80, 1)  -- '1'
            local r = input._process_byte(s, 126, utf8, 80, 1) -- '~'
            assert.equals('end_paste', r)
        end)
    end)
end)
-- ============================================================================
-- HISTORY NAVIGATION EDGE CASES
-- ============================================================================
describe('ui/input.lua — History navigation edge cases', function()
    local input = require('ui.input')
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    before_each(function() input._history_module.clear() end)
    describe('Empty history', function()
        it('Up arrow with empty history is no-op', function()
            local s = new_state()
            s.cur_line = "typed"
            input._process_byte(s, 27, utf8, 80, 1)  -- ESC
            input._process_byte(s, 91, utf8, 80, 1)  -- [
            input._process_byte(s, 65, utf8, 80, 1)  -- Up
            assert.equals("typed", s.cur_line)
            assert.equals(0, s.hist_idx)
        end)
    end)
    describe('Multiple up/down cycles', function()
        before_each(function()
            input._history_module.clear()
            input._history_module.save("first")
            input._history_module.save("second")
            input._history_module.save("third")
        end)
        it('Up, Up, Down, Down returns to typed text', function()
            local s = new_state()
            s.cur_line = "new"
            -- Up -> third
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 65, utf8, 80, 1)
            assert.equals("third", s.cur_line)
            -- Up -> second
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 65, utf8, 80, 1)
            assert.equals("second", s.cur_line)
            -- Down -> third
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 66, utf8, 80, 1)
            assert.equals("third", s.cur_line)
            -- Down -> "new"
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 66, utf8, 80, 1)
            assert.equals("new", s.cur_line)
            assert.equals(0, s.hist_idx)
        end)
        it('Down at bottom stays at bottom', function()
            local s = new_state()
            s.cur_line = "new"
            -- Up -> third
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 65, utf8, 80, 1)
            assert.equals("third", s.cur_line)
            -- Down -> new
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 66, utf8, 80, 1)
            assert.equals("new", s.cur_line)
            -- Down again: should stay at "new"
            input._process_byte(s, 27, utf8, 80, 1)
            input._process_byte(s, 91, utf8, 80, 1)
            input._process_byte(s, 66, utf8, 80, 1)
            assert.equals("new", s.cur_line)
            assert.equals(0, s.hist_idx)
        end)
    end)
end)
-- ============================================================================
-- CTRL+D WITH EXISTING LINES
-- ============================================================================
describe('ui/input.lua — Ctrl+D with existing lines', function()
    local input = require('ui.input')
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    before_each(function() input._history_module.clear() end)
    it('Ctrl+D submits lines + cur_line joined by newline', function()
        local s = new_state()
        s.lines = {"line1", "line2"}
        s.cur_line = "line3"
        local action = input._process_byte(s, 4, utf8, 80, 1)
        assert.equals("submit", action)
        assert.equals("line1\nline2\nline3", s.result)
    end)
    it('Ctrl+D with only lines (empty cur_line)', function()
        local s = new_state()
        s.lines = {"line1", "line2"}
        s.cur_line = ""
        local action = input._process_byte(s, 4, utf8, 80, 1)
        assert.equals("submit", action)
        assert.equals("line1\nline2", s.result)
    end)
    it('Ctrl+D saves multiline result to history', function()
        local s = new_state()
        s.lines = {"a", "b"}
        s.cur_line = "c"
        input._process_byte(s, 4, utf8, 80, 1)
        assert.equals(1, #input._history_module.items)
        assert.equals("a\nb\nc", input._history_module.items[1])
    end)
end)
-- ============================================================================
-- ESCAPE SEQUENCE RECOVERY
-- ============================================================================
describe('ui/input.lua — Escape sequence recovery', function()
    local input = require('ui.input')
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    it('Malformed ESC sequence resets esc_state to 0', function()
        local s = new_state()
        input._process_byte(s, 27, utf8, 80, 1)  -- ESC -> state 1
        assert.equals(1, s.esc_state)
        input._process_byte(s, 65, utf8, 80, 1)  -- 'A' (not '[') -> reset
        assert.equals(0, s.esc_state)
    end)
    it('Unknown CSI byte resets esc_state', function()
        local s = new_state()
        input._process_byte(s, 27, utf8, 80, 1)  -- ESC
        input._process_byte(s, 91, utf8, 80, 1)  -- [ -> state 2
        assert.equals(2, s.esc_state)
        input._process_byte(s, 97, utf8, 80, 1)  -- 'a' (unknown) -> reset
        assert.equals(0, s.esc_state)
    end)
    it('Non-terminating CSI param resets state', function()
        local s = new_state()
        input._process_byte(s, 27, utf8, 80, 1)  -- ESC
        input._process_byte(s, 91, utf8, 80, 1)  -- [
        input._process_byte(s, 50, utf8, 80, 1)  -- '2' -> state 3
        assert.equals(3, s.esc_state)
        input._process_byte(s, 97, utf8, 80, 1)  -- 'a' (not digit, not ~) -> reset
        assert.equals(0, s.esc_state)
    end)
    it('State is not corrupted after malformed sequence', function()
        local s = new_state()
        s.cur_line = "hello"
        s.cur_pos = 6
        input._process_byte(s, 27, utf8, 80, 1)  -- ESC
        input._process_byte(s, 91, utf8, 80, 1)  -- [
        input._process_byte(s, 97, utf8, 80, 1)  -- unknown -> reset
        assert.equals("hello", s.cur_line)
        assert.equals(6, s.cur_pos)
        assert.equals(0, s.esc_state)
    end)
end)
-- ============================================================================
-- PRINTABLE ASCII AT VARIOUS POSITIONS
-- ============================================================================
describe('ui/input.lua — Printable ASCII edge cases', function()
    local input = require('ui.input')
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    it('Insert at pos=1 (beginning of line)', function()
        local s = new_state()
        s.cur_line = "BC"
        s.cur_pos = 1
        local action = input._process_byte(s, 65, utf8, 80, 1)  -- 'A'
        assert.equals("ABC", s.cur_line)
        assert.equals(2, s.cur_pos)
        assert.equals("redraw", action)
    end)
    it('Append at end returns redraw', function()
        local s = new_state()
        s.cur_line = "AB"
        s.cur_pos = 3
        local action = input._process_byte(s, 67, utf8, 80, 1)  -- 'C'
        assert.equals("ABC", s.cur_line)
        assert.equals("redraw", action)
    end)
    it('Insert in middle returns redraw (not print)', function()
        local s = new_state()
        s.cur_line = "AC"
        s.cur_pos = 2
        local action = input._process_byte(s, 66, utf8, 80, 1)  -- 'B'
        assert.equals("ABC", s.cur_line)
        assert.equals("redraw", action)
    end)
end)
-- ============================================================================
-- BACKSPACE WITH UTF-8 AT LINE BOUNDARY
-- ============================================================================
describe('ui/input.lua — Backspace UTF-8 line boundary', function()
    local input = require('ui.input')
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    it('Backspace merges lines with multi-byte previous line', function()
        local s = new_state()
        s.lines = {"привет"}
        s.cur_line = "мир"
        s.cur_pos = 1
        input._process_byte(s, 127, utf8, 80, 1)  -- Backspace
        assert.equals("приветмир", s.cur_line)
        -- "привет" is 6 chars, so cursor should be at 7
        assert.equals(7, s.cur_pos)
        assert.equals(0, #s.lines)
    end)
    it('Backspace merges lines with emoji in previous line', function()
        local s = new_state()
        s.lines = {"A🌍B"}
        s.cur_line = "C"
        s.cur_pos = 1
        input._process_byte(s, 127, utf8, 80, 1)
        assert.equals("A🌍BC", s.cur_line)
        -- "A🌍B" is 3 chars, so cursor at 4
        assert.equals(4, s.cur_pos)
    end)
end)
-- ============================================================================
-- _process_sequence EDGE CASES
-- ============================================================================
describe('ui/input.lua — _process_sequence edge cases', function()
    local input = require('ui.input')
    local utf8 = input._utf8
    local function new_state()
        return {
            lines = {}, lines_below = {}, cur_line = "", cur_pos = 1,
            esc_state = 0, esc_buf = "",
            hist_idx = 0, hist_branch = nil,
        }
    end
    it('Empty bytes string is handled gracefully', function()
        local s = new_state()
        s.cur_line = "hello"
        s.cur_pos = 6
        local action = input._process_sequence(s, "", utf8, 80, 1)
        assert.is_nil(action)
        assert.equals("hello", s.cur_line)
    end)
    it('Single ASCII byte via _process_sequence', function()
        local s = new_state()
        local action = input._process_sequence(s, "X", utf8, 80, 1)
        assert.equals("redraw", action)
        assert.equals("X", s.cur_line)
    end)
end)