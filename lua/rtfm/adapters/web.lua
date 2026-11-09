--- Generic web pages: fetch any URL and extract its main content.
--- Also the shared helper the HTML-based adapters build on.
local cache = require("rtfm.cache")
local urllib = require("rtfm.url")
local util = require("rtfm.util")

local M = {}

M.mode = "remote"

--- Fetch an HTML page through the cache.
---@param opts? {ttl?: number, selector?: string, title?: string}
function M.fetch_url(u, opts, cb)
  opts = opts or {}
  local page = urllib.strip_fragment(u)
  return cache.fetch(page, { ttl = opts.ttl }, function(err, body)
    if err then
      return cb(err)
    end
    cb(nil, { html = body, url = page, base = page, selector = opts.selector, title = opts.title })
  end)
end

function M.page_key(_, item)
  return urllib.strip_fragment(item.url)
end

function M.search(_, query, cb)
  -- the "web" source has no search; a URL typed in the prompt is offered as a result
  vim.schedule(function()
    query = vim.trim(query)
    if urllib.is_http(query) then
      cb(nil, { { title = query, url = query, kind = "url" } })
    else
      cb(nil, {})
    end
  end)
end

function M.fetch(source, item, cb)
  return M.fetch_url(item.url, { ttl = source.ttl, selector = source.selector }, cb)
end

function M.resolve(_, u)
  if urllib.is_http(u) then
    return { item = { url = u, title = util.humanize(urllib.parse(u).path:match("([^/]+)/?$") or u), fragment = urllib.fragment(u) } }
  end
end

return M
