--- Small persistent JSON stores: favorites, bookmarks, history, user sources.
local util = require("rtfm.util")

local M = {}

local loaded = {}

local function path(name)
  return util.data_dir() .. "/" .. name .. ".json"
end

function M.load(name, default)
  if loaded[name] == nil then
    loaded[name] = util.read_json(path(name)) or default or {}
  end
  return loaded[name]
end

function M.save(name)
  if loaded[name] ~= nil then
    util.write_json(path(name), loaded[name])
  end
end

function M.reset(name)
  loaded[name] = nil
end

-- favorites: { [source_id] = true } ---------------------------------------------------------

function M.is_favorite(id)
  return M.load("favorites")[id] == true
end

function M.toggle_favorite(id)
  local favs = M.load("favorites")
  favs[id] = (not favs[id]) or nil
  M.save("favorites")
  return favs[id] == true
end

-- history: newest first, deduped by source+key ---------------------------------------------

M.HISTORY_MAX = 300

local function entry_key(source_id, item)
  return source_id .. "\0" .. (item.url or item.path or item.id or item.title or "")
end
M.entry_key = entry_key

function M.add_history(source_id, item, title)
  local hist = M.load("history")
  local key = entry_key(source_id, item)
  for i = #hist, 1, -1 do
    if hist[i].key == key then
      table.remove(hist, i)
    end
  end
  table.insert(hist, 1, { key = key, source = source_id, item = item, title = title or item.title, ts = os.time() })
  while #hist > M.HISTORY_MAX do
    table.remove(hist)
  end
  M.save("history")
end

function M.history(source_id)
  local out = {}
  for _, h in ipairs(M.load("history")) do
    if not source_id or h.source == source_id then
      table.insert(out, h)
    end
  end
  return out
end

--- Source ids ordered by most recent use.
function M.recent_sources()
  local seen, out = {}, {}
  for _, h in ipairs(M.load("history")) do
    if not seen[h.source] then
      seen[h.source] = true
      table.insert(out, h.source)
    end
  end
  return out
end

-- bookmarks ------------------------------------------------------------------------------

function M.bookmarks()
  return M.load("bookmarks")
end

function M.is_bookmarked(source_id, item)
  local key = entry_key(source_id, item)
  for _, b in ipairs(M.bookmarks()) do
    if b.key == key then
      return true
    end
  end
  return false
end

function M.add_bookmark(source_id, item, title, note)
  local key = entry_key(source_id, item)
  local list = M.bookmarks()
  for _, b in ipairs(list) do
    if b.key == key then
      b.note = note or b.note
      b.title = title or b.title
      M.save("bookmarks")
      return false
    end
  end
  table.insert(list, 1, { key = key, source = source_id, item = item, title = title or item.title, note = note, ts = os.time() })
  M.save("bookmarks")
  return true
end

function M.remove_entry(name, key)
  local list = M.load(name)
  for i = #list, 1, -1 do
    if list[i].key == key then
      table.remove(list, i)
    end
  end
  M.save(name)
end

-- user-added sources ----------------------------------------------------------------------

function M.user_sources()
  return M.load("sources")
end

function M.add_source(id, spec)
  M.user_sources()[id] = spec
  M.save("sources")
end

function M.remove_source(id)
  local srcs = M.user_sources()
  if srcs[id] == nil then
    return false
  end
  srcs[id] = nil
  M.save("sources")
  return true
end

return M
