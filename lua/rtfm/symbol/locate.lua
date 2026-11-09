--- Map a definition location (file path + line) to a doc target.
---
--- A target is either
---   { source = <source table>, item = <item> }            open directly
---   { source = <source table>, query = "json.dumps", exact = {...} }   look up in the source's index
local util = require("rtfm.util")

local M = {}

local function read_lines(path, upto)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, upto, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", upto)
  return ok and lines or {}
end
M.read_lines = read_lines

local function indent(line)
  return #(line:match("^(%s*)") or "")
end

-- Go ----------------------------------------------------------------------------------------

--- Anchor for a Go declaration at `lnum` (1-based) in `lines`, falling back to `ident`.
function M.go_anchor(lines, lnum, ident)
  local line = lines[lnum] or ""
  local recv, name = line:match("^func%s*%(%s*[%w_]*%s*%*?([%w_]+)[^%)]*%)%s*([%w_]+)")
  if recv then
    return recv .. "." .. name
  end
  name = line:match("^func%s+([%w_]+)") or line:match("^type%s+([%w_]+)")
  if name then
    return name
  end
  -- inside a struct/interface: Type.Field
  if indent(line) > 0 then
    local field = line:match("^%s+([%w_]+)")
    for i = lnum - 1, 1, -1 do
      local l = lines[i]
      local t = l:match("^type%s+([%w_]+)%s+[%w_]*%s*struct") or l:match("^type%s+([%w_]+)%s+interface")
        or l:match("^type%s+([%w_]+).*{%s*$")
      if t then
        return t .. "." .. (field or ident)
      end
      if l:match("^[%w}]") and not l:match("^}") then
        break
      end
      -- type ( ... ) groups: "\tName struct {"
      local gt = l:match("^%s+([%w_]+)%s+struct%s*{") or l:match("^%s+([%w_]+)%s+interface%s*{")
      if gt and indent(l) < indent(line) then
        return gt .. "." .. (field or ident)
      end
    end
    return field or ident
  end
  return ident
end

local goroot_version_cache = {}

--- If `path` lives in a GOROOT, return (version, import_path).
function M.go_std(path)
  local ver, pkgdir = path:match("/golang%.org/toolchain@v[^/]*%-go([%d%.]+)%.[^/]*/src/(.+)/[^/]+%.go$")
  if ver then
    return "go" .. ver, pkgdir
  end
  if path:find("/pkg/mod/", 1, true) then
    return nil
  end
  -- walk up looking for <root>/VERSION + <root>/src
  local s = 1
  while true do
    local i = path:find("/src/", s, true)
    if not i then
      return nil
    end
    local root = path:sub(1, i - 1)
    local cached = goroot_version_cache[root]
    if cached == nil then
      local v = util.read_file(root .. "/VERSION")
      cached = v and v:match("^(go[%d%.]+)") or false
      goroot_version_cache[root] = cached
    end
    if cached then
      local pkgdir = path:sub(i + 5):match("^(.+)/[^/]+%.go$")
      return cached, pkgdir
    end
    s = i + 1
  end
end

function M.go(path, lnum, ident, project)
  local gopkg = require("rtfm.adapters.gopkg")
  local lines = read_lines(path, lnum + 1)
  local anchor = M.go_anchor(lines, lnum, ident)
  local source, import_path
  local std_ver, std_pkg = M.go_std(path)
  if std_ver then
    source, import_path = gopkg.versioned("std", gopkg.std_version(std_ver)), std_pkg
  else
    local mod, ver, sub = path:match("/pkg/mod/(.+)@(v[^/]+)/(.*)$")
    if mod then
      mod = require("rtfm.project.go").unescape(mod)
      sub = sub:match("^(.*)/[^/]+%.go$") or ""
      source, import_path = gopkg.versioned(mod, ver), mod .. (sub ~= "" and ("/" .. sub) or "")
    else
      local vendored = path:match("/vendor/(.+)/[^/]+%.go$")
      if vendored and project then
        local dep = require("rtfm.project").go_module_for(project, vendored)
        if dep then
          source, import_path = gopkg.versioned(dep.name, dep.version), vendored
        end
      end
    end
  end
  if not source then
    return nil
  end
  local pkg = import_path:match("([^/]+)$")
  return {
    source = source,
    item = {
      title = pkg .. "." .. anchor,
      import_path = import_path,
      url = gopkg.versioned_url(source, import_path) .. "#" .. anchor,
      fragment = anchor,
    },
  }
end

-- Python ------------------------------------------------------------------------------------

function M.python_name(lines, lnum, ident)
  local line = lines[lnum] or ""
  local name = line:match("^%s*def%s+([%w_]+)") or line:match("^%s*async%s+def%s+([%w_]+)")
    or line:match("^%s*class%s+([%w_]+)") or line:match("^%s*([%w_]+)%s*[:=]") or ident
  local ind = indent(line)
  local chain = { name }
  for i = lnum - 1, 1, -1 do
    local l = lines[i]
    if l:match("%S") and indent(l) < ind then
      local cls = l:match("^%s*class%s+([%w_]+)")
      if cls then
        table.insert(chain, 1, cls)
        ind = indent(l)
      elseif l:match("^%s*def%s") or l:match("^%s*async%s+def%s") then
        return nil -- nested function: not documented
      end
      if ind == 0 then
        break
      end
    end
  end
  return table.concat(chain, ".")
end

local function dist_version(site, pkg)
  local pattern = site .. "/" .. pkg:gsub("-", "_") .. "-*.dist-info"
  local found = vim.fn.glob(pattern, false, true)
  if #found == 0 then
    found = vim.fn.glob(site .. "/" .. pkg .. "-*.dist-info", false, true)
  end
  local v = found[1] and found[1]:match("%-([%d][%w%.]*)%.dist%-info$")
  return v
end

local function module_of(rel)
  rel = rel:gsub("%.pyi?$", ""):gsub("/__init__$", "")
  return (rel:gsub("/", "."))
end

function M.python(path, lnum, ident, project, cb)
  local proj = require("rtfm.project")
  local lines = read_lines(path, lnum + 1)
  local name = M.python_name(lines, lnum, ident)
  if not name then
    return cb(nil)
  end
  local site, rel = path:match("^(.*/site%-packages)/(.+)$")
  local base, version, module
  if site then
    module = module_of(rel)
    local top = module:match("^([^.]+)")
    base = top
    version = dist_version(site, top)
  else
    local pyver, srel = path:match("/lib/python(%d+%.%d+)/(.+)$")
    if not pyver then
      srel = path:match("/typeshed/stdlib/(.+)$") or path:match("/stdlib/(.+%.pyi)$")
      pyver = project and project.langs.python
    end
    if not srel then
      return cb(nil)
    end
    module = module_of(srel)
    base, version = "python", pyver
  end
  local qualified = module .. "." .. name
  if base ~= "python" then
    local mapped = (proj.DEVDOCS_ALIASES.python or {})[base]
    if mapped == false then
      return cb(nil)
    end
    base = mapped or base
  end
  require("rtfm.adapters.devdocs").catalog(function(err, catalog)
    if err then
      return cb(nil)
    end
    local e = proj.pick_devdocs(catalog, base, version)
    if not e then
      return cb(nil)
    end
    local source = require("rtfm.adapters.devdocs").source_from_entry(e)
    cb({ source = source, query = qualified, exact = { qualified, qualified .. "()" } })
  end)
end

-- Rust --------------------------------------------------------------------------------------

local RUST_KINDS = { "fn", "struct", "enum", "trait", "type", "const", "static", "union", "mod" }

function M.rust_item(lines, lnum, ident)
  local line = lines[lnum] or ""
  local name, kind = line:match("macro_rules!%s*([%w_]+)"), "macro"
  if not name then
    for _, k in ipairs(RUST_KINDS) do
      name = line:match("%f[%w]" .. k .. "%s+([%w_]+)")
      if name then
        kind = k
        break
      end
    end
  end
  name = name or ident
  local owner, owner_kind
  if kind == "fn" and indent(line) > 0 then
    for i = lnum - 1, 1, -1 do
      local l = lines[i]
      if indent(l) < indent(line) and l:match("%S") then
        local t = l:match("^%s*impl[^{]-%sfor%s+([%w_]+)") or l:match("^%s*impl%s*<.->%s*([%w_]+)") or l:match("^%s*impl%s+([%w_]+)")
        if t then
          owner, owner_kind = t, "impl"
        else
          local tr = l:match("^%s*pub%s+trait%s+([%w_]+)") or l:match("^%s*trait%s+([%w_]+)")
          if tr then
            owner, owner_kind = tr, "trait"
          end
        end
        break
      end
    end
  end
  return { name = name, kind = kind, owner = owner, owner_kind = owner_kind, has_body = line:find("{", 1, true) ~= nil }
end

function M.rust(path, lnum, ident)
  local lines = read_lines(path, lnum + 1)
  local info = M.rust_item(lines, lnum, ident)
  local crate, version, rel = path:match("/registry/src/[^/]+/([%w_-]+)%-(%d[%w%.%-+]*)/(.*)$")
  local query = info.owner or info.name
  local fragment
  if info.owner then
    fragment = (info.owner_kind == "trait" and not info.has_body and "tymethod." or "method.") .. info.name
  end
  if crate then
    local docsrs = require("rtfm.adapters.docsrs")
    local module = rel:gsub("^src/", ""):gsub("%.rs$", ""):gsub("/mod$", ""):gsub("^lib$", ""):gsub("^main$", "")
    return {
      source = docsrs.versioned(crate, version),
      query = query,
      module = module:gsub("/", "::"),
      fragment = fragment,
      match_last = true,
    }
  end
  local std = path:match("/rustlib/src/rust/library/(%w+)/src/")
  if std then
    local src = require("rtfm.sources").get_sync("rust")
    if src then
      return { source = src, query = query, fragment = fragment, match_last = true }
    end
  end
end

-- JS / TS -----------------------------------------------------------------------------------

function M.node(path, ident, project, cb)
  local proj = require("rtfm.project")
  local pkg = path:match("/node_modules/(@[^/]+/[^/]+)/") or path:match("/node_modules/([^/]+)/")
  local base, version
  if pkg == "typescript" and path:match("/lib/lib%.dom") then
    base = "dom"
  elseif pkg == "typescript" and path:match("/lib/lib%.es") then
    base = "javascript"
  elseif pkg == "@types/node" or (pkg and pkg:match("^@types/node")) then
    base = "node"
    version = project and project.langs.node
  elseif pkg then
    local pj = util.json_decode(util.read_file(path:match("^(.*/node_modules/" .. vim.pesc(pkg) .. ")") .. "/package.json") or "")
    version = pj and pj.version
    local alias = (proj.DEVDOCS_ALIASES.node or {})[pkg]
    if alias == false then
      return cb(nil)
    end
    base = alias or pkg:gsub("^@types/", ""):gsub("^@[^/]+/", "")
  end
  if not base then
    return cb(nil)
  end
  require("rtfm.adapters.devdocs").catalog(function(err, catalog)
    local e = not err and proj.pick_devdocs(catalog, base, version) or nil
    if not e then
      return cb(nil)
    end
    cb({ source = require("rtfm.adapters.devdocs").source_from_entry(e), query = ident, match_last = true })
  end)
end

--- Dispatch by file type of the definition.
---@param cb fun(target: table|nil)
function M.locate(path, lnum, ident, project, cb)
  if path:match("%.go$") then
    return cb(M.go(path, lnum, ident, project))
  elseif path:match("%.pyi?$") then
    return M.python(path, lnum, ident, project, cb)
  elseif path:match("%.rs$") then
    return cb(M.rust(path, lnum, ident))
  elseif path:match("%.[cm]?[jt]sx?$") or path:match("%.d%.ts$") then
    return M.node(path, ident, project, cb)
  end
  cb(nil)
end

return M
