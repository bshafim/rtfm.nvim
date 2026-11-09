--- Source registry: builtins, user config, user-added, devdocs catalog, versioned ids.
local config = require("rtfm.config")
local store = require("rtfm.store")
local util = require("rtfm.util")

local M = {}

M.BUILTIN = {
  github = { name = "GitHub Docs", adapter = "github", home = "https://docs.github.com" },
  mdn = { name = "MDN Web Docs", adapter = "mdn", home = "https://developer.mozilla.org" },
  gopkg = { name = "Go packages (pkg.go.dev)", adapter = "gopkg", lang = "go", home = "https://pkg.go.dev" },
  docsrs = { name = "Rust crates (docs.rs)", adapter = "docsrs", lang = "rust", home = "https://docs.rs" },
  web = { name = "Web page (paste a URL)", adapter = "web" },
  ["docker-docs"] = {
    name = "Docker Docs",
    adapter = "sitemap",
    url = "https://docs.docker.com/sitemap.xml",
    home = "https://docs.docker.com",
  },
}

-- adapters that understand "<adapter>:<param>" ids
local PARAM_ADAPTERS = { gopkg = true, docsrs = true }

local adapter_cache = {}
function M.adapter(name)
  if not adapter_cache[name] then
    local ok, mod = pcall(require, "rtfm.adapters." .. name)
    if not ok then
      error("rtfm: unknown adapter '" .. tostring(name) .. "'")
    end
    adapter_cache[name] = mod
  end
  return adapter_cache[name]
end

function M.mode(source)
  local a = M.adapter(source.adapter)
  if a.mode_for then
    return a.mode_for(source)
  end
  return a.mode or "remote"
end

local function normalize(id, spec)
  local s = vim.deepcopy(spec)
  s.id = id
  s.name = s.name or id
  return s
end

--- Sources that don't need the network to enumerate (builtin + config + user-added + installed).
function M.static()
  local out, seen = {}, {}
  local function add(id, spec)
    if spec and not seen[id] then
      seen[id] = true
      table.insert(out, normalize(id, spec))
    end
  end
  for id, spec in pairs(config.options.sources) do
    if spec ~= false then
      add(id, spec)
    else
      seen[id] = true
    end
  end
  for id, spec in pairs(store.user_sources()) do
    add(id, spec)
  end
  for id, spec in pairs(M.BUILTIN) do
    add(id, spec)
  end
  for _, m in ipairs(require("rtfm.offline").list()) do
    if m.source and not m.source.slug then -- devdocs ones come from the catalog
      add(m.source.id, m.source)
    end
  end
  table.sort(out, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function devdocs_sources(catalog)
  local dd = require("rtfm.adapters.devdocs")
  local opts = config.options.devdocs
  local only = opts.only and {} or nil
  for _, slug in ipairs(opts.only or {}) do
    only[slug] = true
  end
  local out, seen_name = {}, {}
  for _, e in ipairs(catalog or {}) do
    local keep
    if only then
      keep = only[e.slug] or only[dd.base_slug(e.slug)]
    elseif opts.latest_only then
      -- the catalog lists the newest version of each doc first
      keep = not seen_name[e.name] or store.is_favorite(e.slug) or require("rtfm.offline").is_installed({ id = e.slug })
    else
      keep = true
    end
    seen_name[e.name] = true
    if keep then
      table.insert(out, dd.source_from_entry(e))
    end
  end
  return out
end

--- All listable sources. Calls cb twice at most: immediately with static ones, then with the catalog.
---@param cb fun(sources: table[], complete: boolean)
function M.list(cb)
  local static = M.static()
  if not config.options.devdocs.enabled then
    return cb(static, true)
  end
  local dd = require("rtfm.adapters.devdocs")
  local cached = dd.catalog_cached()
  if cached then
    return cb(vim.list_extend(static, devdocs_sources(cached)), true)
  end
  cb(static, false)
  dd.catalog(function(err, catalog)
    if err then
      util.warn("could not load the DevDocs catalog: " .. err)
      return cb(static, true)
    end
    cb(vim.list_extend(vim.deepcopy(static), devdocs_sources(catalog)), true)
  end)
end

local function find_static(id)
  for _, s in ipairs(M.static()) do
    if s.id == id then
      return s
    end
  end
end

local function find_devdocs(catalog, id)
  local dd = require("rtfm.adapters.devdocs")
  id = id:lower()
  for _, e in ipairs(catalog) do
    if e.slug == id then
      return dd.source_from_entry(e)
    end
  end
  for _, e in ipairs(catalog) do
    if (e.alias and e.alias == id) or dd.base_slug(e.slug) == id or e.name:lower() == id then
      return dd.source_from_entry(e) -- first = newest
    end
  end
end

--- Resolve a source id. Accepts "go", "python~3.12", "py" (alias), "gopkg:mod@v1", "docsrs:serde@1.0".
---@param cb fun(err: string|nil, source: table|nil)
function M.get(id, cb)
  if type(id) == "table" then
    return vim.schedule(function()
      cb(nil, id)
    end)
  end
  local s = find_static(id)
  if s then
    return vim.schedule(function()
      cb(nil, s)
    end)
  end
  local adapter, param = id:match("^(%w+):(.+)$")
  if adapter and PARAM_ADAPTERS[adapter] then
    local src = M.adapter(adapter).from_param(param)
    return vim.schedule(function()
      if src then
        cb(nil, src)
      else
        cb("bad source id " .. id)
      end
    end)
  end
  if not config.options.devdocs.enabled then
    return vim.schedule(function()
      cb("unknown source '" .. id .. "'")
    end)
  end
  require("rtfm.adapters.devdocs").catalog(function(err, catalog)
    if err then
      return cb(err)
    end
    local src = find_devdocs(catalog, id)
    if not src then
      return cb("unknown source '" .. id .. "'")
    end
    cb(nil, src)
  end)
end

--- Synchronous lookup; only works for static/param sources or once the catalog is loaded.
function M.get_sync(id)
  local s = find_static(id)
  if s then
    return s
  end
  local adapter, param = id:match("^(%w+):(.+)$")
  if adapter and PARAM_ADAPTERS[adapter] then
    return M.adapter(adapter).from_param(param)
  end
  local catalog = require("rtfm.adapters.devdocs").catalog_cached()
  return catalog and find_devdocs(catalog, id) or nil
end

--- Ids for command completion.
function M.complete_ids()
  local ids = {}
  for _, s in ipairs(M.static()) do
    table.insert(ids, s.id)
  end
  local catalog = require("rtfm.adapters.devdocs").catalog_cached()
  if not catalog then
    local raw = require("rtfm.cache").get("devdocs/docs.json", -1)
    catalog = raw and util.json_decode(raw) or {}
  end
  for _, e in ipairs(catalog) do
    table.insert(ids, e.slug)
  end
  return ids
end

--- Guess an adapter for a URL a user wants to add.
function M.add_url(u, name, cb)
  local urllib = require("rtfm.url")
  local host = urllib.host(u)
  local id = name or host:gsub("^www%.", ""):gsub("^docs%.", ""):gsub("%..*$", "")
  local spec
  if u:match("sitemap[^/]*%.xml") then
    spec = { name = name or host, adapter = "sitemap", url = u, home = "https://" .. host }
    store.add_source(id, spec)
    return cb(nil, normalize(id, spec))
  end
  local p = urllib.parse(u)
  local root = (p.scheme or "https") .. "://" .. p.host
  local candidates = { root .. "/sitemap.xml", root .. "/sitemap_index.xml" }
  if p.path ~= "" and p.path ~= "/" then
    table.insert(candidates, 1, urllib.join(u:gsub("/?$", "/"), "sitemap.xml"))
  end
  local cache = require("rtfm.cache")
  local i = 0
  local function try_next()
    i = i + 1
    local c = candidates[i]
    if not c then
      return cb("no sitemap.xml found for " .. u .. " (add it with an explicit sitemap URL)")
    end
    cache.fetch(c, {
      ttl = 3600,
      validate = function(body)
        return body:find("<urlset", 1, true) ~= nil or body:find("<sitemapindex", 1, true) ~= nil
      end,
    }, function(err)
      if err then
        return try_next()
      end
      spec = { name = name or host, adapter = "sitemap", url = c, home = root }
      -- scope the sitemap to the given path prefix (e.g. https://site/docs/)
      if p.path ~= "" and p.path ~= "/" then
        spec.include = "^" .. vim.pesc(p.path:gsub("/$", ""))
      end
      store.add_source(id, spec)
      cb(nil, normalize(id, spec))
    end)
  end
  try_next()
end

return M
