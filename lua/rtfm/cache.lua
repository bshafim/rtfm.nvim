--- On-disk HTTP cache. Serves stale entries when the network fails or offline mode is on.
local util = require("rtfm.util")
local http = require("rtfm.http")

local M = {}

function M.path_for(key)
  local safe = key:gsub("^https?://", ""):gsub("[^%w%._~-]", "_")
  if #safe > 100 then
    safe = safe:sub(1, 60) .. "-" .. vim.fn.sha256(key):sub(1, 16)
  end
  return util.cache_dir("http") .. "/" .. safe
end

---@return string|nil content, boolean fresh
function M.get(key, ttl)
  local path = M.path_for(key)
  local mtime = util.mtime(path)
  if not mtime then
    return nil, false
  end
  local fresh = ttl == nil or ttl < 0 or (os.time() - mtime) < ttl
  return util.read_file(path), fresh
end

function M.set(key, data)
  util.write_file(M.path_for(key), data)
end

function M.delete(key)
  os.remove(M.path_for(key))
end

---@class rtfm.CacheOpts
---@field key? string
---@field ttl? number seconds; negative = never expires
---@field refresh? boolean
---@field request? table extra http request fields
---@field validate? fun(body: string): boolean

--- Fetch `url`, served from the cache when fresh. Falls back to a stale copy on failure.
---@param cb fun(err: string|nil, body: string|nil, from_cache: boolean|nil)
function M.fetch(url, opts, cb)
  opts = opts or {}
  local key = opts.key or url
  local ttl = opts.ttl or require("rtfm.config").options.cache.ttl
  local cached, fresh = M.get(key, ttl)
  if cached and (fresh or require("rtfm.config").options.offline) and not opts.refresh then
    vim.schedule(function()
      cb(nil, cached, true)
    end)
    return { cancel = function() end }
  end
  local req = vim.tbl_extend("force", { url = url }, opts.request or {})
  return http.request(req, function(err, res)
    if not err and opts.validate and not opts.validate(res.body) then
      err = "unexpected response from " .. url
    end
    if err then
      if cached then
        return cb(nil, cached, true)
      end
      return cb(err)
    end
    M.set(key, res.body)
    cb(nil, res.body, false)
  end)
end

function M.fetch_json(url, opts, cb)
  opts = opts or {}
  return M.fetch(url, opts, function(err, body, from_cache)
    if err then
      return cb(err)
    end
    local data, jerr = util.json_decode(body)
    if jerr then
      if not from_cache then
        M.delete(opts.key or url)
      end
      return cb(jerr .. " (" .. url .. ")")
    end
    cb(nil, data)
  end)
end

function M.clear()
  vim.fn.delete(util.cache_dir("http"), "rf")
end

return M
