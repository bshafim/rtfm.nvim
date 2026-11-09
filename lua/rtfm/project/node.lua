--- package.json + lockfiles (npm, pnpm, yarn).
local util = require("rtfm.util")

local M = {}

M.files = { "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", ".nvmrc", ".node-version" }

local function clean(range)
  if type(range) ~= "string" then
    return nil
  end
  return range:match("(%d+[%d%.]*)")
end
M.clean = clean

function M.parse_npm_lock(text)
  local data = util.json_decode(text)
  local out = {}
  if not data then
    return out
  end
  for path, info in pairs(data.packages or {}) do
    local name = path:match("^node_modules/(.+)$")
    if name and not name:find("/node_modules/", 1, true) and info.version then
      out[name] = info.version
    end
  end
  for name, info in pairs(data.dependencies or {}) do
    if not out[name] and type(info) == "table" and info.version then
      out[name] = info.version
    end
  end
  return out
end

function M.version_from_pnpm(text, name)
  local esc = vim.pesc(name)
  -- importers: '  react:\n    specifier: ^18\n    version: 18.2.0(...)'
  local v = text:match("\n%s+'?" .. esc .. "'?:%s*\n%s+specifier:[^\n]*\n%s+version:%s*'?(%d[%w%.%-]*)")
  if v then
    return v
  end
  return text:match("\n%s+'?/?" .. esc .. "@(%d[%w%.%-]*)")
end

function M.version_from_yarn(text, name)
  local esc = vim.pesc(name)
  for header, body in text:gmatch('\n("?[^\n]-)"?:\n(.-)\n\n') do
    if header:find('^"?' .. esc .. "@") or header:find(', "?' .. esc .. "@") then
      local v = body:match('version:?%s+"?([%d][%w%.%-]*)')
      if v then
        return v
      end
    end
  end
end

function M.detect(root, read)
  local pkg_text = read(root .. "/package.json")
  if not pkg_text then
    return nil
  end
  local pkg = util.json_decode(pkg_text) or {}
  local npm_lock = read(root .. "/package-lock.json")
  local locked = npm_lock and M.parse_npm_lock(npm_lock) or {}
  local pnpm = read(root .. "/pnpm-lock.yaml")
  local yarn = read(root .. "/yarn.lock")

  local deps, seen = {}, {}
  for _, field in ipairs({ "dependencies", "devDependencies", "peerDependencies" }) do
    local names = vim.tbl_keys(pkg[field] or {})
    table.sort(names)
    for _, name in ipairs(names) do
      if not seen[name] then
        seen[name] = true
        local range = pkg[field][name]
        local version = locked[name]
          or (pnpm and M.version_from_pnpm(pnpm, name))
          or (yarn and M.version_from_yarn(yarn, name))
          or clean(range)
        table.insert(deps, { eco = "node", name = name, version = version, direct = true, dev = field ~= "dependencies" })
      end
    end
  end

  local node_version = vim.trim(read(root .. "/.nvmrc") or read(root .. "/.node-version") or "")
  if node_version == "" or not node_version:match("%d") then
    node_version = pkg.engines and clean(pkg.engines.node) or nil
  else
    node_version = clean(node_version)
  end
  return { lang = "node", lang_version = node_version, deps = deps, name = pkg.name }
end

return M
