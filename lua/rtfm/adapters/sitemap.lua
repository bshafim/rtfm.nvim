--- Any docs site with a sitemap.xml. Titles are derived from URL paths; pages are extracted.
---
--- Source spec: { adapter = "sitemap", url = "https://site/sitemap.xml",
---                include = "^/docs/" (Lua pattern on the path, optional),
---                exclude = "/blog/",  selector = ".content" (optional) }
local cache = require("rtfm.cache")
local urllib = require("rtfm.url")
local util = require("rtfm.util")
local web = require("rtfm.adapters.web")

local M = {}

M.mode = "local"
M.MAX_CHILD_SITEMAPS = 25

local function locs(xml)
  local out = {}
  for loc in xml:gmatch("<loc>%s*(.-)%s*</loc>") do
    loc = loc:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("&amp;", "&")
    table.insert(out, loc)
  end
  return out
end

function M.item_for(u)
  local p = urllib.parse(u)
  local path = p.path:gsub("/index%.html?$", "/"):gsub("%.html?$", "")
  local segs = vim.split(path, "/", { trimempty = true })
  local last = segs[#segs] or p.host or u
  local parent = #segs > 1 and table.concat(segs, "/", 1, #segs - 1) or ""
  local title = util.humanize(urllib.decode(last))
  return {
    title = title,
    kind = parent ~= "" and parent or nil,
    url = u,
    search = title .. " " .. parent:gsub("[/_-]", " "),
  }
end

function M.parse(xml, source)
  local items = {}
  local seen = {}
  for _, u in ipairs(locs(xml)) do
    local path = urllib.parse(u).path or ""
    local ok = (not source.include or path:find(source.include))
      and (not source.exclude or not path:find(source.exclude))
    if ok and not seen[u] then
      seen[u] = true
      table.insert(items, M.item_for(u))
    end
  end
  table.sort(items, function(a, b)
    return a.url < b.url
  end)
  return items
end

local function is_index(xml)
  return xml:find("<sitemapindex", 1, true) ~= nil
end

function M.load(source, cb)
  local ttl = source.ttl or 24 * 3600
  cache.fetch(source.url, { ttl = ttl }, function(err, xml)
    if err then
      return cb(err)
    end
    if not is_index(xml) then
      return cb(nil, M.parse(xml, source))
    end
    local children = locs(xml)
    if #children > M.MAX_CHILD_SITEMAPS then
      children = vim.list_slice(children, 1, M.MAX_CHILD_SITEMAPS)
    end
    local parts = {}
    util.parallel(children, 4, function(child, done)
      cache.fetch(child, { ttl = ttl }, function(cerr, body)
        if not cerr and body and not is_index(body) then
          table.insert(parts, body)
        end
        done(cerr)
      end)
    end, nil, function()
      cb(nil, M.parse(table.concat(parts, "\n"), source))
    end)
  end)
end

function M.page_key(_, item)
  return urllib.strip_fragment(item.url)
end

function M.fetch(source, item, cb)
  return web.fetch_url(item.url, { ttl = source.page_ttl, selector = source.selector }, cb)
end

function M.resolve(source, u)
  local site = urllib.host(source.url)
  if urllib.host(u) ~= site then
    return nil
  end
  local item = M.item_for(urllib.strip_fragment(u))
  item.url = u
  item.fragment = urllib.fragment(u)
  return { item = item }
end

function M.pages(source, cb)
  M.load(source, cb)
end

return M
