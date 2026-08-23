-- ui/__tests__/test_input_flush.lua
-- Busted-style tests for M.flush_input() and its integration with read_line/confirm

local input = require('ui.input')
local tty   = require('ui.tty')

describe('ui.input.flush_input', function()

    local orig_is_tty
    local orig_os_execute
    local orig_io_read

    setup(function()
        orig_is_tty     = tty.is_tty
        orig_os_execute = os.execute
        orig_io_read    = io.read
    end)

    teardown(function()
        tty.is_tty     = orig_is_tty
        os.execute     = orig_os_execute
        io.read        = orig_io_read
    end)

    -- ------------------------------------------------------------------
    -- Test 1: non-TTY mode is a no-op
    -- ------------------------------------------------------------------
    it('returns nil without calling os.execute when not a TTY', function()
        tty.is_tty = false

        local exec_calls = {}
        os.execute = function(cmd)
            table.insert(exec_calls, cmd)
            return true
        end

        local result = input.flush_input()

        assert.are.equal(nil, result)
        assert.are.equal(0, #exec_calls, 'os.execute should NOT be called in non-TTY mode')
    end)

    -- ------------------------------------------------------------------
    -- Test 2: TTY mode calls the correct stty commands
    -- ------------------------------------------------------------------
    it('calls stty raw and stty sane when TTY is enabled', function()
        tty.is_tty = true

        local exec_calls = {}
        os.execute = function(cmd)
            table.insert(exec_calls, cmd)
            return true
        end

        -- io.read(1) returns nil immediately (no pending bytes)
        io.read = function(fmt)
            return nil
        end

        input.flush_input()
        assert.are.equal(3, #exec_calls, 'expected exactly 3 os.execute calls')
        assert.match('stty raw', exec_calls[1], 'first call should set raw mode')
        assert.match('-icanon', exec_calls[1], 'first call should disable canonical mode')
        assert.match('min 0', exec_calls[1], 'first call should set min 0')
        assert.match('time 0', exec_calls[1], 'first call should set time 0')
        assert.match('IFS=', exec_calls[2], 'second call should drain via shell')
        assert.match('stty sane', exec_calls[3], 'third call should restore sane mode')
    end)

    -- ------------------------------------------------------------------
    -- Test 3: TTY mode drains pending bytes from stdin
    -- ------------------------------------------------------------------
    it('drains all pending bytes from stdin before restoring', function()
        tty.is_tty = true

        local exec_calls = {}
        os.execute = function(cmd)
            table.insert(exec_calls, cmd)
            return true
        end

        -- Simulate 3 pending bytes then EOF
        local pending = { 'a', 'b', 'c' }
        local read_count = 0
        io.read = function(fmt)
            read_count = read_count + 1
            if read_count <= #pending then
                return pending[read_count]
            end
            return nil
        end

        input.flush_input()

        assert.are.equal(#pending + 1, read_count, 'should read all pending bytes plus one nil')
        assert.are.equal(3, #exec_calls, 'should still call stty three times')
    end)

    -- ------------------------------------------------------------------
    -- Test 4: read_line calls flush_input before reading
    -- ------------------------------------------------------------------
    it('read_line calls flush_input before io.read', function()
        tty.is_tty = true

        local call_order = {}

        -- Spy on flush_input
        local orig_flush = input.flush_input
        input.flush_input = function()
            table.insert(call_order, 'flush_input')
            return orig_flush()
        end

        os.execute = function(cmd)
            return true
        end

        -- io.read: first call is from flush_input (returns nil), second is the actual line read
        local read_seq = { nil, 'hello' }
        local read_idx = 0
        io.read = function(fmt)
            read_idx = read_idx + 1
            table.insert(call_order, 'io.read#' .. read_idx)
            if read_idx <= #read_seq then
                return read_seq[read_idx]
            end
            return nil
        end

        local result = input.read_line('Test: ')
        input.flush_input = orig_flush

        assert.are.equal('hello', result)
        -- flush_input must come before the line-reading io.read
        local flush_pos, read_pos = 1, 1
        for i, v in ipairs(call_order) do
            if v == 'flush_input' then flush_pos = i end
            if v == 'io.read#2' then read_pos = i end
        end
        assert.is_true(flush_pos < read_pos, 'flush_input must be called before the line read')
    end)

    -- ------------------------------------------------------------------
    -- Test 5: confirm calls flush_input before reading
    -- ------------------------------------------------------------------
    it('confirm calls flush_input before io.read', function()
        tty.is_tty = true

        local call_order = {}

        local orig_flush = input.flush_input
        input.flush_input = function()
            table.insert(call_order, 'flush_input')
            return orig_flush()
        end

        os.execute = function(cmd)
            return true
        end

        -- io.read: first call is from flush_input (returns nil), second is the answer
        local read_seq = { nil, 'y' }
        local read_idx = 0
        io.read = function(fmt)
            read_idx = read_idx + 1
            table.insert(call_order, 'io.read#' .. read_idx)
            if read_idx <= #read_seq then
                return read_seq[read_idx]
            end
            return nil
        end

        local result = input.confirm('Proceed?', 'n')
        input.flush_input = orig_flush

        assert.are.equal(true, result)
        local flush_pos, read_pos = 1, 1
        for i, v in ipairs(call_order) do
            if v == 'flush_input' then flush_pos = i end
            if v == 'io.read#2' then read_pos = i end
        end
        assert.is_true(flush_pos < read_pos, 'flush_input must be called before the confirm read')
    end)

    -- ------------------------------------------------------------------
    -- Test 6: confirm_with_reason calls flush_input before reading
    -- ------------------------------------------------------------------
    it('confirm_with_reason calls flush_input before io.read', function()
        tty.is_tty = true

        local call_order = {}

        local orig_flush = input.flush_input
        input.flush_input = function()
            table.insert(call_order, 'flush_input')
            return orig_flush()
        end

        os.execute = function(cmd)
            return true
        end

        local read_seq = { nil, 'n' }
        local read_idx = 0
        io.read = function(fmt)
            read_idx = read_idx + 1
            table.insert(call_order, 'io.read#' .. read_idx)
            if read_idx <= #read_seq then
                return read_seq[read_idx]
            end
            return nil
        end

        local result = input.confirm_with_reason('Execute?', 'n')
        input.flush_input = orig_flush

        assert.are.equal(false, result.allowed)
        local flush_pos, read_pos = 1, 1
        for i, v in ipairs(call_order) do
            if v == 'flush_input' then flush_pos = i end
            if v == 'io.read#2' then read_pos = i end
        end
        assert.is_true(flush_pos < read_pos, 'flush_input must be called before the confirm_with_reason read')
    end)

    -- ------------------------------------------------------------------
    -- Test 7: flush_input is safe when os.execute fails (pcall protection)
    -- ------------------------------------------------------------------
    it('does not raise an error when os.execute fails', function()
        tty.is_tty = true

        os.execute = function(cmd)
            error('simulated stty failure')
        end

        io.read = function(fmt)
            return nil
        end

        local ok, err = pcall(input.flush_input)
        assert.is_true(ok, 'flush_input should not propagate os.execute errors: ' .. tostring(err))
    end)

end)