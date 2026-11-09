--- Uniform search over sources: local entry lists (fuzzy) and remote adapters.
local fuzzy = require("rtfm.fuzzy")
local offline = require("rtfm.offline")
local sources = require("rtfm.sources")

local M = {}

local entries_mem = {}

--- Full entry list for a local source (installed copy first).
function M.load(source, cb)
  local key = source.id
  if entries_mem[key] then
    return vim.schedule(function()
      cb(nil, entries_mem[key])
    end)
  end
  local installed = offline.entries(source)
  if installed then
    entries_mem[key] = installed
    return vim.schedule(function()
      cb(nil, installed)
    end)
  end
  sources.adapter(source.adapter).load(source, function(err, items)
    if not err then
      entries_mem[key] = items
    end
    cb(err, items)
  end)
end

function M.forget(source_id)
  entries_mem[source_id] = nil
end

--- Run a query against a source. Returns fuzzy matches ({item, positions, score}).
---@param cb fun(err: string|nil, matches: table[]|nil)
---@return {cancel: fun()}|nil
function M.query(source, query, cb, limit)
  if sources.mode(source) == "local" then
    M.load(source, function(err, items)
      if err then
        return cb(err)
      end
      cb(nil, fuzzy.filter(items, query, limit))
    end)
    return nil
  end
  if vim.trim(query) == "" then
    vim.schedule(function()
      cb(nil, {})
    end)
    return nil
  end
  return sources.adapter(source.adapter).search(source, query, function(err, items)
    if err then
      local installed = offline.entries(source)
      if installed then
        return cb(nil, fuzzy.filter(installed, query, limit))
      end
      return cb(err)
    end
    local out = {}
    for i, it in ipairs(items or {}) do
      out[i] = { item = it, positions = {}, score = 0 }
    end
    cb(nil, out)
  end)
end

return M
