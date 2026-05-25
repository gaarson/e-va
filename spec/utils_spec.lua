local utils = require("utils")
local os = require("os")

describe("utils module", function()
  describe("trim()", function()
    it("should remove leading and trailing whitespace", function()
      assert.are.equal("hello", utils.trim("  hello  "))
      assert.are.equal("hello world", utils.trim("\t hello world \n"))
    end)

    it("should handle nil gracefully", function()
      assert.are.equal("", utils.trim(nil))
    end)
  end)

  describe("normalize_path()", function()
    it("should strip path/file prefixes and quotes", function()
      local root = "/home/ruser/projects/E-va"
      assert.are.equal("src/main.c", utils.normalize_path(root, "path: 'src/main.c'"))
      assert.are.equal("src/main.c", utils.normalize_path(root, 'file="src/main.c"'))
    end)

    it("should remove project root if path is absolute", function()
      local root = "/home/projects/E-va"
      local absolute = "/home/projects/E-va/config.lua"
      assert.are.equal("config.lua", utils.normalize_path(root, absolute))
    end)
  end)

  describe("deep_merge()", function()
    it("should recursively merge two tables", function()
      local base = { a = 1, b = { x = 10, y = 20 } }
      local specific = { b = { y = 99, z = 30 }, c = 2 }

      local merged = utils.deep_merge(base, specific)

      assert.are.equal(1, merged.a)
      assert.are.equal(10, merged.b.x)
      assert.are.equal(99, merged.b.y)
      assert.are.equal(30, merged.b.z)
      assert.are.equal(2, merged.c)
    end)

    it("should handle nil inputs gracefully", function()
      local base = { a = 1 }
      local merged = utils.deep_merge(base, nil)
      assert.are.equal(1, merged.a)

      local merged2 = utils.deep_merge(nil, base)
      assert.are.equal(1, merged2.a)
    end)
  end)

  describe("load_config()", function()
    local test_file = "test_config_tmp.lua"

    after_each(function()
      os.remove(test_file)
    end)

    it("should load legacy config that returns a table with M.get()", function()
      utils.write_file(test_file, [[
        local M = {}
        function M.get() return { is_legacy = true, val = 42 } end
        return M
      ]])

      local cfg, err = utils.load_config(test_file)
      assert.is_nil(err)
      assert.is_table(cfg)
      assert.is_true(cfg.is_legacy)
      assert.are.equal(42, cfg.val)
    end)

    it("should load modern config that directly returns a table", function()
      utils.write_file(test_file, [[
        return { is_modern = true, val = 99 }
      ]])

      local cfg, err = utils.load_config(test_file)
      assert.is_nil(err)
      assert.is_table(cfg)
      assert.is_true(cfg.is_modern)
      assert.are.equal(99, cfg.val)
    end)

    it("should handle invalid config paths or errors gracefully", function()
      local cfg, err = utils.load_config("non_existent_fake_path.lua")
      assert.is_nil(cfg)
      assert.truthy(err:match("cannot open") or err:match("No such file"))

      utils.write_file(test_file, "return function() end")
      local cfg2, err2 = utils.load_config(test_file)
      assert.is_nil(cfg2)
      assert.truthy(err2:match("must return a table"))
    end)
  end)

  describe("base64_encode()", function()
    it("should encode empty string to empty result", function()
      assert.are.equal("", utils.base64_encode(""))
    end)

    it("should encode known ASCII strings correctly", function()
      assert.are.equal("TWFu", utils.base64_encode("Man"))
      assert.are.equal("TWE=", utils.base64_encode("Ma"))
      assert.are.equal("TQ==", utils.base64_encode("M"))
      assert.are.equal("SGVsbG8sIFdvcmxkIQ==", utils.base64_encode("Hello, World!"))
      assert.are.equal("", utils.base64_encode(""))
    end)

    it("should encode binary data correctly", function()
      local binary_data = ""
      for i = 0, 255 do
        binary_data = binary_data .. string.char(i)
      end
      local encoded = utils.base64_encode(binary_data)
      assert.truthy(encoded:len() > 0, "Encoded string should not be empty")
      assert.truthy(encoded:match("^[A-Za-z0-9+/]+=*$"), "Should only contain valid base64 characters")
    end)

    it("should produce correct padding for all remainder cases", function()
      -- Length 1 -> 2 padding chars (==)
      assert.are.equal("TQ==", utils.base64_encode("M"))
      -- Length 2 -> 1 padding char (=)
      assert.are.equal("TWE=", utils.base64_encode("Ma"))
      -- Length 3 -> no padding
      assert.are.equal("TWFu", utils.base64_encode("Man"))
      -- Length 4 -> 2 padding chars (==)
      assert.are.equal("TWFuYQ==", utils.base64_encode("Mana"))
      -- Length 5 -> 1 padding char (=)
      assert.are.equal("TWFuYXk=", utils.base64_encode("Manay"))
    end)
  end)

  describe("load_images_from_dir()", function()
    local test_dir = "/tmp/e_va_test_images_" .. os.time()

    after_each(function()
      -- Cleanup temp files
      local handle = io.popen("ls " .. test_dir .. " 2>/dev/null")
      if handle then
        local files = handle:read("*a")
        handle:close()
        for f in files:gmatch("[^\r\n]+") do
          if f ~= "" then os.remove(test_dir .. "/" .. f) end
        end
      end
      os.execute("rmdir " .. test_dir .. " 2>/dev/null")
    end)

    it("should return empty table for non-existent directory", function()
      local result = utils.load_images_from_dir("/nonexistent/path_xyz")
      assert.same({}, result)
    end)

    it("should return empty table for nil input", function()
      local result = utils.load_images_from_dir(nil)
      assert.same({}, result)
    end)

    it("should scan directory and return image metadata", function()
      os.execute("mkdir -p " .. test_dir)
      -- Write a minimal valid PNG header
      local png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde"
      utils.write_file(test_dir .. "/test.png", png_header)

      local result = utils.load_images_from_dir(test_dir)
      assert.are.equal(1, #result)
      assert.truthy(result[1].path:match("test%.png$"))
      assert.are.equal("image/png", result[1].mime_type)
      assert.truthy(result[1].base64_data:len() > 0)
    end)

    it("should map extensions to correct MIME types", function()
      os.execute("mkdir -p " .. test_dir)
      utils.write_file(test_dir .. "/img.jpg", "fake_jpg_data")
      utils.write_file(test_dir .. "/img.gif", "fake_gif_data")
      utils.write_file(test_dir .. "/img.webp", "fake_webp_data")
      utils.write_file(test_dir .. "/img.bmp", "fake_bmp_data")

      local result = utils.load_images_from_dir(test_dir)
      assert.are.equal(4, #result)

      local mime_found = {}
      for _, img in ipairs(result) do
        mime_found[img.mime_type] = true
      end
      assert.is_true(mime_found["image/jpeg"])
      assert.is_true(mime_found["image/gif"])
      assert.is_true(mime_found["image/webp"])
      assert.is_true(mime_found["image/bmp"])
    end)

    it("should ignore non-image files", function()
      os.execute("mkdir -p " .. test_dir)
      utils.write_file(test_dir .. "/notes.txt", "ignore me")
      utils.write_file(test_dir .. "/code.lua", "ignore me too")
      local png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde"
      utils.write_file(test_dir .. "/valid.png", png_header)

      local result = utils.load_images_from_dir(test_dir)
      assert.are.equal(1, #result)
      assert.are.equal("image/png", result[1].mime_type)
    end)
  end)

  describe("apply_agent_defaults()", function()
    it("should fill missing url/model/params from AGENT_DEFAULTS", function()
      local config = {
        AGENT_DEFAULTS = {
          url = "http://defaults:8000/v1/chat/completions",
          model = "default-model",
          is_reasoning = false,
          params = { stream = true, temperature = 0.1 }
        },
        AGENTS = {
          AGENT_A = {
            name = "AGENT_A",
            prompt_file = "prompts/a.md",
            allowed_tools = { "read_file" }
          }
        }
      }

      local result = utils.apply_agent_defaults(config)

      assert.are.equal("http://defaults:8000/v1/chat/completions", result.AGENTS.AGENT_A.url)
      assert.are.equal("default-model", result.AGENTS.AGENT_A.model)
      assert.are.equal(false, result.AGENTS.AGENT_A.is_reasoning)
      assert.is_table(result.AGENTS.AGENT_A.params)
      assert.are.equal(true, result.AGENTS.AGENT_A.params.stream)
      assert.are.equal(0.1, result.AGENTS.AGENT_A.params.temperature)
    end)

    it("should NOT overwrite existing fields", function()
      local config = {
        AGENT_DEFAULTS = {
          url = "http://defaults:8000/v1/chat/completions",
          model = "default-model",
          is_reasoning = false,
          params = { stream = true, temperature = 0.1 }
        },
        AGENTS = {
          AGENT_B = {
            name = "AGENT_B",
            url = "http://custom:9999/v1/chat/completions",
            model = "custom-model",
            is_reasoning = true,
            params = { temperature = 0.9, max_tokens = 4096 },
            prompt_file = "prompts/b.md",
            allowed_tools = { "shell" }
          }
        }
      }

      local result = utils.apply_agent_defaults(config)

      assert.are.equal("http://custom:9999/v1/chat/completions", result.AGENTS.AGENT_B.url)
      assert.are.equal("custom-model", result.AGENTS.AGENT_B.model)
      assert.are.equal(true, result.AGENTS.AGENT_B.is_reasoning)
      assert.are.equal(0.9, result.AGENTS.AGENT_B.params.temperature)
      assert.are.equal(4096, result.AGENTS.AGENT_B.params.max_tokens)
      assert.are.equal(true, result.AGENTS.AGENT_B.params.stream) -- inherited from defaults
    end)

    it("should deep-merge params correctly (agent overrides defaults)", function()
      local config = {
        AGENT_DEFAULTS = {
          url = "http://defaults:8000/v1/chat/completions",
          model = "default-model",
          params = { stream = true, temperature = 0.1, top_p = 0.5, stop = { "STOP" } }
        },
        AGENTS = {
          AGENT_C = {
            name = "AGENT_C",
            params = { temperature = 0.8, max_tokens = 8192 }
          }
        }
      }

      local result = utils.apply_agent_defaults(config)

      -- Agent-specific values should win
      assert.are.equal(0.8, result.AGENTS.AGENT_C.params.temperature)
      assert.are.equal(8192, result.AGENTS.AGENT_C.params.max_tokens)
      -- Default values should be present
      assert.are.equal(true, result.AGENTS.AGENT_C.params.stream)
      assert.are.equal(0.5, result.AGENTS.AGENT_C.params.top_p)
      assert.is_table(result.AGENTS.AGENT_C.params.stop)
    end)

    it("should handle gracefully when AGENT_DEFAULTS is nil", function()
      local config = {
        AGENTS = {
          AGENT_D = {
            name = "AGENT_D",
            url = "http://existing:8000/v1/chat/completions",
            model = "existing-model"
          }
        }
      }

      local result = utils.apply_agent_defaults(config)

      -- Should remain unchanged
      assert.are.equal("http://existing:8000/v1/chat/completions", result.AGENTS.AGENT_D.url)
      assert.are.equal("existing-model", result.AGENTS.AGENT_D.model)
      assert.is_nil(result.AGENTS.AGENT_D.params)
    end)
  end)

end)