local registry = require("tool_registry")

local function init()
    local explore_tree = require("tools.explore_tree")
    explore_tree.register(registry)

    local read_file = require("tools.read_file")
    read_file.register(registry)

    local read_chunk = require("tools.read_chunk")
    read_chunk.register(registry)

    local search = require("tools.search")
    search.register(registry)

    local rollback = require("tools.rollback")
    rollback.register(registry)

    local cleanup_baks = require("tools.cleanup_baks")
    cleanup_baks.register(registry)

    local patch = require("tools.patch")
    patch.register(registry)

    local create_file = require("tools.create_file")
    create_file.register(registry)

    local shell = require("tools.shell")
    shell.register(registry)

    local delegate_plan = require("tools.delegate_plan")
    delegate_plan.register(registry)

    local task_complete = require("tools.task_complete")
    task_complete.register(registry)

    local ask_user = require("tools.ask_user")
    ask_user.register(registry)

    local outline = require("tools.outline")
    outline.register(registry)

    local pin = require("tools.pin")
    pin.register(registry)

    local unpin = require("tools.unpin")
    unpin.register(registry)

    local trace_execution = require("tools.trace_execution")
    trace_execution.register(registry)
end

return { init = init }
