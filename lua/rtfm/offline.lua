--- Installed (offline) docs: stored under stdpath("data")/rtfm/docs/<source>/.
local config = require("rtfm.config")
local util = require("rtfm.util")

local M = {}

local function safe(id)
  return (id:gsub("[^%w%._~@-]", "_"))
end

function M.dir(source)
  return util.data_dir("docs") .. "/" .. safe(source.id)
end

local function manifest_path(source)
  return M.dir(source) .. "/manifest.json"
end

local manifest_mem = {}

function M.manifest(source)
  local p = manifest_path(source)
  if manifest_mem[p] == nil then
    manifest_mem[p] = util.read_json(p) or false
  end
  return manifest_mem[p] or nil
end

function M.is_installed(source)
  return M.manifest(source) ~= nil
end

function M.read_file(source, name)
  if not M.is_installed(source) then
    return nil
  end
  return util.read_file(M.dir(source) .. "/" .. name)
end

function M.list()
  local root = util.data_dir("docs")
  local out = {}
  for name, typ in vim.fs.dir(root) do
    if typ == "directory" then
      local m = util.read_json(root .. "/" .. name .. "/manifest.json")
      if m then
        m.dir = root .. "/" .. name
        table.insert(out, m)
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.name or "") < (b.name or "")
  end)
  return out
end

-- generic page store --------------------------------------------------------------------

local function page_file(key)
  return vim.fn.sha256(key):sub(1, 24) .. ".json"
end

local pages_index_mem = {}

local function pages_index(source)
  local dir = M.dir(source)
  if pages_index_mem[dir] == nil then
    pages_index_mem[dir] = util.read_json(dir .. "/pages.json") or false
  end
  return pages_index_mem[dir] or nil
end

function M.read_page(source, key)
  local idx = pages_index(source)
  if not idx or not idx[key] then
    return nil
  end
  local data = util.read_json(M.dir(source) .. "/pages/" .. idx[key].file)
  return data
end

--- Iterate all installed pages: fn(key, raw).
function M.each_page(source, fn)
  local adapter = require("rtfm.sources").adapter(source.adapter)
  if adapter.each_page and adapter.each_page(source, fn) then
    return true
  end
  local idx = pages_index(source)
  if not idx then
    return false
  end
  for key, meta in pairs(idx) do
    local raw = util.read_json(M.dir(source) .. "/pages/" .. meta.file)
    if raw then
      fn(key, raw)
    end
  end
  return true
end

function M.entries(source)
  local raw = M.read_file(source, "entries.json")
  return raw and util.json_decode(raw) or nil
end

local function forget(source)
  local dir = M.dir(source)
  manifest_mem[dir .. "/manifest.json"] = nil
  pages_index_mem[dir] = nil
  local adapter = require("rtfm.sources").adapter(source.adapter)
  if adapter.forget_installed then
    adapter.forget_installed(source)
  end
end

function M.installable(source)
  local adapter = require("rtfm.sources").adapter(source.adapter)
  if source.adapter == "gopkg" or source.adapter == "docsrs" then
    return source.version ~= nil and source.version ~= "latest"
  end
  return adapter.install ~= nil or adapter.pages ~= nil
end

--- Download everything for a source.
---@param opts? {on_progress?: fun(msg: string), index?: boolean}
---@param cb? fun(err: string|nil, manifest: table|nil)
function M.install(source, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  local sources = require("rtfm.sources")
  local adapter = sources.adapter(source.adapter)
  if not M.installable(source) then
    return cb(("'%s' can't be installed for offline use (pick a versioned source, a devdoc or a sitemap source)"):format(source.id))
  end
  if config.options.offline then
    return cb("offline mode is on")
  end
  local dir = M.dir(source)
  vim.fn.mkdir(dir, "p")
  local progress = opts.on_progress or function() end

  local function finish(err, stats)
    if err then
      return cb(err)
    end
    local manifest = {
      id = source.id,
      name = source.name,
      adapter = source.adapter,
      version = source.version,
      installed_at = os.time(),
      pages = stats and stats.pages or 0,
      source = source,
    }
    util.write_json(dir .. "/manifest.json", manifest)
    forget(source)
    cb(nil, manifest)
  end

  if adapter.install then
    return adapter.install(source, dir, progress, finish)
  end

  -- generic: enumerate pages, fetch each, store raw content + collect entries
  progress("listing pages")
  adapter.pages(source, function(err, items)
    if err then
      return finish(err)
    end
    local max = config.options.offline_install.max_pages
    if #items > max then
      progress(("limiting to %d of %d pages"):format(max, #items))
      items = vim.list_slice(items, 1, max)
    end
    local index, entries = {}, {}
    local by_page = {}
    for _, it in ipairs(items) do
      table.insert(entries, it)
      local key = adapter.page_key and adapter.page_key(source, it) or it.url
      if not by_page[key] then
        by_page[key] = it
      end
    end
    local keys = vim.tbl_keys(by_page)
    local delay = config.options.offline_install.delay
    vim.fn.mkdir(dir .. "/pages", "p")
    util.parallel(keys, config.options.offline_install.concurrency, function(key, done)
      local item = by_page[key]
      adapter.fetch(source, item, function(ferr, raw)
        if ferr or not raw then
          return done(ferr or "empty page")
        end
        local file = page_file(key)
        raw.item = item
        util.write_json(dir .. "/pages/" .. file, raw)
        index[key] = { file = file, title = item.title, url = raw.url }
        if adapter.symbols and raw.html then
          local ok, syms = pcall(adapter.symbols, raw, item)
          if ok then
            vim.list_extend(entries, syms)
          end
        end
        if delay > 0 then
          vim.defer_fn(function()
            done()
          end, delay)
        else
          done()
        end
      end)
    end, function(n, total)
      if n % 5 == 0 or n == total then
        progress(("pages %d/%d"):format(n, total))
      end
    end, function(errors)
      util.write_json(dir .. "/pages.json", index)
      util.write_json(dir .. "/entries.json", entries)
      if #errors > 0 then
        progress(("%d pages failed (first: %s)"):format(#errors, errors[1]))
      end
      finish(nil, { pages = vim.tbl_count(index) })
    end)
  end)
end

function M.uninstall(source)
  local dir = M.dir(source)
  if not util.exists(dir) then
    return false
  end
  vim.fn.delete(dir, "rf")
  forget(source)
  require("rtfm.index").forget(source)
  return true
end

return M
