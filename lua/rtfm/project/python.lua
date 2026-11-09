--- pyproject.toml / requirements / lockfiles / .python-version.
local M = {}

M.files = { "pyproject.toml", "requirements.txt", "requirements-dev.txt", ".python-version", "uv.lock", "poetry.lock", "runtime.txt" }

local function norm(name)
  return (name:lower():gsub("[-_.]+", "-"))
end
M.norm = norm

--- "requests>=2.31,<3" -> "requests", "2.31"
local function split_req(spec)
  spec = vim.trim((spec:gsub(";.*$", ""):gsub("%[.-%]", "")))
  local name, rest = spec:match("^([%w%-_.]+)%s*(.*)$")
  if not name then
    return nil
  end
  local version = rest:match("==%s*([%d][%w%.]*)") or rest:match("~=%s*([%d][%w%.]*)") or rest:match(">=%s*([%d][%w%.]*)")
  return name, version
end
M.split_req = split_req

function M.parse_lock(text)
  local out = {}
  for _, block in ipairs(require("rtfm.util").toml_blocks(text, "[[package]]")) do
    local name = block:match('\nname%s*=%s*"([^"]+)"')
    local version = block:match('\nversion%s*=%s*"([^"]+)"')
    if name and version then
      out[norm(name)] = version
    end
  end
  return out
end

function M.parse_pyproject(text)
  local deps, python = {}, nil
  -- PEP 621: dependencies = [ "a>=1", "b" ]
  local arr = text:match("\n%s*dependencies%s*=%s*(%b[])")
  if arr then
    for spec in arr:gmatch('"([^"]+)"') do
      local name, version = split_req(spec)
      if name then
        table.insert(deps, { name = name, version = version })
      end
    end
  end
  python = text:match('requires%-python%s*=%s*"[^"%d]*([%d%.]+)')
  -- poetry
  local poetry = text:match("%[tool%.poetry%.dependencies%](.-)\n%[") or text:match("%[tool%.poetry%.dependencies%](.*)$")
  if poetry then
    for line in poetry:gmatch("[^\n]+") do
      local name, rest = line:match("^%s*([%w%-_.]+)%s*=%s*(.+)$")
      if name then
        local v = rest:match("(%d+[%d%.]*)")
        if name == "python" then
          python = python or v
        else
          table.insert(deps, { name = name, version = v })
        end
      end
    end
  end
  return deps, python
end

function M.parse_requirements(text)
  local deps = {}
  for line in text:gmatch("[^\r\n]+") do
    line = vim.trim((line:gsub("#.*$", "")))
    if line ~= "" and not line:match("^%-") then
      local name, version = split_req(line)
      if name then
        table.insert(deps, { name = name, version = version })
      end
    end
  end
  return deps
end

function M.detect(root, read)
  local pyproject = read(root .. "/pyproject.toml")
  local reqs = read(root .. "/requirements.txt")
  local pyver_file = read(root .. "/.python-version")
  if not (pyproject or reqs or pyver_file) then
    return nil
  end
  local deps, python = {}, nil
  if pyproject then
    deps, python = M.parse_pyproject(pyproject)
  end
  if reqs then
    vim.list_extend(deps, M.parse_requirements(reqs))
  end
  local lock = read(root .. "/uv.lock") or read(root .. "/poetry.lock")
  local locked = lock and M.parse_lock(lock) or {}
  local out, seen = {}, {}
  for _, d in ipairs(deps) do
    local key = norm(d.name)
    if not seen[key] then
      seen[key] = true
      table.insert(out, { eco = "python", name = d.name, version = locked[key] or d.version, direct = true })
    end
  end
  if pyver_file and pyver_file:match("%d") then
    python = pyver_file:match("(%d+%.%d+[%d%.]*)") or python
  end
  local runtime = read(root .. "/runtime.txt")
  if not python and runtime then
    python = runtime:match("(%d+%.%d+[%d%.]*)")
  end
  return { lang = "python", lang_version = python, deps = out }
end

return M
