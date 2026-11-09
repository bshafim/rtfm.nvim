local M = {}

function M.check()
  local health = vim.health
  local config = require("rtfm.config")
  health.start("rtfm.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required")
  end

  if vim.fn.executable("curl") == 1 then
    health.ok("curl found")
  else
    health.error("curl is required for fetching docs")
  end

  if vim.fn.executable("pandoc") == 1 then
    health.ok("pandoc found (set html.converter = 'auto' or 'pandoc' to use it)")
  else
    health.info("pandoc not found (optional)")
  end

  local ok_ts = pcall(vim.treesitter.language.inspect, "markdown")
  if ok_ts then
    health.ok("treesitter markdown parser available")
  else
    health.warn("no treesitter markdown parser; doc buffers fall back to regex highlighting")
  end

  if require("rtfm.index.vec").has_ffi then
    health.ok("LuaJIT FFI available for fast vector search")
  else
    health.warn("no LuaJIT FFI; semantic search will be slower")
  end

  local data = require("rtfm.util").data_dir()
  if vim.fn.filewritable(data) == 2 then
    health.ok("data dir: " .. data)
  else
    health.error("data dir not writable: " .. data)
  end

  if config.options.offline then
    health.info("offline mode is ON")
  end

  health.start("rtfm.nvim: semantic search")
  local embed = require("rtfm.index.embed")
  if not embed.enabled() then
    health.info("embeddings disabled; keyword (BM25) search only")
  else
    local e = config.options.index.embed
    local done, ok, err, dim = false, false, nil, nil
    embed.check(function(o, er, d)
      done, ok, err, dim = true, o, er, d
    end)
    vim.wait(5000, function()
      return done
    end, 50)
    if ok then
      health.ok(("%s model '%s' reachable (dim %d)"):format(e.provider, e.model, dim))
    else
      health.warn(("%s model '%s' not reachable: %s"):format(e.provider, e.model, err or "timeout"))
    end
  end
  local installed = require("rtfm.offline").list()
  health.info(("%d installed docs, %d indexed"):format(#installed, #require("rtfm.index").list()))
end

return M
