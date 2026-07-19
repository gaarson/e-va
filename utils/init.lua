local M = {}
-- Load all sub-modules
local stream = require("utils.stream")
local strings = require("utils.strings")
local config = require("utils.config")
local file_io = require("utils.file_io")
local directory = require("utils.directory")
local encoding = require("utils.encoding")
local images = require("utils.images")
local diff = require("utils.diff")
-- Re-export stream functions
M.stream_token_printer = stream.stream_token_printer
M.flush_stream_buffer = stream.flush_stream_buffer
-- Re-export string functions
M.trim = strings.trim
M.normalize_path = strings.normalize_path
-- Re-export config functions
M.deep_merge = config.deep_merge
M.load_config = config.load_config
M.apply_agent_defaults = config.apply_agent_defaults
-- Re-export file_io functions
M.copy_file = file_io.copy_file
M.read_file_range = file_io.read_file_range
M.write_file = file_io.write_file
M.count_lines_fast = file_io.count_lines_fast
M.read_file_numbered = file_io.read_file_numbered
M.read_lines_raw = file_io.read_lines_raw
M.read_file_lines = file_io.read_file_lines
M.restore_backup = file_io.restore_backup
M.cleanup_backups = file_io.cleanup_backups
M.replace_lines = file_io.replace_lines
-- Re-export directory functions
M.list_files_recursive = directory.list_files_recursive
M.shell_quote = strings.shell_quote
M.explore_directory = directory.explore_directory
-- Re-export encoding functions
M.base64_encode = encoding.base64_encode
M.escape_json_string = encoding.escape_json_string
M.sanitize_for_json = encoding.sanitize_for_json
-- Re-export images functions and state
M.estimate_image_tokens = images.estimate_image_tokens
M.get_image_dimensions = images.get_image_dimensions
M.compress_image = images.compress_image
M.load_images_from_dir = images.load_images_from_dir
M._compress_stats = images._compress_stats
-- Re-export diff functions
M.compute_diff = diff.compute_diff
return M
