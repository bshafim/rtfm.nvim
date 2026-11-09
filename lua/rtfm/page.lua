--- Fetch → convert → render pipeline for doc pages.
local config = require("rtfm.config")
local util = require("rtfm.util")
local urllib = require("rtfm.url")

local M = {}

local mem = util.lru(64)

function M.key(source, item)
  local adapter = require("rtfm.sources").adapter(source.adapter)
  local k = adapter.page_key and adapter.page_key(source, item) or item.url or item.path
  return source.id .. "\0" .. tostring(k)
end

--- Raw page: installed copy first, then the adapter (network/cache).
function M.raw(source, item, cb)
  local sources = require("rtfm.sources")
  local adapter = sources.adapter(source.adapter)
  local offline = require("rtfm.offline")
  if offline.is_installed(source) and not adapter.install then
    local key = adapter.page_key and adapter.page_key(source, item) or item.url
    local raw = offline.read_page(source, key)
    if raw then
      return vim.schedule(function()
        cb(nil, raw)
      end)
    end
  end
  return adapter.fetch(source, item, cb)
end

local function use_pandoc()
  local c = config.options.html.converter
  if c == "pandoc" then
    return true
  end
  return c == "auto" and vim.fn.executable("pandoc") == 1
end

--- Convert raw content to markdown lines + anchors.
---@param cb fun(err: string|nil, rendered: rtfm.Rendered|nil)
function M.render(raw, cb)
  local md = require("rtfm.html.markdown")
  if raw.markdown then
    return cb(nil, md.from_markdown(raw.markdown, { base = raw.base, title = raw.title }))
  end
  local P = require("rtfm.html.parser")
  local ok, root = pcall(P.parse, raw.html or "")
  if not ok then
    return cb("could not parse page: " .. tostring(root))
  end
  local node, title = root, raw.title
  if raw.extract ~= false then
    local found_title
    node, found_title = require("rtfm.html.extract").extract(root, { selector = raw.selector })
    title = found_title or title
  end
  if use_pandoc() then
    local html = P.to_html(node)
    vim.system({ "pandoc", "-f", "html", "-t", "gfm-raw_html", "--wrap=none" }, { text = true, stdin = html }, function(out)
      vim.schedule(function()
        if out.code ~= 0 then
          -- fall back to the builtin converter
          return cb(nil, md.render(node, { base = raw.base, title = title, lang = raw.lang }))
        end
        cb(nil, md.from_markdown(out.stdout, { base = raw.base, title = title }))
      end)
    end)
    return
  end
  local rok, res = pcall(md.render, node, { base = raw.base, title = title, lang = raw.lang })
  if not rok then
    return cb("could not render page: " .. tostring(res))
  end
  cb(nil, res)
end

---@class rtfm.Page
---@field source_id string
---@field item table
---@field title string
---@field url string
---@field lines string[]
---@field anchors table<string, integer>
---@field fragment? string

--- Load a page for display.
---@param cb fun(err: string|nil, page: rtfm.Page|nil)
function M.load(source, item, cb, opts)
  opts = opts or {}
  local key = M.key(source, item)
  local fragment = item.fragment or (item.url and urllib.fragment(item.url))
  local hit = not opts.refresh and mem.get(key)
  if hit then
    local page = vim.tbl_extend("force", hit, { item = item, fragment = fragment })
    return vim.schedule(function()
      cb(nil, page)
    end)
  end
  return M.raw(source, item, function(err, raw)
    if err then
      return cb(err)
    end
    M.render(raw, function(rerr, rendered)
      if rerr then
        return cb(rerr)
      end
      local title = rendered.lines[1] and rendered.lines[1]:match("^#%s+(.+)$") or item.title or raw.url
      local page = {
        source_id = source.id,
        item = item,
        title = title,
        url = raw.url or item.url,
        lines = rendered.lines,
        anchors = rendered.anchors,
        fragment = fragment,
      }
      mem.set(key, page)
      cb(nil, page)
    end)
  end)
end

function M.clear()
  mem.clear()
end

--- Line for a fragment: exact anchor, slug, or a heading that mentions it.
function M.anchor_line(page, fragment)
  if not fragment or fragment == "" then
    return nil
  end
  fragment = urllib.decode(fragment)
  if page.anchors[fragment] then
    return page.anchors[fragment]
  end
  local slug = require("rtfm.html.markdown").slug(fragment)
  if page.anchors[slug] then
    return page.anchors[slug]
  end
  local needle = fragment:lower():gsub("[-_]", " ")
  for i, line in ipairs(page.lines) do
    if line:match("^#+%s") and line:lower():gsub("[-_]", " "):find(needle, 1, true) then
      return i
    end
  end
  return nil
end

return M
