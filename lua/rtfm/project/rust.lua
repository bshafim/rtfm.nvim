--- Cargo.toml / Cargo.lock parsing.
local M = {}

M.files = { "Cargo.toml", "Cargo.lock" }

--- Exact versions from Cargo.lock: { name = version } (first occurrence wins).
function M.parse_lock(text)
  local versions = {}
  for _, block in ipairs(require("rtfm.util").toml_blocks(text, "[[package]]")) do
    local name = block:match('\nname%s*=%s*"([^"]+)"')
    local version = block:match('\nversion%s*=%s*"([^"]+)"')
    if name and version and not versions[name] then
      versions[name] = version
    end
  end
  return versions
end

--- Direct deps from Cargo.toml: { {name, req} }
function M.parse_manifest(text)
  local deps, section = {}, nil
  local seen = {}
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = vim.trim((raw:gsub("#.*$", "")))
    local sec = line:match("^%[([^%]]+)%]$")
    if sec then
      section = sec
      -- [dependencies.serde] style
      local name = sec:match("dependencies%.([%w_-]+)$")
      if name and not seen[name] then
        seen[name] = true
        table.insert(deps, { name = name })
      end
    elseif section and section:match("dependencies$") then
      local name, rest = line:match("^([%w_-]+)%s*=%s*(.+)$")
      if name and not seen[name] then
        seen[name] = true
        local req = rest:match('^"([^"]+)"') or rest:match('version%s*=%s*"([^"]+)"')
        local pkg = rest:match('package%s*=%s*"([^"]+)"')
        table.insert(deps, { name = pkg or name, req = req })
      end
    elseif section and section:match("dependencies%.[%w_-]+$") then
      local req = line:match('^version%s*=%s*"([^"]+)"')
      if req then
        deps[#deps].req = req
      end
    end
  end
  return deps
end

local function clean_req(req)
  if not req then
    return nil
  end
  return req:match("(%d+[%d%.]*[%w%.%-+]*)")
end

function M.detect(root, read)
  local manifest = read(root .. "/Cargo.toml")
  if not manifest then
    return nil
  end
  local lock_path = vim.fs.find("Cargo.lock", { path = root, upward = true, limit = 1 })[1]
  local locked = lock_path and M.parse_lock(read(lock_path) or "") or {}
  local deps = {}
  for _, d in ipairs(M.parse_manifest(manifest)) do
    table.insert(deps, {
      eco = "rust",
      name = d.name,
      version = locked[d.name] or clean_req(d.req),
      direct = true,
    })
  end
  return { lang = "rust", deps = deps, locked = locked }
end

return M
