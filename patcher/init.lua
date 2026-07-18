
local M = {}


-- Load sub-modules

local diff = require("patcher.diff")

local matcher = require("patcher.matcher")

local parser = require("patcher.parser")


-- Re-export diff functions

M.generate_unified_diff = diff.generate_unified_diff


-- Re-export parser functions

M.apply_patch = parser.apply_patch


return M

