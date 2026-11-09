--- go.mod parsing.
local M = {}

M.files = { "go.mod" }

--- Module paths in the module cache escape capitals: "!azure" -> "Azure".
function M.unescape(path)
  return (path:gsub("!(%l)", function(c)
    return c:upper()
  end))
end

---@return {lang_version?: string, deps: table[], module?: string}
function M.parse_gomod(text)
  local out = { deps = {} }
  local by_name = {}
  local function add(name, version, indirect)
    if by_name[name] then
      by_name[name].version = version
      return
    end
    local d = { eco = "go", name = name, version = version, direct = not indirect }
    by_name[name] = d
    table.insert(out.deps, d)
  end
  local in_require, in_replace = false, false
  local replaces = {}
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = raw:gsub("^%s+", "")
    local comment = line:match("//(.*)$") or ""
    local code = vim.trim((line:gsub("//.*$", "")))
    local indirect = comment:find("indirect", 1, true) ~= nil
    if code:match("^module%s") then
      out.module = code:match("^module%s+(%S+)")
    elseif code:match("^go%s+[%d.]+") then
      out.go = code:match("^go%s+([%d.]+)")
    elseif code:match("^toolchain%s") then
      out.toolchain = code:match("^toolchain%s+go([%d.]+)")
    elseif code:match("^require%s*%($") then
      in_require = true
    elseif code:match("^replace%s*%($") then
      in_replace = true
    elseif code == ")" then
      in_require, in_replace = false, false
    elseif code:match("^require%s") then
      local name, version = code:match("^require%s+(%S+)%s+(%S+)")
      if name then
        add(name, version, indirect)
      end
    elseif code:match("^replace%s") or in_replace then
      local spec = code:gsub("^replace%s+", "")
      local from, to, tover = spec:match("^(%S+)[^=]*=>%s*(%S+)%s*(%S*)")
      if from and tover ~= "" then
        replaces[from] = { name = to, version = tover }
      end
    elseif in_require then
      local name, version = code:match("^(%S+)%s+(%S+)")
      if name then
        add(name, version, indirect)
      end
    end
  end
  for _, d in ipairs(out.deps) do
    local r = replaces[d.name]
    if r then
      d.docs_name, d.version = r.name, r.version
    end
  end
  out.lang_version = out.toolchain or out.go
  return out
end

function M.detect(root, read)
  local text = read(root .. "/go.mod")
  if not text then
    return nil
  end
  local res = M.parse_gomod(text)
  res.lang = "go"
  return res
end

return M
