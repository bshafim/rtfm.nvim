--- Async HTTP over curl + vim.system. Callbacks always run on the main loop.
local config = require("rtfm.config")

local M = {}

local STATUS_MARK = "\n__RTFM_HTTP_STATUS__:"

M.OFFLINE_ERR = "offline mode: network disabled"

---@class rtfm.HttpRequest
---@field url string
---@field method? string
---@field headers? table<string,string>
---@field body? string
---@field timeout? number seconds
---@field output? string write the body to this file instead of returning it
---@field force? boolean ignore offline mode (used for localhost embedding servers)

---@param req rtfm.HttpRequest
---@param cb fun(err: string|nil, res: {status: integer, body: string}|nil)
---@return {cancel: fun()}
function M.request(req, cb)
  local opts = config.options
  if opts.offline and not req.force then
    vim.schedule(function()
      cb(M.OFFLINE_ERR)
    end)
    return { cancel = function() end }
  end
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--location",
    "--compressed",
    "--max-time",
    tostring(req.timeout or opts.http.timeout),
    "--user-agent",
    opts.http.user_agent,
    "--write-out",
    STATUS_MARK .. "%{http_code}",
  }
  if req.method and req.method ~= "GET" then
    vim.list_extend(cmd, { "--request", req.method })
  end
  for k, v in pairs(req.headers or {}) do
    vim.list_extend(cmd, { "--header", k .. ": " .. v })
  end
  if req.body then
    vim.list_extend(cmd, { "--data-binary", "@-" })
  end
  if req.output then
    vim.fn.mkdir(vim.fn.fnamemodify(req.output, ":h"), "p")
    vim.list_extend(cmd, { "--output", req.output })
  end
  table.insert(cmd, req.url)

  local cancelled = false
  local ok, proc = pcall(vim.system, cmd, { text = true, stdin = req.body }, function(out)
    vim.schedule(function()
      if cancelled then
        return
      end
      if out.code ~= 0 then
        local msg = vim.trim(out.stderr or "")
        if msg == "" then
          msg = "curl exited with code " .. out.code
        end
        return cb(msg .. " (" .. req.url .. ")")
      end
      local stdout = out.stdout or ""
      local idx = stdout:find(STATUS_MARK, 1, true)
      local status, body = 0, stdout
      if idx then
        status = tonumber(stdout:sub(idx + #STATUS_MARK)) or 0
        body = stdout:sub(1, idx - 1)
      end
      if status >= 400 then
        return cb(("HTTP %d for %s"):format(status, req.url), { status = status, body = body })
      end
      cb(nil, { status = status, body = body })
    end)
  end)

  if not ok then
    vim.schedule(function()
      cb("failed to run curl: " .. tostring(proc))
    end)
    return { cancel = function() end }
  end

  return {
    cancel = function()
      cancelled = true
      pcall(proc.kill, proc, 15)
    end,
  }
end

function M.get(url, cb, opts)
  return M.request(vim.tbl_extend("force", { url = url }, opts or {}), cb)
end

function M.get_json(url, cb, opts)
  return M.get(url, function(err, res)
    if err then
      return cb(err)
    end
    local data, jerr = require("rtfm.util").json_decode(res.body)
    if jerr then
      return cb(jerr .. " (" .. url .. ")")
    end
    cb(nil, data)
  end, opts)
end

function M.post_json(url, payload, cb, opts)
  opts = opts or {}
  local headers = vim.tbl_extend("force", { ["Content-Type"] = "application/json" }, opts.headers or {})
  return M.request({
    url = url,
    method = "POST",
    headers = headers,
    body = vim.json.encode(payload),
    timeout = opts.timeout,
    force = opts.force,
  }, function(err, res)
    if err then
      return cb(err)
    end
    local data, jerr = require("rtfm.util").json_decode(res.body)
    if jerr then
      return cb(jerr)
    end
    cb(nil, data)
  end)
end

return M
