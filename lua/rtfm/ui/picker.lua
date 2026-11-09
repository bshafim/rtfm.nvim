--- Floating picker: choose a source, search it, preview pages, open them.
---
--- Modes:
---   source  filter the list of sources; <Tab>/<CR> picks one (becomes a chip in the prompt)
---   search  query the chosen source (fuzzy for local sources, debounced for remote ones)
---   list    a fixed list of entries (bookmarks, history, project deps)
---   ask     semantic search across every indexed doc
local config = require("rtfm.config")
local fuzzy = require("rtfm.fuzzy")
local offline = require("rtfm.offline")
local page = require("rtfm.page")
local search = require("rtfm.search")
local sources = require("rtfm.sources")
local store = require("rtfm.store")
local util = require("rtfm.util")

local M = {}

local ns = vim.api.nvim_create_namespace("rtfm.picker")
local ns_chip = vim.api.nvim_create_namespace("rtfm.picker.chip")
local ns_sel = vim.api.nvim_create_namespace("rtfm.picker.sel")

---@type table|nil the open picker
local P

-- helpers ---------------------------------------------------------------------------------

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

--- Mark the selected row with a caret (visible regardless of the theme's CursorLine).
local function place_caret()
  if not P or not vim.api.nvim_buf_is_valid(P.bufs.results) then
    return
  end
  vim.api.nvim_buf_clear_namespace(P.bufs.results, ns_sel, 0, -1)
  if P.matches[P.sel] then
    vim.api.nvim_buf_set_extmark(P.bufs.results, ns_sel, P.sel - 1, 0, {
      virt_text = { { "▌", "RtfmCaret" } },
      virt_text_pos = "overlay",
      priority = 200,
    })
  end
end

local function is_ascii(s)
  return not s:find("[\128-\255]")
end

local function adapter_label(src)
  local labels = { devdocs = "devdocs", gopkg = "pkg.go.dev", docsrs = "docs.rs", github = "github", mdn = "mdn", sitemap = "site", algolia = "algolia", web = "web" }
  return labels[src.adapter] or src.adapter
end

local function source_marks(src)
  local icons = config.options.ui.icons
  local marks = {}
  if src._project then
    table.insert(marks, { icons.project, "RtfmProject" })
  end
  if store.is_favorite(src.id) then
    table.insert(marks, { icons.favorite, "RtfmFavorite" })
  end
  if offline.is_installed(src) then
    table.insert(marks, { icons.installed, "RtfmInstalled" })
  end
  return marks
end

local function current_query()
  if not P or not vim.api.nvim_buf_is_valid(P.bufs.prompt) then
    return ""
  end
  return vim.api.nvim_buf_get_lines(P.bufs.prompt, 0, 1, false)[1] or ""
end

local function set_footer(text)
  if not P or not valid(P.wins.results) then
    return
  end
  pcall(vim.api.nvim_win_set_config, P.wins.results, {
    footer = { { " " .. text .. " ", "RtfmFooter" } },
    footer_pos = "right",
  })
end

local function set_title(win, text)
  if valid(win) then
    pcall(vim.api.nvim_win_set_config, win, { title = { { " " .. text .. " ", "RtfmTitle" } }, title_pos = "center" })
  end
end

-- layout ----------------------------------------------------------------------------------

local function layout()
  local ui = config.options.ui
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local W = math.max(40, math.floor(cols * ui.width))
  local H = math.max(10, math.floor(lines * ui.height))
  local row = math.floor((lines - H) / 2)
  local col = math.floor((cols - W) / 2)
  local show_preview = ui.preview and W >= 80
  local rw = show_preview and math.floor(W * ui.results_width) or W
  return {
    prompt = { row = row, col = col, width = rw - 2, height = 1 },
    results = { row = row + 3, col = col, width = rw - 2, height = H - 5 },
    preview = show_preview and { row = row, col = col + rw, width = W - rw - 2, height = H - 2 } or nil,
  }
end

local function float_opts(geo, extra)
  return vim.tbl_extend("force", {
    relative = "editor",
    row = geo.row,
    col = geo.col,
    width = geo.width,
    height = geo.height,
    border = config.options.ui.border,
    style = "minimal",
    zindex = 60,
  }, extra or {})
end

local function scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

-- rendering -------------------------------------------------------------------------------

local function display_of(match)
  local it = match.item
  if P.mode == "source" then
    return it.name, it._installed_label or it._project or adapter_label(it)
  end
  local title = it.title or it.url or "?"
  local kind = it.kind
  if it._source_name then
    kind = it._source_name .. (kind and (" · " .. kind) or "")
  end
  return title, kind
end

local function render_results()
  if not P or not vim.api.nvim_buf_is_valid(P.bufs.results) then
    return
  end
  local buf = P.bufs.results
  local lines = {}
  local icons = config.options.ui.icons
  local prefixes = {}
  for i, m in ipairs(P.matches) do
    local title = display_of(m)
    local marks = P.mode == "source" and source_marks(m.item) or {}
    if m.semantic then
      table.insert(marks, { icons.semantic, "RtfmSemantic" })
    end
    local prefix = " "
    for _, mk in ipairs(marks) do
      prefix = prefix .. mk[1] .. " "
    end
    prefixes[i] = { prefix = prefix, marks = marks }
    lines[i] = prefix .. title:gsub("\n", " ")
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, m in ipairs(P.matches) do
    local title, kind = display_of(m)
    local pre = prefixes[i]
    -- mark icons
    local col = 1
    for _, mk in ipairs(pre.marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = col + #mk[1], hl_group = mk[2] })
      col = col + #mk[1] + 1
    end
    -- fuzzy match positions (only within the title part of the search text)
    if m.positions and #m.positions > 0 and is_ascii(title) then
      for _, pos in ipairs(m.positions) do
        if pos < #title then
          local c = #pre.prefix + pos
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, c, { end_col = c + 1, hl_group = "RtfmMatch" })
        end
      end
    end
    if kind and kind ~= "" then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { kind:sub(1, 48), "RtfmKind" } },
        virt_text_pos = "right_align",
        hl_mode = "combine",
      })
    end
  end
  if valid(P.wins.results) then
    if #P.matches > 0 then
      P.sel = math.max(1, math.min(P.sel, #P.matches))
      vim.api.nvim_win_set_cursor(P.wins.results, { P.sel, 0 })
    end
  end
  place_caret()
end

-- preview ---------------------------------------------------------------------------------

local function set_preview(lines, opts)
  opts = opts or {}
  if not P or not P.bufs.preview or not vim.api.nvim_buf_is_valid(P.bufs.preview) then
    return
  end
  local buf = P.bufs.preview
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_exec_autocmds, "TextChanged", { buffer = buf, modeline = false })
  if valid(P.wins.preview) then
    local line = math.max(1, math.min(opts.line or 1, #lines))
    vim.api.nvim_win_set_cursor(P.wins.preview, { line, 0 })
    vim.api.nvim_win_call(P.wins.preview, function()
      vim.cmd("normal! zt")
    end)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if opts.line and opts.line > 1 then
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = "RtfmFlash" })
    end
    if opts.title then
      set_title(P.wins.preview, opts.title)
    end
  end
end

local function source_info(src)
  local lines = { "# " .. src.name, "" }
  local function kv(k, v)
    if v and v ~= "" then
      table.insert(lines, ("- **%s**: %s"):format(k, v))
    end
  end
  kv("id", "`" .. src.id .. "`")
  kv("adapter", adapter_label(src))
  kv("version", src.version or src.release)
  kv("home", src.home or src.url)
  if src._project then
    kv("project", src._project)
  end
  kv("search", sources.mode(src) == "local" and "local index, fuzzy as you type" or "remote, debounced")
  local m = offline.manifest(src)
  kv("offline", m and ("installed, " .. (m.pages or 0) .. " pages") or (offline.installable(src) and "not installed (`:Rtfm install " .. src.id .. "`)" or "n/a"))
  local idx = require("rtfm.index").status(src)
  kv("semantic index", idx and (idx.chunks .. " chunks" .. (idx.vectors and (", embedded with " .. idx.model) or ", lexical only")) or "none")
  kv("favorite", store.is_favorite(src.id) and "yes" or "no (<C-f> to toggle)")
  vim.list_extend(lines, {
    "",
    "_<Tab>/<CR> search this source · <C-f> favorite · <Esc> close_",
  })
  return lines
end

local function source_of_match(m)
  if m.item._source then
    return m.item._source
  end
  return P.source
end

local function update_preview()
  if not P or not P.wins.preview then
    return
  end
  local m = P.matches[P.sel]
  P.preview_req = (P.preview_req or 0) + 1
  local req = P.preview_req
  if not m then
    return set_preview({ "", "  " .. (P.empty_msg or "No results") })
  end
  if P.mode == "source" then
    return set_preview(source_info(m.item), { title = m.item.name })
  end
  if m.item._source_id and not m.item._source then
    -- list entries carry a source id only; resolve it first
    return sources.get(m.item._source_id, function(err, s)
      if err or not P or req ~= P.preview_req then
        return
      end
      m.item._source = s
      update_preview()
    end)
  end
  local src = source_of_match(m)
  if not src then
    return
  end
  set_preview({ "", "  _Loading…_" }, { title = m.item.title })
  P.preview_debounced(src, m.item, req)
end

local function load_preview(src, item, req)
  page.load(src, item, function(err, p)
    if not P or req ~= P.preview_req then
      return
    end
    if err then
      return set_preview({ "", "> " .. err }, { title = item.title })
    end
    local line = page.anchor_line(p, p.fragment)
    set_preview(p.lines, { line = line, title = p.title })
  end)
end

-- querying --------------------------------------------------------------------------------

local function set_matches(matches, footer)
  if not P then
    return
  end
  P.matches = matches or {}
  P.sel = 1
  render_results()
  set_footer(footer or (#P.matches .. " results"))
  update_preview()
end

local function sort_sources(list)
  local recent = {}
  for i, id in ipairs(store.recent_sources()) do
    recent[id] = i
  end
  local function rank(s)
    if s._project then
      return 0
    elseif store.is_favorite(s.id) then
      return 1
    elseif recent[s.id] then
      return 2
    elseif offline.is_installed(s) then
      return 3
    end
    return 4
  end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    if ra == 0 and a._order and b._order then
      return a._order < b._order
    end
    if ra == 2 then
      return recent[a.id] < recent[b.id]
    end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

local function source_items()
  local out = {}
  for _, s in ipairs(P.sources or {}) do
    s.search = s.name .. " " .. s.id
    s.title = s.name
    table.insert(out, s)
  end
  return out
end

local function wants_semantic(query)
  if P.semantic ~= nil then
    return P.semantic
  end
  local words = select(2, query:gsub("%S+", ""))
  return words >= config.options.index.semantic_min_words
end

local function run_query()
  if not P then
    return
  end
  local query = current_query()
  P.req = P.req + 1
  local req = P.req
  if P.handle then
    pcall(P.handle.cancel)
    P.handle = nil
  end

  if P.mode == "source" then
    return set_matches(fuzzy.filter(source_items(), query, config.options.ui.max_results), (#P.sources .. " sources"))
  elseif P.mode == "list" then
    return set_matches(fuzzy.filter(P.items, query, config.options.ui.max_results), (#P.items .. " entries"))
  end

  local index = require("rtfm.index")
  if P.mode == "ask" then
    if vim.trim(query) == "" then
      return set_matches({}, "type a question")
    end
    set_footer("thinking…")
    return P.remote_debounced(function()
      index.search_all(query, function(err, results)
        if not P or req ~= P.req then
          return
        end
        if err then
          return set_matches({}, err)
        end
        set_matches(results, #results .. " results · semantic")
      end)
    end)
  end

  local src = P.source
  local semantic = wants_semantic(query) and index.status(src) ~= nil and vim.trim(query) ~= ""
  if semantic then
    set_footer("searching…")
    return P.remote_debounced(function()
      index.search(src, query, function(err, results)
        if not P or req ~= P.req then
          return
        end
        if err then
          return set_matches({}, err)
        end
        set_matches(results, #results .. " results · " .. (P.semantic == nil and "auto " or "") .. "semantic")
      end)
    end)
  end

  local is_local = sources.mode(src) == "local"
  if not is_local and vim.trim(query) == "" then
    -- show recently opened pages of this source
    local items = {}
    for _, h in ipairs(store.history(src.id)) do
      local it = vim.deepcopy(h.item)
      it.title = h.title or it.title
      it.kind = "recent"
      table.insert(items, { item = it, positions = {}, score = 0 })
    end
    P.empty_msg = "Type to search " .. src.name
    return set_matches(items, #items > 0 and "recent" or "type to search")
  end
  local function deliver(err, matches)
    if not P or req ~= P.req then
      return
    end
    if err then
      P.empty_msg = err
      return set_matches({}, "error")
    end
    P.empty_msg = "No results"
    set_matches(matches, #matches .. " results · " .. adapter_label(src))
  end
  if is_local then
    if not P.entries_loaded then
      set_footer("loading index…")
    end
    search.query(src, query, function(err, matches)
      if P then
        P.entries_loaded = true
      end
      deliver(err, matches)
    end, config.options.ui.max_results)
  else
    set_footer("searching…")
    P.remote_debounced(function()
      if not P or req ~= P.req then
        return
      end
      P.handle = search.query(src, query, deliver, config.options.ui.max_results)
    end)
  end
end

-- chip / modes ----------------------------------------------------------------------------

local function render_prompt_decor()
  if not P or not vim.api.nvim_buf_is_valid(P.bufs.prompt) then
    return
  end
  local buf = P.bufs.prompt
  vim.api.nvim_buf_clear_namespace(buf, ns_chip, 0, -1)
  local chunks = {}
  if P.mode == "search" and P.source then
    table.insert(chunks, { " " .. P.source.name .. " ", "RtfmChip" })
    table.insert(chunks, { " ", "Normal" })
  elseif P.mode == "ask" then
    table.insert(chunks, { " ask ", "RtfmChip" })
    table.insert(chunks, { " ", "Normal" })
  end
  table.insert(chunks, { config.options.ui.icons.prompt, "RtfmPrompt" })
  vim.api.nvim_buf_set_extmark(buf, ns_chip, 0, 0, { virt_text = chunks, virt_text_pos = "inline", right_gravity = false })
  local titles = {
    source = "rtfm · pick a source",
    search = "rtfm · search",
    list = "rtfm · " .. (P.list_title or "list"),
    ask = "rtfm · ask your docs",
  }
  local t = titles[P.mode]
  if P.mode == "search" and P.semantic ~= nil then
    t = t .. (P.semantic and " (semantic)" or " (keyword)")
  end
  set_title(P.wins.prompt, t)
end

local function set_query(text)
  if not vim.api.nvim_buf_is_valid(P.bufs.prompt) then
    return M.close()
  end
  P.setting_query = true
  vim.api.nvim_buf_set_lines(P.bufs.prompt, 0, -1, false, { text or "" })
  vim.schedule(function()
    if P then
      P.setting_query = false
    end
  end)
  if valid(P.wins.prompt) then
    vim.api.nvim_win_set_cursor(P.wins.prompt, { 1, #(text or "") })
  end
end

local function enter_search(src, query)
  P.mode = "search"
  P.source = src
  P.entries_loaded = false
  P.semantic = nil
  P.matches = {}
  render_prompt_decor()
  set_query(query or "")
  run_query()
end

local function enter_sources(query)
  P.mode = "source"
  P.source = nil
  P.matches = {}
  render_prompt_decor()
  set_query(query or "")
  run_query()
end

-- actions ---------------------------------------------------------------------------------

M.actions = {}

function M.close()
  if not P then
    return
  end
  local p = P
  P = nil
  if p.remote_debounced then
    p.remote_debounced.close()
  end
  if p.preview_debounced then
    p.preview_debounced.close()
  end
  if p.handle then
    pcall(p.handle.cancel)
  end
  pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
  for _, win in pairs(p.wins) do
    if valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.cmd("stopinsert")
  if valid(p.origin_win) then
    pcall(vim.api.nvim_set_current_win, p.origin_win)
  end
end
M.actions.close = M.close

local function open_with(mode)
  local m = P and P.matches[P.sel]
  if not m then
    return
  end
  if P.mode == "source" then
    return enter_search(m.item)
  end
  local item = m.item
  local src = source_of_match(m)
  local source_id = item._source_id or (src and src.id)
  local on_open = P.on_open
  M.close()
  vim.schedule(function()
    if on_open then
      return on_open(item, mode)
    end
    local viewer = require("rtfm.ui.viewer")
    local clean = vim.deepcopy(item)
    clean._source, clean._source_id, clean._source_name = nil, nil, nil
    if src and src.id == source_id then
      viewer.open(src, clean, { mode = mode })
    else
      viewer.open_id(source_id, clean, { mode = mode })
    end
  end)
end

function M.actions.open()
  open_with(P and P.open_mode or config.options.open)
end
function M.actions.open_split()
  open_with("split")
end
function M.actions.open_vsplit()
  open_with("vsplit")
end
function M.actions.open_tab()
  open_with("tab")
end
function M.actions.open_float()
  open_with("float")
end

function M.actions.select_source()
  if P.mode == "source" then
    local m = P.matches[P.sel]
    if m then
      enter_search(m.item)
    end
  else
    M.actions.next()
  end
end

local function move(delta)
  if not P or #P.matches == 0 then
    return
  end
  P.sel = ((P.sel - 1 + delta) % #P.matches) + 1
  if valid(P.wins.results) then
    vim.api.nvim_win_set_cursor(P.wins.results, { P.sel, 0 })
  end
  place_caret()
  update_preview()
end

function M.actions.next()
  move(1)
end
function M.actions.prev()
  move(-1)
end

local function scroll_preview(key)
  if P and valid(P.wins.preview) then
    vim.api.nvim_win_call(P.wins.preview, function()
      vim.cmd("normal! " .. vim.keycode(key))
    end)
  end
end
function M.actions.preview_down()
  scroll_preview("<C-d>")
end
function M.actions.preview_up()
  scroll_preview("<C-u>")
end

function M.actions.toggle_favorite()
  local src = P.mode == "source" and (P.matches[P.sel] or {}).item or P.source
  if not src or not src.id then
    return
  end
  local on = store.toggle_favorite(src.id)
  util.notify((on and "★ favorited " or "unfavorited ") .. src.name)
  render_results()
  update_preview()
end

function M.actions.bookmark()
  local m = P.matches[P.sel]
  if not m or P.mode == "source" then
    return
  end
  local src = source_of_match(m)
  local id = m.item._source_id or (src and src.id)
  if id then
    local clean = vim.deepcopy(m.item)
    clean._source, clean._source_id, clean._source_name = nil, nil, nil
    store.add_bookmark(id, clean, clean.title)
    util.notify("bookmarked " .. (clean.title or ""))
  end
end

function M.actions.delete()
  local m = P.matches[P.sel]
  if not m or not P.on_delete then
    return
  end
  P.on_delete(m.item)
  for i, it in ipairs(P.items) do
    if it == m.item then
      table.remove(P.items, i)
      break
    end
  end
  run_query()
end

function M.actions.toggle_semantic()
  if P.mode ~= "search" then
    return
  end
  if not require("rtfm.index").status(P.source) then
    return util.warn(P.source.name .. " has no semantic index yet. Run :Rtfm index " .. P.source.id)
  end
  if P.semantic == nil then
    P.semantic = true
  else
    P.semantic = not P.semantic
  end
  render_prompt_decor()
  run_query()
end

function M.actions.browser()
  local m = P.matches[P.sel]
  local u = m and (P.mode == "source" and (m.item.home or m.item.url) or m.item.url)
  if u then
    util.open_in_browser(u)
  end
end

function M.actions.backspace()
  if P.mode == "search" and current_query() == "" and not P.locked then
    return enter_sources()
  end
  vim.api.nvim_feedkeys(vim.keycode("<BS>"), "n", false)
end

-- open --------------------------------------------------------------------------------------

local function setup_keymaps(buf)
  for lhs, action in pairs(config.options.keymaps.picker) do
    local fn = type(action) == "function" and action or (action and M.actions[action])
    if fn then
      vim.keymap.set("i", lhs, function()
        fn()
      end, { buffer = buf, nowait = true, desc = "rtfm: " .. tostring(action) })
    end
  end
  vim.keymap.set("n", "<Esc>", M.close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", M.actions.open, { buffer = buf, nowait = true })
  vim.keymap.set("n", "j", M.actions.next, { buffer = buf, nowait = true })
  vim.keymap.set("n", "k", M.actions.prev, { buffer = buf, nowait = true })
end

local function create_windows()
  local geo = layout()
  P.bufs.prompt = scratch()
  vim.bo[P.bufs.prompt].buftype = "nofile"
  P.bufs.results = scratch()
  P.wins.results = vim.api.nvim_open_win(P.bufs.results, false, float_opts(geo.results, { focusable = false }))
  if geo.preview then
    P.bufs.preview = scratch()
    P.wins.preview = vim.api.nvim_open_win(P.bufs.preview, false, float_opts(geo.preview, { focusable = false }))
    -- set after the window exists so markdown renderers attach
    vim.bo[P.bufs.preview].filetype = "markdown"
    vim.wo[P.wins.preview].wrap = true
    vim.wo[P.wins.preview].linebreak = true
    vim.wo[P.wins.preview].conceallevel = 2
    vim.wo[P.wins.preview].winhighlight = "NormalFloat:RtfmNormal,FloatBorder:RtfmBorder"
  end
  P.wins.prompt = vim.api.nvim_open_win(P.bufs.prompt, true, float_opts(geo.prompt))
  vim.wo[P.wins.results].cursorline = true
  vim.wo[P.wins.results].winhighlight = "NormalFloat:RtfmNormal,FloatBorder:RtfmBorder,CursorLine:RtfmSelection"
  vim.wo[P.wins.prompt].winhighlight = "NormalFloat:RtfmNormal,FloatBorder:RtfmBorder"
end

local function relayout()
  if not P then
    return
  end
  local geo = layout()
  for name, win in pairs(P.wins) do
    if valid(win) and geo[name] then
      vim.api.nvim_win_set_config(win, float_opts(geo[name]))
    end
  end
end

---@class rtfm.PickerOpts
---@field source? string|table preselected source (skips source mode)
---@field query? string initial query
---@field mode? "source"|"search"|"list"|"ask"
---@field items? table[] for list mode: items with title/kind and _source_id
---@field title? string list title
---@field on_delete? fun(item: table)
---@field on_open? fun(item: table, mode: string)
---@field locked? boolean don't allow going back to source mode
---@field open_mode? string default open mode for <CR>
---@field extra_sources? table[] sources to show first (project deps)
---@field sources_only? boolean list only extra_sources

---@param opts? rtfm.PickerOpts
function M.open(opts)
  opts = opts or {}
  if P then
    M.close()
  end
  P = {
    wins = {},
    bufs = {},
    matches = {},
    sel = 1,
    req = 0,
    mode = "source",
    origin_win = vim.api.nvim_get_current_win(),
    origin_buf = vim.api.nvim_get_current_buf(),
    items = opts.items or {},
    list_title = opts.title,
    on_delete = opts.on_delete,
    on_open = opts.on_open,
    locked = opts.locked,
    open_mode = opts.open_mode,
  }
  P.remote_debounced = util.debounce(config.options.ui.debounce, function(fn)
    fn()
  end)
  P.preview_debounced = util.debounce(config.options.ui.preview_debounce, load_preview)

  create_windows()
  setup_keymaps(P.bufs.prompt)

  P.augroup = vim.api.nvim_create_augroup("rtfm.picker", { clear = true })
  local prompt_buf = P.bufs.prompt
  vim.api.nvim_buf_attach(prompt_buf, false, {
    on_lines = function()
      vim.schedule(function()
        if P and P.bufs.prompt == prompt_buf and not P.setting_query then
          P.sel = 1
          run_query()
        end
      end)
      if not P or P.bufs.prompt ~= prompt_buf then
        return true -- detach
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = P.augroup,
    buffer = P.bufs.prompt,
    callback = function()
      vim.schedule(function()
        if P and vim.api.nvim_get_current_buf() ~= P.bufs.prompt then
          M.close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = P.augroup, callback = relayout })
  -- something else (a dashboard, a session plugin) wiped our buffer: close cleanly
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = P.augroup,
    buffer = P.bufs.prompt,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  vim.cmd("startinsert")

  if opts.mode == "list" then
    P.mode = "list"
    P.locked = true
    render_prompt_decor()
    set_query(opts.query)
    run_query()
    return
  elseif opts.mode == "ask" then
    P.mode = "ask"
    P.locked = true
    render_prompt_decor()
    set_query(opts.query)
    run_query()
    return
  end

  if opts.source then
    P.locked = opts.locked
    render_prompt_decor()
    set_footer("loading…")
    sources.get(opts.source, function(err, src)
      if not P then
        return
      end
      if err then
        util.warn(err)
        return M.open({ query = opts.source })
      end
      enter_search(src, opts.query)
    end)
    return
  end

  -- source mode: project deps first, then everything else
  render_prompt_decor()
  local extra = opts.extra_sources or {}
  local function merge(list)
    local seen, out = {}, {}
    for i, s in ipairs(extra) do
      s._order = i
      seen[s.id] = true
      table.insert(out, s)
    end
    for _, s in ipairs(list) do
      if not seen[s.id] then
        table.insert(out, s)
      end
    end
    return sort_sources(out)
  end
  P.sources = merge({})
  set_query(opts.query)
  if opts.sources_only then
    return run_query()
  end
  sources.list(function(list, complete)
    if not P or P.mode ~= "source" then
      if P and complete then
        P.sources = merge(list)
      end
      return
    end
    P.sources = merge(list)
    if not complete then
      set_footer("loading catalog…")
    end
    run_query()
  end)
end

function M.is_open()
  return P ~= nil
end

--- For tests.
function M._state()
  return P
end

return M
