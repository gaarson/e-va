-- main.lua
-- Основной скрипт для взаимодействия с LLM и Neovim

local config_module = require("config")
local neovim = require("neovim")
local llm_handler = require("llm_handler")
local utils = require("utils")

local JSON = require("JSON")
local io = require("io")
local string = require("string")
local table = require("table")
local inspect = require("inspect") -- For debugging

--- Основная функция для взаимодействия с LLM.
local function run_assistant(initial_instruction)
  local cfg = config_module.get() -- Load configuration

  -- 1. Выбор активного буфера Neovim
  local neovim_buffers = neovim.get_all_vim_buffers()
  if #neovim_buffers == 0 then
    print("Error: No active Neovim instances/buffers found connected via nvr.")
    print("Ensure Neovim is running with a servername (e.g., nvim --listen /tmp/nvim.sock) and nvr can connect.")
    return
  end

  print("Select the Neovim buffer to work with:")
  for i, buf_info in ipairs(neovim_buffers) do
    print(string.format("[%d] %s (%s) - Server: %s", i, buf_info.filename, buf_info.path, buf_info.server))
  end

  local index
  while true do
    io.stdout:write("Enter buffer index: ")
    io.stdout:flush()
    local index_str = io.read()
    index = tonumber(index_str)
    if index and index >= 1 and index <= #neovim_buffers then
      break
    else
      print("Error: Invalid index. Please try again.")
    end
  end

  local target_buffer = neovim_buffers[index]
  print("Working with buffer: " .. target_buffer.path .. " on server " .. target_buffer.server)

  -- 2. Инициализация диалога
  local conversation_history = {}
  if cfg.SYSTEM_PROMPT and #cfg.SYSTEM_PROMPT > 0 then
    table.insert(conversation_history, { role = "system", content = cfg.SYSTEM_PROMPT })
  end

  local initial_prompt = string.format(
    "Instruction: %s\n\nCurrent file context:\nPath: %s\nFilename: %s\nLanguage Extension: %s\n\nFull file content:\n%s",
    initial_instruction,
    target_buffer.path,
    target_buffer.filename,
    utils.get_file_extension(target_buffer.filename),
    target_buffer.content
  )
  table.insert(conversation_history, { role = "user", content = initial_prompt })

  local max_turns = cfg.MAX_CONVERSATION_TURNS or 5 -- Max turns can be in .env
  local current_turn = 0

  -- 3. Цикл диалога с моделью
  while current_turn < max_turns do
    current_turn = current_turn + 1
    print(string.format("\n--- Conversation Turn %d ---", current_turn))

    local request_data = {
      model = cfg.API_MODEL, -- Include model name from config
      messages = conversation_history,
      stream = false
      -- Add other params like temperature from cfg if needed
      -- options = { temperature = cfg.TEMPERATURE or 0.7 }
    }

    print("Sending request to LLM (model: " .. cfg.API_MODEL .. ")...")
    -- For debugging, show only the last user message concisely
    -- if #conversation_history > 0 then
    --   local last_msg = conversation_history[#conversation_history]
    --   print("Last message sent (content preview): " .. string.sub(last_msg.content, 1, 100) .. (#last_msg.content > 100 and "..." or ""))
    -- end


    local response_data, err = llm_handler.send_request(request_data)

    if not response_data then
      print("Error: Failed to get response from LLM:", err)
      break
    end

    local response_text, think_text = llm_handler.extract_response_and_think_content(
      llm_handler.extract_response_text(response_data)
    )

    if not response_text then
      print("Error: Could not extract text from LLM response.")
      -- print("Raw response:", inspect(response_data)) -- For debugging
      break
    end

    print("LLM Thinks:\n" .. think_text)
    print("\nLLM Response:\n" .. response_text)
    table.insert(conversation_history, {
      role = "assistant",
      content = [[
          thinks: ]] .. think_text .. [[
          response: ]] .. response_text .. [[
        ]]
    })

    -- 4. Анализ ответа и выполнение действий
    local requested_file_path = llm_handler.find_file_request(response_text)
    local is_patch = llm_handler.is_patch_format(response_text)

    if is_patch then
      print("Detected patch format. Attempting to apply to: " .. target_buffer.path)
      local success, patch_err = neovim.apply_patch_to_temp_file_and_sync(target_buffer.server, target_buffer.path,
        response_text)
      if success then
        print("Patch applied successfully and buffer reloaded.")
        -- Optionally, update target_buffer.content if needed for further conversation
        local updated_content_json, _ = neovim.nvr_command(target_buffer.server,
          '--remote-expr "json_encode(join(getline(1, \'$\'), \'\\n\'))"')
        if updated_content_json then
          local updated_content, _ = JSON:decode(updated_content_json)
          if updated_content then target_buffer.content = updated_content end
        end
      else
        print("Error applying patch:", patch_err)
        -- Inform LLM about patching failure
        table.insert(conversation_history,
          {
            role = "user",
            content = "The patch application failed with the following error: " ..
                patch_err .. "\nPlease review the patch AND return fixed alternative."
          })
        goto continue_loop -- Continue conversation to let LLM try again or give different instructions
      end
      -- Decide if conversation should end after successful patch
      print("Task involving patch completed.")
      break -- End conversation after attempting a patch
    elseif requested_file_path then
      print("LLM requested file:", requested_file_path)
      -- Ensure requested_file_path is treated as relative to PROJECT_ROOT
      local absolute_path = utils.join_path(cfg.PROJECT_ROOT, requested_file_path)

      if not absolute_path then
        print("Error: Could not resolve path: " .. requested_file_path .. " relative to " .. cfg.PROJECT_ROOT)
        table.insert(conversation_history,
          { role = "user", content = "Error: Could not resolve the requested path: " .. requested_file_path })
        goto continue_loop
      end

      print("Attempting to read resolved path:", absolute_path)
      local file_content, read_err = utils.read_file(absolute_path)

      if not file_content then
        print("Error reading requested file:", read_err)
        table.insert(conversation_history, {
          role = "user",
          content = "I could not read the file you requested: " .. requested_file_path ..
              ". Reason: " .. (read_err or "File not found or permission denied.") ..
              " Please ensure the path is correct and relative to the project root: " .. cfg.PROJECT_ROOT
        })
      else
        print("Sending content of", requested_file_path, "to LLM...")
        local file_prompt = string.format(
          "Here is the content of the file you requested (`%s`):\n\n```%s\n%s\n```\nNow, please continue with your original task based on this information and the previous context.",
          requested_file_path,
          utils.get_file_extension(requested_file_path), -- for syntax highlighting
          file_content
        )
        table.insert(conversation_history, { role = "user", content = file_prompt })
      end
    else
      print("LLM provided a general response. No specific action (patch/file request) detected.")
      -- Ask user if they want to continue or if the task is done.
      io.stdout:write("LLM provided a general response. Do you want to continue the conversation? (yes/no): ")
      io.stdout:flush()
      local user_choice = io.read()
      if user_choice:lower():match("^n") then
        print("Task finished based on user input.")
        break
      else
        io.stdout:write("Your follow-up instruction (or press Enter to let assistant continue): ")
        io.stdout:flush()
        local follow_up_instruction = io.read()
        if #follow_up_instruction > 0 then
          table.insert(conversation_history, { role = "user", content = follow_up_instruction })
        else
          -- If no specific follow-up, we might need a generic prompt to ask the LLM what to do next,
          -- or simply let it continue based on its last response.
          -- For now, if the user says 'yes' but gives no new instruction, we let the loop continue,
          -- and the LLM will respond based on its previous "assistant" message.
          -- This might lead to repetitive behavior if the LLM is stuck.
          -- A better approach might be to insert a "user" message like "Please continue." or "What's next?".
          table.insert(conversation_history,
            { role = "user", content = "Please continue or clarify your previous response if no action was taken." })
        end
      end
    end
    ::continue_loop::
  end

  if current_turn >= max_turns then
    print("Warning: Reached maximum conversation turns limit.")
  end

  print("\n--- Assistant finished ---")
end

-- Entry point
local args = { ... }
if #args == 0 then
  io.stdout:write("Enter your instruction for the AI assistant: ")
  io.stdout:flush()
  local instruction = io.read()
  if not instruction or #instruction == 0 then
    print("Error: No instruction provided.")
  else
    run_assistant(instruction)
  end
else
  run_assistant(args[1])
end
