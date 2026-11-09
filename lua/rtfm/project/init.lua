--- Project detection: find manifests, read exact versions, map them to doc sources.
local config = require("rtfm.config")
local util = require("rtfm.util")

local M = {}

M.ECOSYSTEMS = { "go", "rust", "node", "python" }

local function parser(eco)
  return require("rtfm.project." .. eco)
end

local function read(path)
  return util.read_file(path)
end

-- devdocs base slugs for package names that don't match their doc slug
M.DEVDOCS_ALIASES = {
  node = {
    ["@angular/core"] = "angular",
    ["vue"] = "vue",
    ["next"] = "nextjs",
    ["three"] = "threejs",
    ["socket.io"] = "socketio",
    ["@babel/core"] = "babel",
    ["react-dom"] = false,
    ["@types/node"] = false,
    ["@reduxjs/toolkit"] = "redux",
    ["svelte"] = "svelte",
    ["tailwindcss"] = "tailwindcss",
    ["typescript"] = "typescript",
    ["vitest"] = "vitest",
    ["d3"] = "d3",
  },
  python = {
    torch = "pytorch",
    ["scikit-learn"] = "scikit_learn",
    ["scikit-image"] = "scikit_image",
    jinja2 = "jinja",
    ["beautifulsoup4"] = false,
  },
}

local function markers()
  return config.options.project.markers
end

function M.root(buf)
  buf = buf or 0
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or path:match("^%w+://") then
    path = vim.fn.getcwd()
  end
  local root
  if vim.fs.root then
    root = vim.fs.root(path, markers())
  else
    local found = vim.fs.find(markers(), { path = path, upward = true })[1]
    root = found and vim.fs.dirname(found)
  end
  return root or vim.fn.getcwd()
end

local cache = {}

local function signature(root)
  local parts = {}
  for _, eco in ipairs(M.ECOSYSTEMS) do
    for _, f in ipairs(parser(eco).files) do
      local m = util.mtime(root .. "/" .. f)
      if m then
        table.insert(parts, f .. "=" .. m)
      end
    end
  end
  return table.concat(parts, ",")
end

---@class rtfm.Project
---@field root string
---@field ecosystems table<string, table> per-ecosystem parse result
---@field langs table<string, string> language -> version

--- Detect the project for a buffer (cached; invalidated when manifests change).
---@return rtfm.Project
function M.detect(buf)
  local root = M.root(buf)
  local sig = signature(root)
  local hit = cache[root]
  if hit and hit.sig == sig then
    return hit.project
  end
  local project = { root = root, ecosystems = {}, langs = {} }
  for _, eco in ipairs(M.ECOSYSTEMS) do
    local ok, res = pcall(parser(eco).detect, root, read)
    if ok and res then
      project.ecosystems[eco] = res
      if res.lang_version then
        project.langs[res.lang] = res.lang_version
      end
    end
  end
  cache[root] = { sig = sig, project = project }
  return project
end

--- Find a dependency by name (and optional ecosystem).
function M.dep(project, name, eco)
  for e, res in pairs(project.ecosystems) do
    if not eco or e == eco then
      for _, d in ipairs(res.deps or {}) do
        if d.name == name then
          return d
        end
      end
    end
  end
end

--- Go: longest module path that is a prefix of an import path.
function M.go_module_for(project, import_path)
  local go = project.ecosystems.go
  if not go then
    return nil
  end
  local best
  for _, d in ipairs(go.deps) do
    if import_path == d.name or import_path:sub(1, #d.name + 1) == d.name .. "/" then
      if not best or #d.name > #best.name then
        best = d
      end
    end
  end
  return best
end

-- devdocs version matching ------------------------------------------------------------------

local function version_parts(v)
  local out = {}
  for n in tostring(v or ""):gmatch("%d+") do
    table.insert(out, tonumber(n))
  end
  return out
end

--- Pick the devdocs entry for `base` closest to `version` (at or below; else the oldest above).
---@return table|nil entry, boolean exact
function M.pick_devdocs(catalog, base, version)
  local dd = require("rtfm.adapters.devdocs")
  local candidates = {}
  for _, e in ipairs(catalog or {}) do
    if dd.base_slug(e.slug) == base then
      table.insert(candidates, e)
    end
  end
  if #candidates == 0 then
    return nil, false
  end
  if not version then
    return candidates[1], false
  end
  local used = version_parts(version)
  local best, best_parts
  local above, above_parts
  for _, e in ipairs(candidates) do
    local cp = version_parts(e.version)
    if #cp == 0 then
      -- unversioned doc: acceptable fallback
      above = above or e
    else
      local cmp = 0
      for i = 1, #cp do
        local a, b = cp[i], used[i] or 0
        if a ~= b then
          cmp = a < b and -1 or 1
          break
        end
      end
      if cmp <= 0 then
        if not best or util.version_cmp(table.concat(cp, "."), table.concat(best_parts, ".")) > 0 then
          best, best_parts = e, cp
        end
      elseif not above_parts or (above_parts and util.version_cmp(table.concat(cp, "."), table.concat(above_parts, ".")) < 0) then
        above, above_parts = e, cp
      end
    end
  end
  if best then
    local exact = true
    for i = 1, #best_parts do
      if best_parts[i] ~= used[i] then
        exact = false
      end
    end
    return best, exact
  end
  return above or candidates[1], false
end

local function devdocs_base_for(eco, name, catalog)
  local alias = (M.DEVDOCS_ALIASES[eco] or {})[name]
  if alias == false then
    return nil
  end
  local dd = require("rtfm.adapters.devdocs")
  local bases = {}
  for _, e in ipairs(catalog or {}) do
    bases[dd.base_slug(e.slug)] = true
  end
  local candidates = { alias }
  local n = name:lower()
  table.insert(candidates, n)
  table.insert(candidates, (n:gsub("^@[^/]+/", "")))
  table.insert(candidates, (n:gsub("[-.]", "_")))
  table.insert(candidates, (n:gsub("[-.]", "")))
  table.insert(candidates, (n:gsub("js$", "")))
  for _, c in ipairs(candidates) do
    if c and bases[c] then
      return c
    end
  end
end

--- Doc sources for the project's runtimes and direct dependencies.
---@param cb fun(sources: table[], project: rtfm.Project)
function M.sources(buf, cb)
  local project = M.detect(buf)
  local gopkg = require("rtfm.adapters.gopkg")
  local docsrs = require("rtfm.adapters.docsrs")
  local dd = require("rtfm.adapters.devdocs")

  local function build(catalog)
    local out = {}
    local function add(src, label)
      if src then
        src._project = label
        table.insert(out, src)
      end
    end
    local function add_devdocs(base, version, label)
      if not catalog then
        return
      end
      local e, exact = M.pick_devdocs(catalog, base, version)
      if e then
        local src = dd.source_from_entry(e)
        add(src, label .. (version and not exact and (" (closest docs: " .. (e.version ~= "" and e.version or "latest") .. ")") or ""))
      end
    end

    local go = project.ecosystems.go
    if go then
      if go.lang_version then
        add(gopkg.versioned("std", gopkg.std_version(go.lang_version)), "go.mod: go " .. go.lang_version)
      end
      for _, d in ipairs(go.deps) do
        if d.direct and d.version then
          add(gopkg.versioned(d.docs_name or d.name, d.version), "go.mod")
        end
      end
    end
    local rust = project.ecosystems.rust
    if rust then
      add_devdocs("rust", nil, "Cargo.toml")
      for _, d in ipairs(rust.deps) do
        if d.version then
          add(docsrs.versioned(d.name, d.version), "Cargo.toml")
        end
      end
    end
    local node = project.ecosystems.node
    if node then
      if node.lang_version then
        local major = node.lang_version:match("^(%d+)")
        add_devdocs("node", major, "node " .. node.lang_version)
      end
      for _, d in ipairs(node.deps) do
        local base = devdocs_base_for("node", d.name, catalog)
        if base then
          add_devdocs(base, d.version, "package.json: " .. d.name .. "@" .. tostring(d.version))
        end
      end
    end
    local py = project.ecosystems.python
    if py then
      if py.lang_version then
        add_devdocs("python", py.lang_version, "python " .. py.lang_version)
      end
      for _, d in ipairs(py.deps) do
        local base = devdocs_base_for("python", d.name, catalog)
        if base then
          add_devdocs(base, d.version, d.name .. " " .. tostring(d.version or ""))
        end
      end
    end
    -- dedupe by id, keep first
    local seen, uniq = {}, {}
    for _, s in ipairs(out) do
      if not seen[s.id] then
        seen[s.id] = true
        table.insert(uniq, s)
      end
    end
    cb(uniq, project)
  end

  if not config.options.devdocs.enabled then
    return build(nil)
  end
  dd.catalog(function(err, catalog)
    build(not err and catalog or nil)
  end)
end

--- Which source should a filetype use in this project (version-aware)?
---@param cb fun(source_id: string|nil)
function M.source_for_filetype(buf, ft, cb)
  local fallback = config.options.filetypes[ft]
  local project = M.detect(buf)
  local dd = require("rtfm.adapters.devdocs")
  local lang_map = { python = "python", javascript = "node", typescript = "node" }
  local lang = lang_map[ft]
  if ft == "go" and project.langs.go then
    local gopkg = require("rtfm.adapters.gopkg")
    return cb(gopkg.versioned("std", gopkg.std_version(project.langs.go)).id)
  end
  if lang == "python" and project.langs.python and config.options.devdocs.enabled then
    return dd.catalog(function(err, catalog)
      local e = not err and M.pick_devdocs(catalog, "python", project.langs.python) or nil
      cb(e and e.slug or fallback)
    end)
  end
  cb(fallback)
end

return M
