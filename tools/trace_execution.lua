local utils = require("utils")
local os = require("os")

local function register(registry)
    registry.register("trace_execution", "Attach eBPF tracer to a binary to extract real-time arguments and return values", "<cmd>trace_execution:./binary\nuretprobe:./binary:func_name { printf(\"Ret: %%d\", retval); }\n</cmd>", function(args, ctx, agent_name)
        local binary, bpf_script = args:match("^([^%s\n]+)%s*\n(.*)")
        if not binary or not bpf_script then
            return { output = "\n[ERROR]: Usage: \x3ccmd\x3etrace_execution:./binary\nuretprobe:./binary:func_name { printf(\"Ret: %%d\", retval); }\x3c/cmd\x3e" }
        end

        local tmp_script = os.tmpname()
        utils.write_file(tmp_script, bpf_script)

        local wrapper = string.format(
            "sudo bpftrace %s > %s.out 2>&1 & BPF_PID=$!; sleep 1; %s; kill -INT $BPF_PID; sleep 1; cat %s.out",
            tmp_script, tmp_script, binary, tmp_script
        )

        local f = io.popen(wrapper)
        local trace_result = f:read("*a")
        f:close()

        os.remove(tmp_script)
        os.remove(tmp_script .. ".out")

        return { output = "\n[eBPF TRACE RESULTS]:\n" .. trace_result }
    end)
end

return { register = register }