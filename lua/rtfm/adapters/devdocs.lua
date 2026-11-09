--- DevDocs (devdocs.io): ~800 docs with prebuilt search indexes.
local cache = require("rtfm.cache")
local http = require("rtfm.http")
local util = require("rtfm.util")

local M = {}

M.mode = "local"
M.CATALOG_URL = "https://devdocs.io/docs.json"
M.DOCS_URL = "https://documents.devdocs.io"
M.WEB_URL = "https://devdocs.io"

local catalog_mem

--- Catalog of all docs (cached for a week, stale copy used offline).
function M.catalog(cb)
  if catalog_mem then
    return vim.schedule(function()
      cb(nil, catalog_mem)
    end)
  end
  cache.fetch_json(M.CATALOG_URL, { key = "devdocs/docs.json", ttl = 7 * 24 * 3600 }, function(err, data)
    if err then
      return cb(err)
    end
    catalog_mem = data
    cb(nil, data)
  end)
end

function M.catalog_cached()
  return catalog_mem
end

function M.base_slug(slug)
  return (slug:match("^([^~]+)") or slug)
end

function M.source_from_entry(e)
  local version = e.version ~= "" and e.version or nil
  return {
    id = e.slug,
    name = e.name .. (version and (" " .. version) or ""),
    adapter = "devdocs",
    slug = e.slug,
    base = M.base_slug(e.slug),
    doc_name = e.name,
    version = version,
    release = e.release,
    mtime = e.mtime,
    db_size = e.db_size,
    home = e.links and e.links.home,
    alias = e.alias,
    lang = M.base_slug(e.slug),
  }
end

local function split_path(path)
  local page, frag = path:match("^([^#]*)#(.*)$")
  return page or path, frag
end

function M.web_url(source, path)
  return M.WEB_URL .. "/" .. source.slug .. "/" .. path
end

local function to_items(source, data)
  local items = {}
  for i, e in ipairs(data.entries or {}) do
    local page, frag = split_path(e.path)
    items[i] = {
      title = e.name,
      kind = e.type,
      path = e.path,
      fragment = frag,
      page = page,
      url = M.web_url(source, e.path),
    }
  end
  return items
end

local index_mem = {}

---@param cb fun(err: string|nil, items: table[]|nil)
function M.load(source, cb)
  local key = source.slug .. "@" .. tostring(source.mtime)
  if index_mem[key] then
    return vim.schedule(function()
      cb(nil, index_mem[key])
    end)
  end
  local offline = require("rtfm.offline")
  local installed = offline.read_file(source, "index.json")
  if installed then
    local data = util.json_decode(installed)
    if data then
      index_mem[key] = to_items(source, data)
      return vim.schedule(function()
        cb(nil, index_mem[key])
      end)
    end
  end
  local url = ("%s/%s/index.json?%s"):format(M.DOCS_URL, source.slug, source.mtime or "")
  cache.fetch_json(url, { key = ("devdocs/%s/index-%s.json"):format(source.slug, tostring(source.mtime)), ttl = -1 }, function(err, data)
    if err then
      return cb(err)
    end
    index_mem[key] = to_items(source, data)
    cb(nil, index_mem[key])
  end)
end

function M.page_key(_, item)
  return item.page or (split_path(item.path))
end

local db_mem = {}

local function installed_db(source)
  if db_mem[source.slug] == nil then
    local raw = require("rtfm.offline").read_file(source, "db.json")
    db_mem[source.slug] = raw and util.json_decode(raw) or false
  end
  return db_mem[source.slug] or nil
end

function M.forget_installed(source)
  db_mem[source.slug] = nil
  for k in pairs(index_mem) do
    if k:find(source.slug .. "@", 1, true) == 1 then
      index_mem[k] = nil
    end
  end
end

function M.fetch(source, item, cb)
  local page = M.page_key(source, item)
  local web = M.web_url(source, page)
  local db = installed_db(source)
  if db and db[page] then
    return vim.schedule(function()
      cb(nil, { html = db[page], url = web, base = web, extract = false, lang = source.lang })
    end)
  end
  local url = ("%s/%s/%s.html?%s"):format(M.DOCS_URL, source.slug, page, source.mtime or "")
  return cache.fetch(url, { key = "devdocs/" .. source.slug .. "/" .. page, ttl = 30 * 24 * 3600 }, function(err, body)
    if err then
      return cb(err)
    end
    cb(nil, { html = body, url = web, base = web, extract = false, lang = source.lang })
  end)
end

--- devdocs.io/<slug>/<path> links. May point at another doc (returns its source id).
function M.resolve(source, u)
  local slug, path = u:match("^https?://devdocs%.io/([^/]+)/(.+)$")
  if not slug then
    return nil
  end
  local page, frag = split_path(path)
  return {
    source_id = slug,
    item = { title = util.humanize(page:gsub("/index$", ""):match("([^/]+)$") or page), path = path, page = page, fragment = frag, url = u },
  }
end

--- Offline install: index.json + db.json straight from devdocs.
function M.install(source, dir, progress, cb)
  local base = ("%s/%s/"):format(M.DOCS_URL, source.slug)
  progress("downloading index")
  http.request({ url = base .. "index.json?" .. (source.mtime or ""), output = dir .. "/index.json", timeout = 120 }, function(err)
    if err then
      return cb(err)
    end
    progress(("downloading pages (%s)"):format(source.db_size and util.human_size(source.db_size) or "?"))
    http.request({ url = base .. "db.json?" .. (source.mtime or ""), output = dir .. "/db.json", timeout = 900 }, function(err2)
      if err2 then
        return cb(err2)
      end
      M.forget_installed(source)
      local db = installed_db(source)
      cb(nil, { pages = db and vim.tbl_count(db) or 0 })
    end)
  end)
end

--- Iterate every page (for indexing). Requires the doc to be installed.
function M.each_page(source, fn)
  local db = installed_db(source)
  if not db then
    return false
  end
  for page, html in pairs(db) do
    fn(page, { html = html, url = M.web_url(source, page), base = M.web_url(source, page), extract = false })
  end
  return true
end

return M
