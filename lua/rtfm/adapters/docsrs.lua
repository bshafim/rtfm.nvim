--- docs.rs + crates.io: Rust crates, version-aware.
---
--- Source ids:
---   docsrs                  search crates.io (remote)
---   docsrs:serde@1.0.200    one crate at a version (local list of all items)
local cache = require("rtfm.cache")
local P = require("rtfm.html.parser")
local urllib = require("rtfm.url")
local web = require("rtfm.adapters.web")

local M = {}

M.BASE = "https://docs.rs"
M.SELECTOR = "#main-content"

function M.mode_for(source)
  return source.crate and "local" or "remote"
end

local function lib_name(crate)
  return (crate:gsub("-", "_"))
end

function M.versioned(crate, version)
  return {
    id = "docsrs:" .. crate .. "@" .. version,
    name = crate .. " " .. version,
    adapter = "docsrs",
    crate = crate,
    version = version,
    lang = "rust",
    home = ("%s/%s/%s/%s/"):format(M.BASE, crate, version, lib_name(crate)),
  }
end

function M.from_param(param)
  local crate, version = param:match("^([^@]+)@(.+)$")
  if crate then
    return M.versioned(crate, version)
  end
  return M.versioned(param, "latest")
end

function M.crate_root(crate, version)
  return ("%s/%s/%s/%s/"):format(M.BASE, crate, version or "latest", lib_name(crate))
end

-- crates.io search ----------------------------------------------------------------------

function M.parse_search(data)
  local items = {}
  for _, c in ipairs((data or {}).crates or {}) do
    table.insert(items, {
      title = c.name,
      kind = c.max_stable_version or c.max_version or c.newest_version,
      detail = c.description and vim.trim(c.description:gsub("%s+", " ")) or nil,
      url = M.crate_root(c.name, "latest"),
      crate = c.name,
    })
  end
  return items
end

function M.search(_, query, cb)
  local u = ("https://crates.io/api/v1/crates?q=%s&per_page=25"):format(urllib.encode(query))
  return cache.fetch_json(u, { ttl = 24 * 3600 }, function(err, data)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_search(data))
  end)
end

-- versioned crate: all items ------------------------------------------------------------

local KIND = {
  structs = "struct", enums = "enum", traits = "trait", macros = "macro", derives = "derive",
  functions = "fn", types = "type", constants = "const", statics = "static", unions = "union",
  ["attributes"] = "attr", ["trait-aliases"] = "trait alias", primitives = "primitive", modules = "mod",
}

function M.parse_all(html, source)
  local root = P.parse(html)
  local base = M.crate_root(source.crate, source.version)
  local items = { { title = lib_name(source.crate), kind = "crate", url = base } }
  local content = P.select_one(root, "#main-content") or root
  local kind = "item"
  local function walk(node)
    for _, c in ipairs(node.children or {}) do
      if c.type == "element" then
        if c.tag == "h3" and c.attrs.id then
          kind = KIND[c.attrs.id] or c.attrs.id
        elseif c.tag == "ul" and P.has_class(c, "all-items") then
          for _, a in ipairs(P.select(c, "a[href]")) do
            table.insert(items, { title = P.clean_text(a), kind = kind, url = urllib.join(base, a.attrs.href) })
          end
        else
          walk(c)
        end
      end
    end
  end
  walk(content)
  return items
end

function M.load(source, cb)
  local u = M.crate_root(source.crate, source.version) .. "all.html"
  return cache.fetch(u, { ttl = source.version == "latest" and 24 * 3600 or -1 }, function(err, body)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_all(body, source))
  end)
end

-- pages -------------------------------------------------------------------------------

function M.page_key(_, item)
  return urllib.strip_fragment(item.url)
end

function M.fetch(_, item, cb)
  local versioned = not item.url:find("/latest/", 1, true)
  return web.fetch_url(item.url, { ttl = versioned and -1 or 24 * 3600, selector = M.SELECTOR }, function(err, raw)
    if raw then
      raw.lang = "rust"
    end
    cb(err, raw)
  end)
end

function M.resolve(source, u)
  local p = urllib.parse(u)
  local host = (p.host or ""):lower()
  if host ~= "docs.rs" and host ~= "doc.rust-lang.org" then
    return nil
  end
  local name = p.path:match("([^/]+)%.html$") or p.path:match("([^/]+)/?$") or u
  name = name:gsub("^%a+%.", "")
  if host == "doc.rust-lang.org" then
    return { source_id = "web", item = { title = name, url = u, fragment = p.fragment } }
  end
  return { item = { title = name, url = u, fragment = p.fragment } }
end

function M.pages(source, cb)
  M.load(source, cb)
end

return M
