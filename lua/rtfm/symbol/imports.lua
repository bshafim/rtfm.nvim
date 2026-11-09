--- Resolve `alias.Name` under the cursor using the buffer's imports (no LSP needed).
local M = {}

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- Go ----------------------------------------------------------------------------------------

local function go_default_alias(path)
  local last = path:match("([^/]+)$") or path
  if last:match("^v%d+$") then
    last = path:match("([^/]+)/v%d+$") or last
  end
  last = last:gsub("%.v%d+$", ""):gsub("^go%-", ""):gsub("%-go$", ""):gsub("[%-.]", "_")
  return last
end
M.go_default_alias = go_default_alias

function M.go_imports(text)
  local out = {}
  local function add(alias, path)
    if alias == "_" or alias == "." then
      return
    end
    out[alias or go_default_alias(path)] = path
  end
  for block in text:gmatch("import%s*(%b())") do
    for line in block:gmatch("[^\n]+") do
      local alias, path = line:match('^%s*([%w_%.]+)%s+"([^"]+)"')
      if not path then
        path = line:match('^%s*"([^"]+)"')
      end
      if path then
        add(alias, path)
      end
    end
  end
  for alias, path in text:gmatch('\nimport%s+([%w_]*)%s*"([^"]+)"') do
    add(alias ~= "" and alias or nil, path)
  end
  return out
end

function M.go(buf, expr, project)
  local alias, rest = expr:match("^([%w_]+)%.([%w_%.]+)$")
  if not alias then
    return nil
  end
  local path = M.go_imports(buf_text(buf))[alias]
  if not path then
    return nil
  end
  local gopkg = require("rtfm.adapters.gopkg")
  local source
  if path:match("^[^/]*%.") then
    local dep = project and require("rtfm.project").go_module_for(project, path)
    if dep then
      source = gopkg.versioned(dep.docs_name or dep.name, dep.version)
    else
      source = { id = "gopkg", adapter = "gopkg", name = "Go packages" }
    end
  else
    local v = project and project.langs.go
    source = v and gopkg.versioned("std", gopkg.std_version(v)) or { id = "gopkg", adapter = "gopkg", name = "Go packages" }
  end
  local url = source.version and gopkg.versioned_url(source, path) or (gopkg.BASE .. "/" .. path)
  return {
    source = source,
    item = { title = alias .. "." .. rest, import_path = path, url = url .. "#" .. rest, fragment = rest },
  }
end

-- Python ------------------------------------------------------------------------------------

function M.python_imports(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local mod, alias = line:match("^%s*import%s+([%w_.]+)%s+as%s+([%w_]+)")
    if mod then
      out[alias] = mod
    else
      local mods = line:match("^%s*import%s+([%w_., ]+)$")
      if mods then
        for m in mods:gmatch("[%w_.]+") do
          out[m:match("^([^.]+)")] = out[m:match("^([^.]+)")] or m:match("^([^.]+)")
          out[m] = m
        end
      end
      local from, names = line:match("^%s*from%s+([%w_.]+)%s+import%s+(.+)$")
      if from then
        names = names:gsub("[()]", "")
        for spec in names:gmatch("[^,]+") do
          local n, a = spec:match("^%s*([%w_]+)%s+as%s+([%w_]+)")
          if not n then
            n = spec:match("^%s*([%w_]+)")
          end
          if n then
            out[a or n] = from .. "." .. n
          end
        end
      end
    end
  end
  return out
end

function M.python(buf, expr)
  local imports = M.python_imports(buf_text(buf))
  local head, rest = expr:match("^([%w_]+)(.*)$")
  local full = head and imports[head]
  if not full then
    return nil
  end
  return { module = full:match("^([^.]+)"), qualified = full .. rest }
end

-- Rust --------------------------------------------------------------------------------------

function M.rust_uses(text)
  local out = {}
  local function split_as(item)
    local path, alias = item:match("^(.-)@as@([%w_]+)$")
    return path or item, alias
  end
  for body in text:gmatch("use%s+([^;]+);") do
    body = body:gsub("%s+as%s+", "@as@"):gsub("%s+", "")
    local prefix, group = body:match("^(.-)::(%b{})$")
    if prefix then
      for item in group:sub(2, -2):gmatch("[^,]+") do
        local path, alias = split_as(item)
        local name = alias or path:match("([%w_]+)$")
        if name and name ~= "self" then
          out[name] = prefix .. "::" .. path
        end
      end
    else
      local path, alias = split_as(body)
      local name = alias or path:match("([%w_]+)$")
      if name then
        out[name] = path
      end
    end
  end
  return out
end

function M.rust(buf, expr)
  local head = expr:match("^([%w_]+)")
  local uses = M.rust_uses(buf_text(buf))
  local full = head and uses[head]
  if not full then
    return nil
  end
  local rest = expr:sub(#head + 1)
  return { crate = full:match("^([%w_]+)"), path = full .. rest, name = (full .. rest):match("([%w_]+)$") }
end

-- JS / TS -----------------------------------------------------------------------------------

function M.js_imports(text)
  local out = {}
  for clause, pkg in text:gmatch("import%s+(.-)%s+from%s+['\"]([^'\"]+)['\"]") do
    for name in clause:gmatch("[%w_$]+") do
      if name ~= "as" and name ~= "type" then
        out[name] = pkg
      end
    end
  end
  for name, pkg in text:gmatch("([%w_$]+)%s*=%s*require%(['\"]([^'\"]+)['\"]%)") do
    out[name] = pkg
  end
  return out
end

function M.js(buf, expr)
  local head = expr:match("^([%w_$]+)")
  local pkg = head and M.js_imports(buf_text(buf))[head]
  if not pkg or pkg:match("^%.") then
    return nil
  end
  return { package = pkg:match("^(@[^/]+/[^/]+)") or pkg:match("^([^/]+)"), name = expr:match("([%w_$]+)$") }
end

return M
