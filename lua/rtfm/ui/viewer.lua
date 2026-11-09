--- Doc buffers: rendering pages, link following, per-window back/forward history, TOC.
local config = require("rtfm.config")
local page = require("rtfm.page")
local sources = require("rtfm.sources")
local store = require("rtfm.store")
local urllib = require("rtfm.url")
local util = require("rtfm.util")

local M = {}

local ns = vim.api.nvim_create_namespace("rtfm.viewer")

---@type table<integer, {entries: table[], idx: integer}>
M.history = {}
---@type table<integer, table> buffer -> loaded page
M.pages = {}

-- windows ---------------------------------------------------------------------------------

local function is_rtfm_buf(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.b[buf].rtfm == true
end

local function find_doc_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" and is_rtfm_buf(vim.api.nvim_win_get_buf(win)) then
      return win
    end
  end
end

local function open_float()
  local fc = config.options.viewer.float
  local width = math.floor(vim.o.columns * fc.width)
  local height = math.floor((vim.o.lines - vim.o.cmdheight) * fc.height)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = config.options.ui.border,
    style = "minimal",
  })
  vim.w[win].rtfm_float = true
  return win
end

--- Get (or create) the window a page should open in.
function M.prepare_window(mode)
  mode = mode or config.options.open
  local cur = vim.api.nvim_get_current_win()
  if mode == "buffer" then
    return cur
  elseif mode == "float" then
    if vim.w[cur].rtfm_float then
      return cur
    end
    return open_float()
  elseif mode == "tab" then
    vim.cmd("tabnew")
    local win = vim.api.nvim_get_current_win()
    vim.w[win].rtfm_created = true
    return win
  end
  -- split / vsplit: reuse a doc window in this tab if there is one
  if is_rtfm_buf(vim.api.nvim_win_get_buf(cur)) then
    return cur
  end
  local existing = find_doc_window()
  if existing then
    vim.api.nvim_set_current_win(existing)
    return existing
  end
  vim.cmd(mode == "vsplit" and "vsplit" or "split")
  local win = vim.api.nvim_get_current_win()
  vim.w[win].rtfm_created = true
  return win
end

local function apply_win_opts(win)
  for k, v in pairs(config.options.viewer.wo) do
    pcall(vim.api.nvim_set_option_value, k, v, { scope = "local", win = win })
  end
end

-- buffers ---------------------------------------------------------------------------------

local function buf_name(source, item)
  local key = page.key(source, item):gsub("^[^%z]*%z", "")
  key = key:gsub("^https?://", "")
  return "rtfm://" .. source.id .. "/" .. key
end

local function find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local setup_keymaps

local function create_buf(name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].rtfm = true
  vim.bo[buf].filetype = "markdown"
  setup_keymaps(buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      M.pages[buf] = nil
    end,
  })
  return buf
end

local function flash(buf, line)
  pcall(function()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = "RtfmFlash", end_row = line - 1 })
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      end
    end, 700)
  end)
end

function M.jump(win, buf, fragment, lnum)
  local p = M.pages[buf]
  local line = lnum or (p and page.anchor_line(p, fragment))
  if not line or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  line = math.min(line, vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  if not lnum then
    flash(buf, line)
  end
  return true
end

-- history ---------------------------------------------------------------------------------

local function hist(win)
  M.history[win] = M.history[win] or { entries = {}, idx = 0 }
  return M.history[win]
end

local function save_cursor(win)
  local h = M.history[win]
  if h and h.entries[h.idx] and vim.api.nvim_win_is_valid(win) then
    h.entries[h.idx].cursor = vim.api.nvim_win_get_cursor(win)
  end
end

local function push(win, source, item)
  local h = hist(win)
  save_cursor(win)
  for i = #h.entries, h.idx + 1, -1 do
    h.entries[i] = nil
  end
  table.insert(h.entries, { source_id = source.id, source = source, item = item })
  h.idx = #h.entries
end

-- opening -----------------------------------------------------------------------------------

---@param source table
---@param item table
---@param opts? {mode?: string, win?: integer, history?: boolean, cursor?: integer[], on_open?: fun(buf: integer, win: integer)}
function M.open(source, item, opts)
  opts = opts or {}
  local win = opts.win or M.prepare_window(opts.mode)
  if opts.history ~= false then
    push(win, source, item)
  end
  local name = buf_name(source, item)
  local buf = find_buf(name)
  local fragment = item.fragment or (item.url and urllib.fragment(item.url))

  if buf and M.pages[buf] then
    vim.api.nvim_win_set_buf(win, buf)
    apply_win_opts(win)
    if opts.cursor then
      pcall(vim.api.nvim_win_set_cursor, win, opts.cursor)
    elseif not M.jump(win, buf, fragment) then
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
    store.add_history(source.id, item, M.pages[buf].title)
    if opts.on_open then
      opts.on_open(buf, win)
    end
    return buf
  end

  buf = buf or create_buf(name)
  set_lines(buf, { "# " .. (item.title or "…"), "", "_Loading…_" })
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win)

  page.load(source, item, function(err, p)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if err then
      set_lines(buf, { "# " .. (item.title or "Error"), "", "> Could not load this page:", "> " .. err:gsub("\n", " ") })
      return
    end
    M.pages[buf] = p
    set_lines(buf, p.lines)
    vim.b[buf].rtfm_url = p.url
    vim.b[buf].rtfm_source = source.id
    store.add_history(source.id, item, p.title)
    local target_win = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and win or nil
    if target_win then
      if opts.cursor then
        pcall(vim.api.nvim_win_set_cursor, target_win, opts.cursor)
      else
        M.jump(target_win, buf, p.fragment)
      end
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "RtfmPageOpen", modeline = false, data = { buf = buf, page = p } })
    if opts.on_open then
      opts.on_open(buf, win)
    end
  end)
  return buf
end

--- Open a page by source id.
function M.open_id(source_id, item, opts)
  sources.get(source_id, function(err, source)
    if err then
      return util.error(err)
    end
    M.open(source, item, opts)
  end)
end

-- link following ----------------------------------------------------------------------------

--- Link under the cursor: markdown [text](url), <url> or a bare URL.
function M.link_at(line, col)
  col = col + 1 -- 1-based
  local init = 1
  while true do
    local s, e, url = line:find("%[[^%]]*%]%(([^%)%s]+)%)", init)
    if not s then
      break
    end
    if col >= s and col <= e then
      return url
    end
    init = e + 1
  end
  init = 1
  while true do
    local s, e = line:find("https?://[%w%-%._~:/%?#@!%$&'%*%+,;=%%]+", init)
    if not s then
      break
    end
    if col >= s and col <= e then
      return (line:sub(s, e):gsub("[%.,;:]$", ""))
    end
    init = e + 1
  end
end

local function current_page(buf)
  return M.pages[buf or vim.api.nvim_get_current_buf()]
end

function M.follow_url(href, win)
  win = win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local p = current_page(buf)
  if href:sub(1, 1) == "#" then
    save_cursor(win)
    if not M.jump(win, buf, href:sub(2)) then
      util.warn("anchor not found: " .. href)
    end
    return
  end
  if not urllib.is_http(href) then
    return util.warn("not a web link: " .. href)
  end
  local source = p and sources.get_sync(p.source_id)
  local resolved = source and sources.adapter(source.adapter).resolve and sources.adapter(source.adapter).resolve(source, href)
  local links = config.options.links
  if resolved then
    local target_id = resolved.source_id or source.id
    if target_id == "web" and links.other_site == "browser" and urllib.host(href) ~= urllib.host(p.url or "") then
      return util.open_in_browser(href)
    end
    return M.open_id(target_id, resolved.item, { win = win })
  end
  local same_site = p and urllib.host(href) == urllib.host(p.url or "")
  local policy = same_site and links.same_site or links.other_site
  if policy == "rtfm" then
    return M.open_id("web", { url = href, title = href, fragment = urllib.fragment(href) }, { win = win })
  end
  util.open_in_browser(href)
end

-- actions -----------------------------------------------------------------------------------

M.actions = {}

function M.actions.follow()
  local win = vim.api.nvim_get_current_win()
  local cur = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_get_current_line()
  local href = M.link_at(line, cur[2])
  if href then
    return M.follow_url(href, win)
  end
  -- no link: search the current source for the word under the cursor
  local p = current_page()
  local word = vim.fn.expand("<cword>")
  if p and word ~= "" then
    require("rtfm.ui.picker").open({ source = p.source_id, query = word })
  end
end

local function go(delta)
  local win = vim.api.nvim_get_current_win()
  local h = M.history[win]
  if not h or h.idx + delta < 1 or h.idx + delta > #h.entries then
    -- fall back to the regular jumplist
    local key = delta < 0 and "<C-o>" or "<C-i>"
    vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
    return
  end
  save_cursor(win)
  h.idx = h.idx + delta
  local e = h.entries[h.idx]
  M.open(e.source, e.item, { win = win, history = false, cursor = e.cursor })
end

function M.actions.back()
  go(-1)
end

function M.actions.forward()
  go(1)
end

function M.toc_items(buf)
  local items, fence = {}, false
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence then
      local hashes, text = line:match("^(#+)%s+(.+)$")
      if hashes then
        text = text:gsub("%[([^%]]*)%]%b()", "%1")
        table.insert(items, { bufnr = buf, lnum = i, col = 1, text = ("  "):rep(#hashes - 1) .. text })
      end
    end
  end
  return items
end

function M.actions.toc()
  local buf = vim.api.nvim_get_current_buf()
  local items = M.toc_items(buf)
  if #items == 0 then
    return util.notify("no headings on this page")
  end
  vim.fn.setloclist(0, {}, " ", { title = "Contents", items = items })
  vim.cmd("lopen")
end

function M.actions.browser()
  local p = current_page()
  if p then
    util.open_in_browser(p.url .. (p.fragment and ("#" .. p.fragment) or ""))
  end
end

function M.actions.yank_url()
  local p = current_page()
  if p then
    vim.fn.setreg('"', p.url)
    pcall(vim.fn.setreg, "+", p.url)
    util.notify("copied " .. p.url)
  end
end

function M.actions.bookmark()
  local p = current_page()
  if not p then
    return
  end
  vim.ui.input({ prompt = "Bookmark note (optional): " }, function(note)
    if note == nil then
      return
    end
    local added = store.add_bookmark(p.source_id, p.item, p.title, note ~= "" and note or nil)
    util.notify((added and "bookmarked " or "updated bookmark ") .. p.title)
  end)
end

function M.actions.search()
  local p = current_page()
  require("rtfm.ui.picker").open({ source = p and p.source_id })
end

function M.actions.close()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  M.history[win] = nil
  if vim.w[win].rtfm_float or (vim.w[win].rtfm_created and #vim.api.nvim_tabpage_list_wins(0) > 1) then
    vim.api.nvim_win_close(win, false)
    return
  end
  local alt = vim.fn.bufnr("#")
  if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and not is_rtfm_buf(alt) then
    vim.api.nvim_win_set_buf(win, alt)
  elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, false)
  else
    vim.cmd("enew")
  end
end

setup_keymaps = function(buf)
  for lhs, action in pairs(config.options.keymaps.viewer) do
    if action and M.actions[action] then
      vim.keymap.set("n", lhs, M.actions[action], { buffer = buf, nowait = true, desc = "rtfm: " .. action })
    elseif type(action) == "function" then
      vim.keymap.set("n", lhs, action, { buffer = buf, nowait = true })
    end
  end
end

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("rtfm.viewer", { clear = true }),
  callback = function(ev)
    M.history[tonumber(ev.match)] = nil
  end,
})

return M
