--- pkg.go.dev: Go stdlib + every public Go module, version-aware.
---
--- Source ids:
---   gopkg                         search all of pkg.go.dev (remote)
---   gopkg:std@go1.22.0            stdlib at a Go version (local list of packages)
---   gopkg:golang.org/x/sync@v0.10.0   a module at a version (local list of packages)
local cache = require("rtfm.cache")
local P = require("rtfm.html.parser")
local urllib = require("rtfm.url")
local web = require("rtfm.adapters.web")

local M = {}

M.BASE = "https://pkg.go.dev"
M.SELECTOR = ".Documentation-content"

function M.mode_for(source)
  return source.module and "local" or "remote"
end

--- Build a source for a module (or "std") at a version.
function M.versioned(module, version)
  local is_std = module == "std"
  local label = is_std and ("Go " .. version:gsub("^go", "")) or (module .. " " .. version)
  return {
    id = "gopkg:" .. module .. "@" .. version,
    name = label,
    adapter = "gopkg",
    module = module,
    version = version,
    lang = "go",
    home = M.BASE .. "/" .. module .. "@" .. version,
  }
end

function M.from_param(param)
  local module, version = param:match("^(.+)@(.+)$")
  if module then
    return M.versioned(module, version)
  end
end

--- Normalise "1.22" / "1.22.3" / "go1.22" -> "go1.22.0"/"go1.22.3"
function M.std_version(v)
  v = tostring(v):gsub("^go", "")
  local parts = vim.split(v, ".", { plain = true })
  if #parts == 2 then
    -- pkg.go.dev serves go1.21.0+ as x.y.0; older releases are x.y
    if tonumber(parts[1]) == 1 and (tonumber(parts[2]) or 0) < 21 then
      return "go" .. v
    end
    v = v .. ".0"
  end
  return "go" .. v
end

local function versioned_url(source, import_path)
  if source.version then
    if source.module == "std" then
      return ("%s/%s@%s"):format(M.BASE, import_path, source.version)
    end
    local sub = import_path:sub(#source.module + 2)
    return ("%s/%s@%s%s"):format(M.BASE, source.module, source.version, sub ~= "" and ("/" .. sub) or "")
  end
  return M.BASE .. "/" .. import_path
end
M.versioned_url = versioned_url

--- "/golang.org/x/sync@v0.10.0/errgroup" -> "golang.org/x/sync/errgroup"
local function import_path_of(href)
  local path = urllib.parse(href).path:gsub("^/", "")
  return (path:gsub("@[^/]+", ""))
end
M.import_path_of = import_path_of

-- remote search -------------------------------------------------------------------------

local function looks_like_symbol(q)
  return q:match("^[%a_][%w_]*%.[%a_][%w_%.]*$") ~= nil or q:match("^%u[%w_]*$") ~= nil
end

function M.parse_search(html)
  local root = P.parse(html)
  local items = {}
  for _, snip in ipairs(P.select(root, "div.SearchSnippet")) do
    local link = P.select_one(snip, "a[data-test-id=snippet-title]")
    if link and link.attrs.href then
      local kind_el = P.select_one(link, ".SearchSnippet-symbolKind")
      local kind = kind_el and P.clean_text(kind_el) or "package"
      if kind_el then
        P.remove(kind_el)
      end
      local title = P.clean_text(link)
      local href = link.attrs.href
      local pkg_links = P.select(snip, "h2 a")
      local container = pkg_links[2] and P.clean_text(pkg_links[2]) or nil
      local syn = P.select_one(snip, ".SearchSnippet-synopsis")
      local full = urllib.join(M.BASE .. "/", href)
      table.insert(items, {
        title = container and (container:match("([^/]+)$") .. "." .. title) or title,
        kind = container and (kind .. " · " .. container) or kind,
        detail = syn and P.clean_text(syn) or nil,
        url = full,
        fragment = urllib.fragment(full),
        import_path = import_path_of(href),
      })
    end
  end
  return items
end

function M.search(source, query, cb)
  local mode = looks_like_symbol(query) and "symbol" or "package"
  local q = query
  if source.module and source.module ~= "std" then
    q = q .. " " .. source.module
  end
  local u = ("%s/search?q=%s&m=%s"):format(M.BASE, urllib.encode(q), mode)
  return cache.fetch(u, { ttl = 24 * 3600 }, function(err, body)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_search(body))
  end)
end

-- versioned module: list packages ------------------------------------------------------

function M.parse_directories(html, source)
  local root = P.parse(html)
  local items, seen = {}, {}
  local dirs = P.select_one(root, ".UnitDirectories") or root
  for _, a in ipairs(P.select(dirs, "a[href]")) do
    local href = a.attrs.href
    if href:sub(1, 1) == "/" and not href:find("?", 1, true) and href:find("@", 1, true) then
      local ip = import_path_of(href)
      if not seen[ip] and not ip:find("/internal", 1, true) and ip ~= "std" then
        seen[ip] = true
        table.insert(items, {
          title = ip,
          kind = "package",
          import_path = ip,
          url = versioned_url(source, ip),
        })
      end
    end
  end
  -- the module's root package (if it has one) isn't listed in its own directory table
  if source.module ~= "std" and not seen[source.module] then
    table.insert(items, 1, { title = source.module, kind = "module", import_path = source.module, url = versioned_url(source, source.module) })
  end
  return items
end

function M.load(source, cb)
  local u = ("%s/%s@%s"):format(M.BASE, source.module, source.version)
  return cache.fetch(u, { ttl = -1 }, function(err, body)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_directories(body, source))
  end)
end

-- pages -------------------------------------------------------------------------------

function M.page_key(_, item)
  return urllib.strip_fragment(item.url)
end

function M.fetch(source, item, cb)
  local versioned = item.url:find("@", 1, true) ~= nil
  return web.fetch_url(item.url, {
    ttl = versioned and -1 or 24 * 3600,
    selector = M.SELECTOR,
    title = item.import_path or import_path_of(item.url),
  }, function(err, raw)
    if raw then
      raw.lang = "go"
    end
    cb(err, raw)
  end)
end

function M.resolve(source, u)
  local p = urllib.parse(u)
  if (p.host or ""):lower() ~= "pkg.go.dev" or p.path == "/" or p.path:match("^/search") then
    return nil
  end
  local ip = import_path_of(u)
  local target = u
  -- keep links inside a versioned source at that version
  if source.version and not p.path:find("@", 1, true) then
    local in_module = source.module == "std" and not ip:match("^[^/]*%.") or ip:sub(1, #source.module) == source.module
    if in_module then
      target = versioned_url(source, ip) .. (p.fragment and ("#" .. p.fragment) or "")
    end
  end
  return { item = { title = ip, import_path = ip, url = target, fragment = p.fragment } }
end

--- Symbols (functions, types, methods) on a package page, for offline search.
function M.symbols(raw, item)
  local root = P.parse(raw.html)
  local out = {}
  local content = P.select_one(root, M.SELECTOR) or root
  for _, h in ipairs(P.select(content, "h4[id]")) do
    local id = h.attrs.id
    if not id:match("^example") then
      local text = P.clean_text(h):gsub("%s*¶%s*$", "")
      local kind = text:match("^(%a+)") or "symbol"
      table.insert(out, {
        title = (item.import_path or ""):match("([^/]+)$") .. "." .. id,
        kind = kind,
        import_path = item.import_path,
        url = urllib.strip_fragment(item.url) .. "#" .. id,
        fragment = id,
      })
    end
  end
  return out
end

--- Offline install: every package page of the module version.
function M.pages(source, cb)
  M.load(source, cb)
end

return M
