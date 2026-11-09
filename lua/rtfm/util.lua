local M = {}

local uv = vim.uv or vim.loop

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "rtfm" })
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

local function ensure(dir)
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.data_dir(sub)
  return ensure(vim.fn.stdpath("data") .. "/rtfm" .. (sub and ("/" .. sub) or ""))
end

function M.cache_dir(sub)
  return ensure(vim.fn.stdpath("cache") .. "/rtfm" .. (sub and ("/" .. sub) or ""))
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.write_file(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. ".tmp" .. tostring(uv.hrtime())
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  f:write(data)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr
  end
  return true
end

function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

function M.mtime(path)
  local stat = uv.fs_stat(path)
  return stat and stat.mtime.sec or nil
end

function M.json_decode(str)
  if not str or str == "" then
    return nil, "empty response"
  end
  local ok, res = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if not ok then
    return nil, "invalid JSON: " .. tostring(res):sub(1, 200)
  end
  return res
end

function M.read_json(path)
  local data = M.read_file(path)
  if not data then
    return nil
  end
  return (M.json_decode(data))
end

function M.write_json(path, value)
  return M.write_file(path, vim.json.encode(value))
end

--- Debounced callable; `.cancel()` drops a pending call, `.close()` frees the timer.
function M.debounce(ms, fn)
  local timer = assert(uv.new_timer())
  local self = {}
  setmetatable(self, {
    __call = function(_, ...)
      local args = { n = select("#", ...), ... }
      timer:stop()
      timer:start(ms, 0, function()
        vim.schedule(function()
          fn(unpack(args, 1, args.n))
        end)
      end)
    end,
  })
  function self.cancel()
    timer:stop()
  end
  function self.close()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  return self
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- "build-and-push_images.html" -> "Build and push images"
function M.humanize(slug)
  slug = slug:gsub("%.html?$", ""):gsub("[-_]+", " ")
  slug = M.trim(slug)
  return (slug:gsub("^%l", string.upper))
end

function M.open_in_browser(url)
  if not url then
    return
  end
  local ok, _, err = pcall(vim.ui.open, url)
  if not ok or err then
    M.error("could not open " .. url)
  end
end

--- Small LRU map.
function M.lru(capacity)
  local self = { map = {}, order = {} }
  local function touch(key)
    for i, k in ipairs(self.order) do
      if k == key then
        table.remove(self.order, i)
        break
      end
    end
    table.insert(self.order, key)
  end
  function self.get(key)
    local v = self.map[key]
    if v ~= nil then
      touch(key)
    end
    return v
  end
  function self.set(key, value)
    if self.map[key] == nil and #self.order >= capacity then
      self.map[table.remove(self.order, 1)] = nil
    end
    self.map[key] = value
    touch(key)
  end
  function self.clear()
    self.map, self.order = {}, {}
  end
  return self
end

--- Run async tasks with a concurrency limit.
--- task(item, done) must call done(err?) exactly once.
---@param on_progress? fun(done: integer, total: integer)
function M.parallel(items, limit, task, on_progress, on_done)
  local total, next_i, running, finished = #items, 1, 0, 0
  local errors = {}
  local stopped = false
  if total == 0 then
    vim.schedule(function()
      on_done(errors)
    end)
    return { stop = function() end }
  end
  local function launch()
    while not stopped and running < limit and next_i <= total do
      local item = items[next_i]
      next_i = next_i + 1
      running = running + 1
      local called = false
      task(item, function(err)
        if called then
          return
        end
        called = true
        running = running - 1
        finished = finished + 1
        if err then
          table.insert(errors, err)
        end
        if on_progress then
          on_progress(finished, total)
        end
        if finished == total or (stopped and running == 0) then
          on_done(errors)
        else
          launch()
        end
      end)
    end
  end
  launch()
  return {
    stop = function()
      stopped = true
    end,
  }
end

--- Compare dotted versions ("1.22.3" vs "1.9"). Returns -1, 0, 1.
function M.version_cmp(a, b)
  local function parts(v)
    local out = {}
    for n in tostring(v):gmatch("%d+") do
      table.insert(out, tonumber(n))
    end
    return out
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

function M.dir_size(path)
  local total = 0
  local handle = uv.fs_scandir(path)
  if not handle then
    return 0
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local full = path .. "/" .. name
    if typ == "directory" then
      total = total + M.dir_size(full)
    else
      local st = uv.fs_stat(full)
      total = total + (st and st.size or 0)
    end
  end
  return total
end

function M.human_size(bytes)
  local units = { "B", "KB", "MB", "GB" }
  local i = 1
  while bytes >= 1024 and i < #units do
    bytes = bytes / 1024
    i = i + 1
  end
  return (i == 1 and "%d %s" or "%.1f %s"):format(bytes, units[i])
end

return M
