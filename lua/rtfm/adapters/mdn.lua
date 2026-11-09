--- MDN Web Docs via its public search API.
local cache = require("rtfm.cache")
local urllib = require("rtfm.url")
local web = require("rtfm.adapters.web")

local M = {}

M.mode = "remote"
M.BASE = "https://developer.mozilla.org"

local function kind_of(mdn_url)
  -- "/en-US/docs/Web/API/Fetch_API" -> "Web/API"
  local rest = mdn_url:match("/docs/(.+)$") or ""
  local parts = vim.split(rest, "/", { plain = true })
  return table.concat(parts, "/", 1, math.min(2, math.max(#parts - 1, 1)))
end

function M.parse_search(data)
  local items = {}
  for _, d in ipairs((data or {}).documents or {}) do
    table.insert(items, {
      title = d.title,
      kind = kind_of(d.mdn_url),
      detail = d.summary,
      url = M.BASE .. d.mdn_url,
    })
  end
  return items
end

function M.search(source, query, cb)
  local u = ("%s/api/v1/search?q=%s&size=25&locale=%s"):format(M.BASE, urllib.encode(query), source.locale or "en-US")
  return cache.fetch_json(u, { ttl = 24 * 3600 }, function(err, data)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_search(data))
  end)
end

function M.page_key(_, item)
  return urllib.strip_fragment(item.url)
end

function M.fetch(_, item, cb)
  return web.fetch_url(item.url, { ttl = 7 * 24 * 3600, selector = "article.main-page-content" }, cb)
end

function M.resolve(_, u)
  local p = urllib.parse(u)
  if (p.host or ""):lower() ~= "developer.mozilla.org" or not p.path:find("/docs/", 1, true) then
    return nil
  end
  return { item = { title = (p.path:match("([^/]+)$") or u):gsub("_", " "), url = u, fragment = p.fragment } }
end

return M
