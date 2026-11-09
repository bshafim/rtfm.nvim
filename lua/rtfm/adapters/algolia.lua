--- Sites using Algolia DocSearch. Credentials are supplied by the user in their config:
---
---   sources = {
---     mydocs = {
---       adapter = "algolia", name = "My Docs",
---       app_id = "...", api_key = "...", index = "...",
---       params = { facetFilters = { "language:en" } }, -- optional, merged into the query
---     },
---   }
local http = require("rtfm.http")
local urllib = require("rtfm.url")
local web = require("rtfm.adapters.web")

local M = {}

M.mode = "remote"

local LEVELS = { "lvl0", "lvl1", "lvl2", "lvl3", "lvl4", "lvl5", "lvl6" }

local function strip_html(s)
  if type(s) ~= "string" then
    return nil
  end
  return (s:gsub("<[^>]+>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'))
end

function M.parse_hits(data)
  local items, seen = {}, {}
  for _, h in ipairs((data or {}).hits or {}) do
    local hier = h.hierarchy or {}
    local path = {}
    for _, lvl in ipairs(LEVELS) do
      local v = strip_html(hier[lvl])
      if v and v ~= "" then
        table.insert(path, v)
      end
    end
    local u = h.url
    if u and not seen[u] then
      seen[u] = true
      local title = path[#path] or u
      table.insert(items, {
        title = title,
        kind = #path > 1 and table.concat(path, " › ", 1, #path - 1) or nil,
        detail = strip_html(type(h.content) == "string" and h.content or nil),
        url = u,
        fragment = urllib.fragment(u),
      })
    end
  end
  return items
end

function M.search(source, query, cb)
  if not (source.app_id and source.api_key and source.index) then
    vim.schedule(function()
      cb("algolia source '" .. source.id .. "' needs app_id, api_key and index in your config")
    end)
    return { cancel = function() end }
  end
  local endpoint = ("https://%s-dsn.algolia.net/1/indexes/%s/query"):format(source.app_id, urllib.encode(source.index))
  local payload = vim.tbl_extend("force", { query = query, hitsPerPage = 25 }, source.params or {})
  return http.post_json(endpoint, payload, function(err, data)
    if err then
      return cb(err)
    end
    cb(nil, M.parse_hits(data))
  end, {
    headers = {
      ["X-Algolia-Application-Id"] = source.app_id,
      ["X-Algolia-API-Key"] = source.api_key,
    },
  })
end

function M.page_key(_, item)
  return urllib.strip_fragment(item.url)
end

function M.fetch(source, item, cb)
  return web.fetch_url(item.url, { ttl = source.page_ttl, selector = source.selector }, cb)
end

function M.resolve(source, u)
  if source.site and urllib.host(u) ~= urllib.host(source.site) then
    return nil
  end
  return { item = { title = (urllib.parse(u).path:match("([^/]+)/?$") or u), url = u, fragment = urllib.fragment(u) } }
end

return M
