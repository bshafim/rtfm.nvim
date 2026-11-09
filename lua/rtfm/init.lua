--- rtfm.nvim — read the docs without leaving Neovim.
local config = require("rtfm.config")
local util = require("rtfm.util")

local M = {}

local HL = {
  RtfmNormal = { link = "NormalFloat" },
  RtfmBorder = { link = "FloatBorder" },
  RtfmTitle = { link = "FloatTitle" },
  RtfmFooter = { link = "Comment" },
  RtfmChip = { link = "PmenuSel" },
  RtfmPrompt = { link = "Question" },
  RtfmMatch = { link = "Special" },
  RtfmKind = { link = "Comment" },
  RtfmSelection = { link = "CursorLine" },
  RtfmFavorite = { link = "DiagnosticWarn" },
  RtfmProject = { link = "DiagnosticInfo" },
  RtfmInstalled = { link = "DiagnosticOk" },
  RtfmSemantic = { link = "DiagnosticHint" },
  RtfmFlash = { link = "Visual" },
}

local function set_highlights()
  for name, spec in pairs(HL) do
    spec = vim.tbl_extend("force", spec, { default = true })
    vim.api.nvim_set_hl(0, name, spec)
  end
end

local did_setup = false

function M.setup(opts)
  config.setup(opts)
  set_highlights()
  local group = vim.api.nvim_create_augroup("rtfm", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  if config.options.symbol.keymap then
    vim.keymap.set("n", config.options.symbol.keymap, M.symbol, { desc = "rtfm: docs for symbol under cursor" })
  end
  did_setup = true
end

function M.ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

--- Open the picker. With a source, starts in search mode.
---@param opts? rtfm.PickerOpts
function M.open(opts)
  M.ensure_setup()
  opts = opts or {}
  if opts.source or opts.mode then
    return require("rtfm.ui.picker").open(opts)
  end
  if not config.options.project.enabled then
    return require("rtfm.ui.picker").open(opts)
  end
  local buf = vim.api.nvim_get_current_buf()
  require("rtfm.project").sources(buf, function(project_sources)
    opts.extra_sources = project_sources
    require("rtfm.ui.picker").open(opts)
  end)
end

--- Search a source; with `first = true` open the best match directly.
function M.search(source_id, query, opts)
  M.ensure_setup()
  opts = opts or {}
  if not opts.first then
    return M.open({ source = source_id, query = query })
  end
  local sources, search = require("rtfm.sources"), require("rtfm.search")
  sources.get(source_id, function(err, src)
    if err then
      return util.error(err)
    end
    search.query(src, query or "", function(qerr, matches)
      if qerr then
        return util.error(qerr)
      end
      if not matches[1] then
        return util.warn(("no results for %q in %s"):format(query or "", src.name))
      end
      require("rtfm.ui.viewer").open(src, matches[1].item, { mode = opts.mode })
    end, 10)
  end)
end

function M.symbol(opts)
  M.ensure_setup()
  require("rtfm.symbol").lookup(opts)
end

function M.ask(query)
  M.ensure_setup()
  require("rtfm.ui.picker").open({ mode = "ask", query = query })
end

function M.open_url(u, opts)
  M.ensure_setup()
  require("rtfm.ui.viewer").open_id("web", { url = u, title = u, fragment = require("rtfm.url").fragment(u) }, opts)
end

local function item_list(entries)
  local items = {}
  for _, e in ipairs(entries) do
    local it = vim.deepcopy(e.item)
    it.title = e.title or it.title
    it.kind = e.note or nil
    it._source_id = e.source
    it._source_name = e.source
    it._key = e.key
    it.search = (it.title or "") .. " " .. (e.note or "") .. " " .. e.source
    table.insert(items, it)
  end
  return items
end

function M.bookmarks()
  M.ensure_setup()
  local store = require("rtfm.store")
  require("rtfm.ui.picker").open({
    mode = "list",
    title = "bookmarks (<C-x> delete)",
    items = item_list(store.bookmarks()),
    on_delete = function(item)
      store.remove_entry("bookmarks", item._key)
    end,
  })
end

function M.history()
  M.ensure_setup()
  local store = require("rtfm.store")
  require("rtfm.ui.picker").open({
    mode = "list",
    title = "history (<C-x> delete)",
    items = item_list(store.history()),
    on_delete = function(item)
      store.remove_entry("history", item._key)
    end,
  })
end

--- Picker limited to the current project's doc sources.
function M.project()
  M.ensure_setup()
  local buf = vim.api.nvim_get_current_buf()
  require("rtfm.project").sources(buf, function(list, project)
    if #list == 0 then
      return util.notify("no versioned docs detected for " .. project.root)
    end
    require("rtfm.ui.picker").open({ extra_sources = list, sources_only = true })
  end)
end

-- install / index ----------------------------------------------------------------------------

local function progress(prefix)
  return function(msg)
    vim.api.nvim_echo({ { "rtfm: ", "Title" }, { prefix .. ": " .. msg } }, false, {})
  end
end

local function with_sources(ids, cb)
  local sources = require("rtfm.sources")
  if ids == "project" then
    return require("rtfm.project").sources(vim.api.nvim_get_current_buf(), function(list)
      cb(list)
    end)
  end
  sources.get(ids, function(err, src)
    if err then
      return util.error(err)
    end
    cb({ src })
  end)
end

local function sequential(list, fn, done)
  local i = 0
  local function next_one()
    i = i + 1
    if i > #list then
      return done and done()
    end
    fn(list[i], next_one)
  end
  next_one()
end

--- Install for offline use. id may be "project".
---@param opts? {index?: boolean}
function M.install(id, opts, cb)
  M.ensure_setup()
  opts = opts or {}
  local offline = require("rtfm.offline")
  with_sources(id, function(list)
    local installable = vim.tbl_filter(offline.installable, list)
    if #installable == 0 then
      return util.warn("nothing installable" .. (id == "project" and " in this project" or (": " .. id)))
    end
    local ok_count = 0
    sequential(installable, function(src, next_one)
      offline.install(src, { on_progress = progress(src.name) }, function(err, manifest)
        if err then
          util.error(src.name .. ": " .. err)
          return next_one()
        end
        ok_count = ok_count + 1
        require("rtfm.search").forget(src.id)
        util.notify(("installed %s (%d pages)"):format(src.name, manifest.pages or 0))
        if opts.index then
          M.index(src, {}, function()
            next_one()
          end)
        else
          next_one()
        end
      end)
    end, function()
      if #installable > 1 then
        util.notify(("installed %d/%d docs"):format(ok_count, #installable))
      end
      if cb then
        cb()
      end
    end)
  end)
end

--- Build the semantic index (installs first if needed). id may be "project" or a source table.
function M.index(id, opts, cb)
  M.ensure_setup()
  opts = opts or {}
  local offline, index = require("rtfm.offline"), require("rtfm.index")
  local function run(list)
    sequential(list, function(src, next_one)
      local function build()
        index.build(src, { on_progress = progress("indexing " .. src.name) }, function(err, meta)
          if err then
            util.error(src.name .. ": " .. err)
          else
            util.notify(("indexed %s: %d chunks%s"):format(src.name, meta.chunks, meta.embedded > 0 and (", " .. meta.embedded .. " embedded") or " (keyword only)"))
          end
          next_one()
        end)
      end
      if offline.is_installed(src) then
        return build()
      end
      if not offline.installable(src) then
        util.warn(src.name .. " can't be installed, so it can't be indexed")
        return next_one()
      end
      offline.install(src, { on_progress = progress(src.name) }, function(err)
        if err then
          util.error(src.name .. ": " .. err)
          return next_one()
        end
        require("rtfm.search").forget(src.id)
        build()
      end)
    end, cb)
  end
  if type(id) == "table" then
    return run({ id })
  end
  with_sources(id, run)
end

function M.uninstall(id)
  local offline = require("rtfm.offline")
  require("rtfm.sources").get(id, function(err, src)
    if err then
      return util.error(err)
    end
    if offline.uninstall(src) then
      require("rtfm.search").forget(src.id)
      util.notify("removed " .. src.name)
    else
      util.warn(src.name .. " is not installed")
    end
  end)
end

--- List installed docs in a picker (open, <C-x> uninstall).
function M.installed()
  M.ensure_setup()
  local offline, index = require("rtfm.offline"), require("rtfm.index")
  local list = {}
  for _, m in ipairs(offline.list()) do
    local src = m.source or { id = m.id, name = m.name, adapter = m.adapter }
    src._installed_label = ("%s · %d pages%s"):format(util.human_size(util.dir_size(m.dir)), m.pages or 0, index.status(src) and " · indexed" or "")
    table.insert(list, src)
  end
  if #list == 0 then
    return util.notify("nothing installed yet. Try :Rtfm install <source> or :Rtfm install project")
  end
  require("rtfm.ui.picker").open({ extra_sources = list, sources_only = true })
end

function M.set_offline(on)
  if on == nil then
    on = not config.options.offline
  end
  config.options.offline = on
  util.notify("offline mode " .. (on and "on" or "off"))
end

return M
