--- Docs for the symbol under the cursor: LSP → imports → fuzzy search.
local config = require("rtfm.config")
local imports = require("rtfm.symbol.imports")
local locate = require("rtfm.symbol.locate")
local project_mod = require("rtfm.project")
local search = require("rtfm.search")
local sources = require("rtfm.sources")
local util = require("rtfm.util")

local M = {}

--- Expression under the cursor: "http.NewRequest", "np.linalg.norm", "std::fs::read".
function M.expr_at(line, col)
  col = col + 1
  local allowed = "[%w_%.:$]"
  if not line:sub(col, col):match(allowed) then
    return nil
  end
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match(allowed) do
    s = s - 1
  end
  while e < #line and line:sub(e + 1, e + 1):match("[%w_$]") do
    e = e + 1
  end
  local expr = line:sub(s, e):gsub("^[%.:]+", ""):gsub("[%.:]+$", "")
  return expr ~= "" and expr or nil
end

local function strip_call(s)
  return (s:gsub("%(%)$", ""))
end

local function last_segment(s)
  return strip_call(s):match("([%w_$]+)$") or s
end

--- Find the entry for a "query" target in its source's index.
function M.resolve_query(target, cb)
  search.load(target.source, function(err, entries)
    if err or not entries then
      return cb(nil)
    end
    local q = strip_call(target.query)
    local best
    if target.exact then
      local want = {}
      for _, t in ipairs(target.exact) do
        want[strip_call(t)] = true
      end
      for _, e in ipairs(entries) do
        if want[strip_call(e.title or "")] then
          best = e
          break
        end
      end
    end
    if not best and target.match_last then
      local last = last_segment(q)
      local candidates = {}
      for _, e in ipairs(entries) do
        if last_segment(e.title or "") == last then
          table.insert(candidates, e)
        end
      end
      if target.module and target.module ~= "" then
        for _, e in ipairs(candidates) do
          if (e.title or ""):find(target.module, 1, true) == 1 then
            best = e
            break
          end
        end
      end
      best = best or candidates[1]
    end
    if not best then
      return cb(nil)
    end
    local item = vim.deepcopy(best)
    if target.fragment then
      local urllib = require("rtfm.url")
      item.fragment = target.fragment
      if item.url then
        item.url = urllib.strip_fragment(item.url) .. "#" .. target.fragment
      end
      if item.path then
        item.path = item.path:gsub("#.*$", "") .. "#" .. target.fragment
      end
    end
    cb(item)
  end)
end

local function open_target(target, mode, done)
  local viewer = require("rtfm.ui.viewer")
  if target.item then
    viewer.open(target.source, target.item, { mode = mode })
    return done(true)
  end
  M.resolve_query(target, function(item)
    if item then
      viewer.open(target.source, item, { mode = mode })
      return done(true)
    end
    done(false)
  end)
end

--- Ask attached LSP clients for the definition. cb(path, lnum) or cb(nil)
function M.lsp_definition(buf, win, cb)
  local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = buf })
  local capable = {}
  for _, c in ipairs(clients) do
    if c.server_capabilities and c.server_capabilities.definitionProvider then
      table.insert(capable, c)
    end
  end
  if #capable == 0 then
    return cb(nil)
  end
  local finished = false
  local function finish(path, lnum)
    if not finished then
      finished = true
      cb(path, lnum)
    end
  end
  local params = vim.lsp.util.make_position_params(win, capable[1].offset_encoding or "utf-16")
  vim.lsp.buf_request(buf, "textDocument/definition", params, function(err, result)
    if err or not result or (vim.islist or vim.tbl_islist)(result) and #result == 0 then
      return
    end
    local loc = (vim.islist or vim.tbl_islist)(result) and result[1] or result
    local uri = loc.targetUri or loc.uri
    local range = loc.targetSelectionRange or loc.targetRange or loc.range
    if uri and range then
      finish(vim.uri_to_fname(uri), range.start.line + 1)
    end
  end)
  vim.defer_fn(function()
    finish(nil)
  end, config.options.symbol.timeout)
end

local function in_project(path, root)
  if not root or path:sub(1, #root + 1) ~= root .. "/" then
    return false
  end
  local rel = path:sub(#root + 2)
  return not (rel:match("^vendor/") or rel:find("node_modules/", 1, true) or rel:find("site-packages/", 1, true) or rel:match("^%.venv/"))
end

-- import-based resolution, per filetype -----------------------------------------------------

local function from_imports(buf, ft, expr, ident, project, cb)
  if ft == "go" then
    return cb(imports.go(buf, expr, project))
  elseif ft == "python" then
    local r = imports.python(buf, expr)
    if not r then
      return cb(nil)
    end
    local base = r.module
    local version = nil
    local mapped = (project_mod.DEVDOCS_ALIASES.python or {})[base]
    if mapped == false then
      return cb(nil)
    end
    local dep = project_mod.dep(project, base, "python")
    if dep then
      version = dep.version
    end
    require("rtfm.adapters.devdocs").catalog(function(err, catalog)
      local e = not err and project_mod.pick_devdocs(catalog, mapped or base, version) or nil
      if not e then
        -- stdlib module?
        e = not err and project_mod.pick_devdocs(catalog, "python", project.langs.python) or nil
      end
      if not e then
        return cb(nil)
      end
      cb({
        source = require("rtfm.adapters.devdocs").source_from_entry(e),
        query = r.qualified,
        exact = { r.qualified, r.qualified .. "()" },
        match_last = true,
      })
    end)
  elseif ft == "rust" then
    local r = imports.rust(buf, expr)
    if not r then
      return cb(nil)
    end
    if r.crate == "std" or r.crate == "core" or r.crate == "alloc" then
      local src = sources.get_sync("rust")
      return cb(src and { source = src, query = r.path, match_last = true } or nil)
    end
    local locked = project.ecosystems.rust and project.ecosystems.rust.locked or {}
    local crate = r.crate:gsub("_", "-")
    local version = locked[crate] or locked[r.crate]
    if not version then
      local dep = project_mod.dep(project, crate, "rust") or project_mod.dep(project, r.crate, "rust")
      version = dep and dep.version
    end
    local docsrs = require("rtfm.adapters.docsrs")
    local src = docsrs.versioned(locked[crate] and crate or r.crate, version or "latest")
    local module = r.path:gsub("^[%w_]+::", ""):match("^(.*)::[%w_]+$")
    return cb({ source = src, query = r.name, module = module, match_last = true })
  elseif ft == "javascript" or ft == "typescript" or ft == "javascriptreact" or ft == "typescriptreact" then
    local r = imports.js(buf, expr)
    if not r then
      return cb(nil)
    end
    local base = (project_mod.DEVDOCS_ALIASES.node or {})[r.package]
    if base == false then
      return cb(nil)
    end
    base = base or r.package:gsub("^@[^/]+/", "")
    local dep = project_mod.dep(project, r.package, "node")
    require("rtfm.adapters.devdocs").catalog(function(err, catalog)
      local e = not err and project_mod.pick_devdocs(catalog, base, dep and dep.version) or nil
      if not e then
        return cb(nil)
      end
      cb({ source = require("rtfm.adapters.devdocs").source_from_entry(e), query = r.name, match_last = true })
    end)
  else
    cb(nil)
  end
end

-- fuzzy fallback ----------------------------------------------------------------------------

local function fuzzy_fallback(buf, ft, expr, ident, mode)
  local function go_with(source_id)
    if not source_id then
      return require("rtfm.ui.picker").open({ query = expr })
    end
    sources.get(source_id, function(err, src)
      if err then
        return require("rtfm.ui.picker").open({ query = expr })
      end
      search.query(src, expr, function(qerr, matches)
        local top = not qerr and matches and matches[1]
        if top then
          local exact = {}
          for _, m in ipairs(matches) do
            local t = strip_call(m.item.title or "")
            if t == expr or last_segment(t) == ident and t:find(expr, 1, true) then
              table.insert(exact, m)
            end
          end
          if #exact == 1 or (exact[1] and strip_call(exact[1].item.title) == expr) then
            return require("rtfm.ui.viewer").open(src, exact[1].item, { mode = mode })
          end
        end
        require("rtfm.ui.picker").open({ source = src, query = expr })
      end, 50)
    end)
  end
  if ft == "go" then
    -- pkg.go.dev symbol search understands "pkg.Symbol"
    return go_with("gopkg")
  end
  project_mod.source_for_filetype(buf, ft, go_with)
end

--- Open docs for the symbol under the cursor.
---@param opts? {mode?: string}
function M.lookup(opts)
  opts = opts or {}
  local mode = opts.mode or config.options.symbol.open
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local ft = vim.bo[buf].filetype
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_get_current_line()
  local expr = M.expr_at(line, cursor[2])
  local ident = vim.fn.expand("<cword>")
  if not expr or ident == "" then
    return util.warn("no symbol under the cursor")
  end

  -- Neovim's own Lua API lives in :help
  if (ft == "lua" or ft == "vim") and (expr:match("^vim%.") or ft == "vim") then
    if pcall(vim.cmd.help, expr) or pcall(vim.cmd.help, ident) then
      return
    end
  end

  local project = project_mod.detect(buf)

  local function step_fuzzy()
    fuzzy_fallback(buf, ft, expr, ident, mode)
  end

  local function step_imports()
    from_imports(buf, ft, expr, ident, project, function(target)
      if not target then
        return step_fuzzy()
      end
      open_target(target, mode, function(ok)
        if not ok then
          step_fuzzy()
        end
      end)
    end)
  end

  if not config.options.symbol.lsp then
    return step_imports()
  end
  M.lsp_definition(buf, win, function(path, lnum)
    if not path or in_project(path, project.root) then
      return step_imports()
    end
    locate.locate(path, lnum, ident, project, function(target)
      if not target then
        return step_imports()
      end
      open_target(target, mode, function(ok)
        if not ok then
          step_imports()
        end
      end)
    end)
  end)
end

return M
