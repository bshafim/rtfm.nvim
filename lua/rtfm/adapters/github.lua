--- docs.github.com via its public search + article APIs (articles come back as Markdown).
local cache = require("rtfm.cache")
local urllib = require("rtfm.url")

local M = {}

M.mode = "remote"
M.BASE = "https://docs.github.com"
M.CLIENT = "rtfm.nvim"

local function strip_marks(s)
  return (s or ""):gsub("</?mark>", "")
end

function M.parse_search(data)
  local items = {}
  for _, h in ipairs((data or {}).hits or {}) do
    table.insert(items, {
      title = strip_marks(h.title),
      kind = h.breadcrumbs,
      path = h.url,
      url = M.BASE .. h.url,
    })
  end
  return items
end

function M.search(source, query, cb)
  local version = source.version or "free-pro-team@latest"
  local u = ("%s/api/search/v1?version=%s&language=en&size=25&query=%s&client_name=%s"):format(
    M.BASE,
    urllib.encode(version),
    urllib.encode(query),
    M.CLIENT
  )
  return cache.fetch_json(u, { ttl = 24 * 3600 }, function(err, data)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_search(data))
  end)
end

function M.page_key(_, item)
  return item.path or urllib.parse(item.url).path
end

function M.fetch(source, item, cb)
  local path = M.page_key(source, item)
  local u = ("%s/api/article/body?pathname=%s&client_name=%s"):format(M.BASE, urllib.encode(path), M.CLIENT)
  return cache.fetch(u, { ttl = 3 * 24 * 3600 }, function(err, body)
    if err then
      return cb(err)
    end
    cb(nil, { markdown = body, url = M.BASE .. path, base = M.BASE .. path, title = item.title })
  end)
end

function M.resolve(_, u)
  local p = urllib.parse(u)
  if (p.host or ""):lower() ~= "docs.github.com" then
    return nil
  end
  local path = p.path
  if not path:match("^/%a%a/") and not path:match("^/%a%a$") then
    path = "/en" .. path
  end
  return { item = { title = path:match("([^/]+)/?$"), path = path, url = M.BASE .. path, fragment = p.fragment } }
end

return M
