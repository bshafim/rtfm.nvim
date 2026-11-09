--- Render a parsed HTML tree as Markdown lines (+ an anchor -> line map).
local P = require("rtfm.html.parser")
local urllib = require("rtfm.url")

local M = {}

local BLOCK = {}
for t in (
  "address article aside blockquote body center dd details dialog dir div dl dt fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr html li main menu nav ol p pre section summary table tbody td tfoot th thead tr ul #root"
):gmatch("%S+") do
  BLOCK[t] = true
end

local ADMONITION = {}
for t in ("admonition note notecard warning tip caution danger important info callout alert hint attention seealso deprecated versionadded versionchanged"):gmatch("%S+") do
  ADMONITION[t] = true
end

local NBSP = "\194\160"

--- Strip trailing permalink glyphs from heading text ("Foo ¶", "Bar #").
local function strip_permalink(s)
  s = vim.trim(s)
  for _ = 1, 2 do
    s = s:gsub("%s*¶$", ""):gsub("%s*🔗$", ""):gsub("%s+#$", ""):gsub("^§%s*", "")
  end
  return vim.trim(s)
end

local function norm_space(s)
  return (s:gsub(NBSP, " "):gsub("%s+", " "))
end

--- GitHub-style heading slug.
function M.slug(text)
  local s = text:lower():gsub("`", "")
  s = s:gsub("%[([^%]]*)%]%b()", "%1")
  s = s:gsub("[^%w%s%-_\128-\255]", ""):gsub("%s", "-")
  return s
end

-- context -------------------------------------------------------------------------------

local function new_ctx(parent)
  return {
    lines = {},
    anchors = {},
    pending = {},
    base = parent and parent.base,
    page = parent and parent.page,
    resolve = parent and parent.resolve,
  }
end

local function add_ids(ctx, el)
  local a = el.attrs
  if a.id and a.id ~= "" then
    table.insert(ctx.pending, a.id)
  end
  if el.tag == "a" and a.name and a.name ~= "" then
    table.insert(ctx.pending, a.name)
  end
end

local function emit(ctx, line)
  if #ctx.pending > 0 and line ~= "" then
    for _, id in ipairs(ctx.pending) do
      if ctx.anchors[id] == nil then
        ctx.anchors[id] = #ctx.lines + 1
      end
    end
    ctx.pending = {}
  end
  table.insert(ctx.lines, line)
end

local function blank(ctx)
  local n = #ctx.lines
  if n > 0 and ctx.lines[n] ~= "" then
    table.insert(ctx.lines, "")
  end
end

--- Merge a sub-context's lines into ctx with prefixes.
local function merge(ctx, sub, first_prefix, rest_prefix)
  local offset = #ctx.lines
  local first = true
  for i, line in ipairs(sub.lines) do
    local prefix = first and first_prefix or rest_prefix
    if line == "" and not first then
      local p = rest_prefix:gsub("%s+$", "")
      table.insert(ctx.lines, p)
    else
      table.insert(ctx.lines, prefix .. line)
    end
    first = false
    for id, l in pairs(sub.anchors) do
      if l == i and ctx.anchors[id] == nil then
        ctx.anchors[id] = offset + i
      end
    end
  end
  for _, id in ipairs(sub.pending) do
    table.insert(ctx.pending, id)
  end
end

local function trim_blank_edges(lines)
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
end

-- inline --------------------------------------------------------------------------------

local inline

local function wrap_marker(inner, marker)
  local lead, body, trail = inner:match("^(%s*)(.-)(%s*)$")
  if body == "" then
    return inner
  end
  return lead .. marker .. body .. marker .. trail
end

local function code_span(text)
  text = norm_space(text)
  if text:match("^%s*$") then
    return text
  end
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local ticks = ("`"):rep(longest + 1)
  local pad = (text:sub(1, 1) == "`" or text:sub(-1) == "`") and " " or ""
  return ticks .. pad .. text .. pad .. ticks
end

local function resolve_href(ctx, href)
  href = vim.trim(href)
  if href == "" or href:match("^javascript:") then
    return nil
  end
  if href:sub(1, 1) == "#" then
    return href
  end
  if ctx.resolve then
    local r = ctx.resolve(href)
    if r then
      return r
    end
  end
  local abs = ctx.base and urllib.join(ctx.base, href) or href
  if ctx.page and urllib.strip_fragment(abs) == ctx.page then
    local frag = urllib.fragment(abs)
    if frag then
      return "#" .. frag
    end
  end
  return abs
end

local function encode_link(u)
  return (u:gsub(" ", "%%20"):gsub("%(", "%%28"):gsub("%)", "%%29"))
end

local function inline_children(el, ctx, opts)
  local buf = {}
  for _, c in ipairs(el.children) do
    table.insert(buf, inline(c, ctx, opts))
  end
  return table.concat(buf)
end

inline = function(node, ctx, opts)
  if node.type == "text" then
    return norm_space(node.text)
  end
  local tag = node.tag
  add_ids(ctx, node)
  if tag == "br" then
    return "\n"
  elseif tag == "img" or tag == "wbr" then
    return ""
  elseif tag == "code" or tag == "kbd" or tag == "samp" or tag == "tt" then
    if opts.in_code then
      return P.text(node)
    end
    -- links inside code (pkg.go.dev, rustdoc): keep the link, code-format the text
    local link = (#node.children == 1 and node.children[1].tag == "a") and node.children[1] or nil
    if link and link.attrs.href and not opts.no_links then
      local target = resolve_href(ctx, link.attrs.href)
      if target then
        return "[" .. code_span(P.text(link)) .. "](" .. encode_link(target) .. ")"
      end
    end
    return code_span(P.text(node))
  elseif tag == "a" then
    local text = inline_children(node, ctx, opts)
    local href = node.attrs.href
    if opts.no_links or not href or text:match("^%s*$") or text:find("\n") then
      return text
    end
    local target = resolve_href(ctx, href)
    if not target then
      return text
    end
    local lead, body, trail = text:match("^(%s*)(.-)(%s*)$")
    return lead .. "[" .. body .. "](" .. encode_link(target) .. ")" .. trail
  elseif tag == "strong" or tag == "b" then
    return wrap_marker(inline_children(node, ctx, opts), "**")
  elseif tag == "em" or tag == "i" or tag == "cite" or tag == "dfn" or tag == "var" then
    local inner = inline_children(node, ctx, opts)
    if inner:find("^%s*%*%*") then
      return inner
    end
    return wrap_marker(inner, "*")
  elseif tag == "del" or tag == "s" or tag == "strike" then
    return wrap_marker(inline_children(node, ctx, opts), "~~")
  elseif tag == "pre" then
    return code_span(P.text(node))
  end
  local inner = inline_children(node, ctx, opts)
  if BLOCK[tag] then
    return " " .. inner .. " "
  end
  return inner
end

-- blocks --------------------------------------------------------------------------------

local blocks

local function render_sub(el, ctx)
  local sub = new_ctx(ctx)
  blocks(el, sub)
  trim_blank_edges(sub.lines)
  return sub
end

local function flush(ctx, buf)
  if #buf == 0 then
    return
  end
  local text = table.concat(buf)
  for i = #buf, 1, -1 do
    buf[i] = nil
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = vim.trim(line:gsub(" +", " "))
    if line ~= "" then
      table.insert(lines, line)
    end
  end
  if #lines == 0 then
    return
  end
  blank(ctx)
  for i, line in ipairs(lines) do
    -- hard line breaks inside a paragraph
    emit(ctx, line .. (i < #lines and "  " or ""))
  end
  blank(ctx)
end

local function class_tokens(el)
  local out = {}
  for t in (el.attrs.class or ""):gmatch("%S+") do
    out[#out + 1] = t
  end
  return out
end

local function code_lang(el)
  local node, depth = el, 0
  local first_code
  for _, c in ipairs(el.children) do
    if c.type == "element" and c.tag == "code" then
      first_code = c
      break
    end
  end
  local candidates = { el }
  if first_code then
    table.insert(candidates, 1, first_code)
  end
  while node and node.attrs and depth < 3 do
    if node ~= el then
      table.insert(candidates, node)
    end
    node = node.parent
    depth = depth + 1
  end
  for _, n in ipairs(candidates) do
    if n and n.attrs then
      local a = n.attrs
      local dl = a["data-language"] or a["data-lang"]
      if dl and dl ~= "" then
        return dl:lower()
      end
      for _, t in ipairs(class_tokens(n)) do
        local lang = t:match("^language%-([%w_+#-]+)$")
          or t:match("^lang%-([%w_+#-]+)$")
          or t:match("^highlight%-source%-([%w_+#-]+)$")
          or t:match("^highlight%-([%w_+#-]+)$")
          or t:match("^brush:([%w_+#-]+)$")
        if lang and lang ~= "default" and lang ~= "none" and lang ~= "text" then
          return lang:lower()
        end
      end
      if n.tag == "pre" and n.attrs.class and n.attrs.class:find("rust", 1, true) then
        return "rust"
      end
    end
  end
  return ""
end

local LANG_ALIAS = { js = "javascript", ts = "typescript", py = "python", py3 = "python", python3 = "python", sh = "bash", shell = "bash", console = "bash", golang = "go", rs = "rust", ["c++"] = "cpp", yml = "yaml", pycon = "python" }

local function pre_block(el, ctx)
  add_ids(ctx, el)
  local text = P.text(el):gsub(NBSP, " "):gsub("\r\n?", "\n")
  text = text:gsub("^\n", ""):gsub("%s+$", "")
  if text == "" then
    return
  end
  local lang = code_lang(el)
  lang = LANG_ALIAS[lang] or lang
  local fence = text:find("```", 1, true) and "~~~~" or "```"
  blank(ctx)
  emit(ctx, fence .. lang)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(ctx.lines, (line:gsub("%s+$", "")))
  end
  table.insert(ctx.lines, fence)
  blank(ctx)
end

local function heading(el, ctx, level)
  add_ids(ctx, el)
  local text = inline_children(el, ctx, { no_links = true })
  text = strip_permalink(norm_space(text))
  if text == "" then
    return
  end
  blank(ctx)
  emit(ctx, ("#"):rep(level) .. " " .. text)
  blank(ctx)
  local slug = M.slug(text)
  if slug ~= "" and ctx.anchors[slug] == nil then
    ctx.anchors[slug] = #ctx.lines - 1
  end
end

--- Remove blank lines outside code fences (tight list items).
local function tighten(lines)
  local out, fence = {}, nil
  for _, l in ipairs(lines) do
    local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f
      elseif l:match("^%s*" .. vim.pesc(fence) .. "%s*$") then
        fence = nil
      end
    end
    if l ~= "" or fence then
      table.insert(out, l)
    end
  end
  return out
end

local function list_block(el, ctx, ordered)
  add_ids(ctx, el)
  local n = tonumber(el.attrs.start) or 1
  blank(ctx)
  for _, li in ipairs(el.children) do
    if li.type == "element" then
      local sub = render_sub(li, ctx)
      if li.tag == "li" then
        add_ids(sub, li)
      end
      local has_p = false
      for _, c in ipairs(li.children) do
        if c.type == "element" and (c.tag == "p" or c.tag == "pre" or c.tag == "div") then
          has_p = true
        end
      end
      if not has_p then
        local remap = {}
        local new = tighten(sub.lines)
        -- recompute anchors after tightening (map old non-blank lines to new indices)
        local j = 0
        for i, l in ipairs(sub.lines) do
          if l ~= "" then
            j = j + 1
            remap[i] = j
          end
        end
        for id, l in pairs(sub.anchors) do
          sub.anchors[id] = remap[l] or 1
        end
        sub.lines = new
      end
      local only_list = sub.lines[1] and (sub.lines[1]:match("^[-*] ") or sub.lines[1]:match("^%d+%. "))
      if only_list then
        merge(ctx, sub, "", "")
      elseif #sub.lines > 0 then
        local marker = ordered and (n .. ". ") or "- "
        merge(ctx, sub, marker, (" "):rep(#marker))
        n = n + 1
        if has_p then
          blank(ctx)
        end
      end
    elseif li.type == "text" and not li.text:match("^%s*$") then
      emit(ctx, "- " .. vim.trim(norm_space(li.text)))
    end
  end
  blank(ctx)
end

local function table_rows(tbl)
  local rows = {}
  local function collect(node)
    for _, c in ipairs(node.children) do
      if c.type == "element" then
        if c.tag == "tr" then
          table.insert(rows, c)
        elseif c.tag == "thead" or c.tag == "tbody" or c.tag == "tfoot" then
          collect(c)
        end
      end
    end
  end
  collect(tbl)
  return rows
end

local function is_complex_cell(cell)
  return P.select_one(cell, "pre") ~= nil or P.select_one(cell, "table") ~= nil or P.select_one(cell, "ul") ~= nil
end

local function table_block(el, ctx)
  add_ids(ctx, el)
  local rows = table_rows(el)
  if #rows == 0 then
    return blocks(el, ctx)
  end
  local grid, ncols, complex, has_th = {}, 0, false, false
  for ri, tr in ipairs(rows) do
    local cells = {}
    for _, cell in ipairs(tr.children) do
      if cell.type == "element" and (cell.tag == "td" or cell.tag == "th") then
        if is_complex_cell(cell) then
          complex = true
        end
        if cell.tag == "th" and ri == 1 then
          has_th = true
        end
        add_ids(ctx, cell)
        local text = inline_children(cell, ctx, {}):gsub("\n", " ")
        text = vim.trim(norm_space(text)):gsub("|", "\\|")
        table.insert(cells, text)
        for _ = 2, tonumber(cell.attrs.colspan) or 1 do
          table.insert(cells, "")
        end
      end
    end
    ncols = math.max(ncols, #cells)
    table.insert(grid, cells)
  end
  if complex or ncols == 0 then
    -- layout-ish table: render cell contents as blocks
    for _, tr in ipairs(rows) do
      for _, cell in ipairs(tr.children) do
        if cell.type == "element" then
          blocks(cell, ctx)
        end
      end
    end
    return
  end
  if ncols == 1 and not has_th then
    for _, cells in ipairs(grid) do
      if cells[1] ~= "" then
        blank(ctx)
        emit(ctx, cells[1])
      end
    end
    blank(ctx)
    return
  end
  local widths = {}
  for c = 1, ncols do
    widths[c] = 3
    for _, row in ipairs(grid) do
      local w = vim.fn.strdisplaywidth(row[c] or "")
      widths[c] = math.min(math.max(widths[c], w), 40)
    end
  end
  local function fmt(row)
    local parts = {}
    for c = 1, ncols do
      local cell = row[c] or ""
      local pad = widths[c] - vim.fn.strdisplaywidth(cell)
      parts[c] = cell .. (pad > 0 and (" "):rep(pad) or "")
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end
  blank(ctx)
  emit(ctx, fmt(grid[1]))
  local sep = {}
  for c = 1, ncols do
    sep[c] = ("-"):rep(widths[c])
  end
  emit(ctx, "| " .. table.concat(sep, " | ") .. " |")
  for i = 2, #grid do
    emit(ctx, fmt(grid[i]))
  end
  blank(ctx)
end

local function dl_block(el, ctx)
  add_ids(ctx, el)
  blank(ctx)
  for _, c in ipairs(el.children) do
    if c.type == "element" and c.tag == "dt" then
      add_ids(ctx, c)
      local text = strip_permalink(norm_space(inline_children(c, ctx, { no_links = true })))
      if text ~= "" then
        blank(ctx)
        local cls = c.attrs.class or ""
        if c.attrs.id and (cls:find("sig", 1, true)) then
          -- Sphinx API signature: make it a heading so it shows up in the TOC
          emit(ctx, "#### " .. code_span((text:gsub("`", ""))))
          blank(ctx)
        else
          emit(ctx, "**" .. text:gsub("%*%*", "") .. "**")
          blank(ctx)
        end
      end
    elseif c.type == "element" and c.tag == "dd" then
      local sub = render_sub(c, ctx)
      add_ids(sub, c)
      if #sub.lines > 0 then
        merge(ctx, sub, "  ", "  ")
        blank(ctx)
      end
    elseif c.type == "element" then
      blocks({ type = "element", tag = "div", attrs = {}, children = { c } }, ctx)
    end
  end
  blank(ctx)
end

local function is_admonition(el)
  if el.tag ~= "div" and el.tag ~= "aside" and el.tag ~= "section" then
    return false
  end
  for _, t in ipairs(class_tokens(el)) do
    if ADMONITION[t:lower()] then
      return true
    end
  end
  return false
end

local function quote_block(el, ctx)
  add_ids(ctx, el)
  local sub = render_sub(el, ctx)
  if #sub.lines == 0 then
    return
  end
  blank(ctx)
  merge(ctx, sub, "> ", "> ")
  blank(ctx)
end

local function block(el, ctx)
  local tag = el.tag
  local level = tag:match("^h(%d)$")
  if level then
    return heading(el, ctx, tonumber(level))
  elseif tag == "pre" then
    return pre_block(el, ctx)
  elseif tag == "ul" or tag == "menu" or tag == "dir" then
    return list_block(el, ctx, false)
  elseif tag == "ol" then
    return list_block(el, ctx, true)
  elseif tag == "table" then
    return table_block(el, ctx)
  elseif tag == "dl" then
    return dl_block(el, ctx)
  elseif tag == "blockquote" or is_admonition(el) then
    return quote_block(el, ctx)
  elseif tag == "hr" then
    blank(ctx)
    emit(ctx, "---")
    blank(ctx)
    return
  elseif tag == "summary" then
    local text = vim.trim(norm_space(inline_children(el, ctx, {})))
    if text ~= "" then
      blank(ctx)
      emit(ctx, "**" .. text .. "**")
      blank(ctx)
    end
    return
  end
  add_ids(ctx, el)
  blocks(el, ctx)
end

blocks = function(node, ctx)
  local buf = {}
  for _, c in ipairs(node.children or {}) do
    if c.type == "text" then
      table.insert(buf, norm_space(c.text))
    elseif BLOCK[c.tag] then
      flush(ctx, buf)
      block(c, ctx)
    else
      table.insert(buf, inline(c, ctx, {}))
    end
  end
  flush(ctx, buf)
end

-- public --------------------------------------------------------------------------------

--- Collapse blank runs and trailing whitespace outside of code fences.
--- Returns the new lines and a map old index -> new index.
local function finalize(lines)
  local out, map, fence = {}, {}, nil
  for i, l in ipairs(lines) do
    local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f
      elseif vim.trim(l) == fence then
        fence = nil
      end
    end
    if not fence then
      l = l:gsub("%s+$", "")
    end
    if l == "" and not fence and (#out == 0 or out[#out] == "") then
      map[i] = #out + 1
    else
      table.insert(out, l)
      map[i] = #out
    end
  end
  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end
  return out, map
end

local function remap_anchors(anchors, map, n)
  local res = {}
  for id, l in pairs(anchors) do
    res[id] = math.min(map[l] or 1, math.max(n, 1))
  end
  return res
end

---@class rtfm.Rendered
---@field lines string[]
---@field anchors table<string, integer>
---@field title? string

--- Render an element subtree to markdown.
---@param node table
---@param opts? {base?: string, title?: string, resolve?: fun(href: string): string|nil}
---@return rtfm.Rendered
function M.render(node, opts)
  opts = opts or {}
  local ctx = new_ctx()
  ctx.base = opts.base
  ctx.page = opts.base and urllib.strip_fragment(opts.base)
  ctx.resolve = opts.resolve
  if BLOCK[node.tag] or node.type == "root" then
    blocks(node, ctx)
  else
    block(node, ctx)
  end
  local out, map = finalize(ctx.lines)
  local anchors = remap_anchors(ctx.anchors, map, #out)
  local res = { lines = out, anchors = anchors }
  M.ensure_title(res, opts.title)
  return res
end

--- Prepend "# title" when the page doesn't start with a heading.
function M.ensure_title(res, title)
  if not title or title == "" then
    return
  end
  for i = 1, math.min(#res.lines, 6) do
    if res.lines[i]:match("^#%s") then
      return
    end
  end
  table.insert(res.lines, 1, "")
  table.insert(res.lines, 1, "# " .. title)
  for id, l in pairs(res.anchors) do
    res.anchors[id] = l + 2
  end
end

--- Turn an existing markdown document into a rendered page (absolute links + heading anchors).
---@param md string
---@param opts? {base?: string, title?: string, resolve?: fun(href: string): string|nil}
function M.from_markdown(md, opts)
  opts = opts or {}
  local page = opts.base and urllib.strip_fragment(opts.base)
  local lines, anchors, fence = {}, {}, nil
  for line in (md:gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n") do
    local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f
      elseif vim.trim(line) == fence then
        fence = nil
      end
    end
    if not fence then
      line = line:gsub("(%]%()([^%)%s]+)(%))", function(open, href, close)
        local target = href
        if href:sub(1, 1) ~= "#" then
          target = (opts.resolve and opts.resolve(href)) or (opts.base and urllib.join(opts.base, href)) or href
          if page and urllib.strip_fragment(target) == page and urllib.fragment(target) then
            target = "#" .. urllib.fragment(target)
          end
        end
        return open .. target .. close
      end)
      local text = line:match("^#+%s+(.-)%s*#*$")
      if text then
        local slug = M.slug(text)
        if anchors[slug] == nil then
          anchors[slug] = #lines + 1
        end
      end
      local id = line:match('<a%s+[^>]*name="([^"]+)"') or line:match('<a%s+[^>]*id="([^"]+)"')
      if id then
        anchors[id] = #lines + 1
      end
    end
    table.insert(lines, line)
  end
  local out, map = finalize(lines)
  local res = { lines = out, anchors = remap_anchors(anchors, map, #out) }
  M.ensure_title(res, opts.title)
  return res
end

return M
