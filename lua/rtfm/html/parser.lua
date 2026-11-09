--- A small, forgiving HTML parser that builds a DOM-ish tree.
--- Not spec-complete; it's tuned for documentation pages.
---
--- Node shapes:
---   element: { type = "element", tag = "div", attrs = {...}, children = {...}, parent = node }
---   text:    { type = "text", text = "...", parent = node }
local M = {}

local VOID = {}
for t in ("area base br col embed hr img input link meta param source track wbr"):gmatch("%S+") do
  VOID[t] = true
end

-- content is skipped entirely
local SKIP_RAW = { script = true, style = true, template = true, noscript = false }
-- content is kept as plain text
local KEEP_RAW = { textarea = true, title = true, xmp = true }

local INLINE = {}
for t in ("a abbr b bdi bdo cite code data dfn em i kbd mark q s samp small span strong sub sup time u var wbr font"):gmatch("%S+") do
  INLINE[t] = true
end

local CLOSES_P = {}
for t in (
  "address article aside blockquote details dialog div dl fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr main menu nav ol p pre section table ul"
):gmatch("%S+") do
  CLOSES_P[t] = true
end

-- opening key closes an open value element, but not past a boundary element
local IMPLIED = {
  li = { close = { li = true }, boundary = { ul = true, ol = true, menu = true } },
  dt = { close = { dt = true, dd = true }, boundary = { dl = true } },
  dd = { close = { dt = true, dd = true }, boundary = { dl = true } },
  tr = { close = { tr = true, td = true, th = true }, boundary = { table = true, thead = true, tbody = true, tfoot = true } },
  td = { close = { td = true, th = true }, boundary = { tr = true, table = true } },
  th = { close = { td = true, th = true }, boundary = { tr = true, table = true } },
  thead = { close = { thead = true, tbody = true, tfoot = true, tr = true, td = true, th = true }, boundary = { table = true } },
  tbody = { close = { thead = true, tbody = true, tfoot = true, tr = true, td = true, th = true }, boundary = { table = true } },
  tfoot = { close = { thead = true, tbody = true, tfoot = true, tr = true, td = true, th = true }, boundary = { table = true } },
  option = { close = { option = true }, boundary = { select = true, datalist = true } },
}

M.ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ensp = " ", emsp = " ", thinsp = " ",
  copy = "©", reg = "®", trade = "™", hellip = "…", mdash = "—", ndash = "–", lsquo = "‘", rsquo = "’",
  ldquo = "“", rdquo = "”", sbquo = "‚", bdquo = "„", bull = "•", middot = "·", times = "×", divide = "÷",
  larr = "←", rarr = "→", uarr = "↑", darr = "↓", harr = "↔", lArr = "⇐", rArr = "⇒", hArr = "⇔",
  laquo = "«", raquo = "»", para = "¶", sect = "§", deg = "°", plusmn = "±", micro = "µ", le = "≤",
  ge = "≥", ne = "≠", asymp = "≈", infin = "∞", minus = "−", prime = "′", Prime = "″", dagger = "†",
  Dagger = "‡", permil = "‰", euro = "€", pound = "£", yen = "¥", cent = "¢", zwj = "", zwnj = "",
  lrm = "", rlm = "", shy = "", check = "✓", cross = "✗", star = "☆", hearts = "♥", lambda = "λ",
  alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ε", pi = "π", sigma = "σ", mu = "μ",
  theta = "θ", omega = "ω", Delta = "Δ", Sigma = "Σ", Omega = "Ω", sum = "∑", prod = "∏", radic = "√",
  isin = "∈", notin = "∉", cap = "∩", cup = "∪", sub = "⊂", sup = "⊃", and_ = "∧", forall = "∀",
  exist = "∃", empty = "∅", nabla = "∇", part = "∂", int = "∫", there4 = "∴", sim = "∼", equiv = "≡",
  lowast = "∗", oplus = "⊕", otimes = "⊗", perp = "⊥", sdot = "⋅", lceil = "⌈", rceil = "⌉",
  lfloor = "⌊", rfloor = "⌋", lang = "⟨", rang = "⟩", loz = "◊", spades = "♠", clubs = "♣", diams = "♦",
  iexcl = "¡", iquest = "¿", ordf = "ª", ordm = "º", sup1 = "¹", sup2 = "²", sup3 = "³", frac14 = "¼",
  frac12 = "½", frac34 = "¾", acute = "´", cedil = "¸", uml = "¨", macr = "¯", not_ = "¬", brvbar = "¦",
  curren = "¤", Tab = "\t", NewLine = "\n", grave = "`", lsqb = "[", rsqb = "]", lcub = "{", rcub = "}",
  verbar = "|", vert = "|", lowbar = "_", ast = "*", num = "#", excl = "!", colon = ":", semi = ";",
  comma = ",", period = ".", sol = "/", bsol = "\\", Hat = "^", dollar = "$", percnt = "%", equals = "=",
  plus = "+", quest = "?", commat = "@", lpar = "(", rpar = ")",
}
M.ENTITIES["and"] = "∧"
M.ENTITIES["not"] = "¬"

local function utf8_char(cp)
  if cp < 0 or cp > 0x10FFFF then
    return "�"
  end
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end
M.utf8_char = utf8_char

function M.decode_entities(s)
  if not s:find("&", 1, true) then
    return s
  end
  s = s:gsub("&#[xX](%x+);?", function(h)
    return utf8_char(tonumber(h, 16))
  end)
  s = s:gsub("&#(%d+);?", function(d)
    return utf8_char(tonumber(d))
  end)
  s = s:gsub("&(%a[%w]*);", function(name)
    return M.ENTITIES[name] or ("&" .. name .. ";")
  end)
  return s
end

local function new_el(tag, attrs, parent)
  return { type = "element", tag = tag, attrs = attrs, children = {}, parent = parent }
end

local function parse_attrs(html, pos)
  -- returns attrs, position after '>', self_closing
  local attrs = {}
  local len = #html
  while pos <= len do
    local s, e = html:find("^[%s]+", pos)
    if s then
      pos = e + 1
    end
    local c = html:sub(pos, pos)
    if c == ">" then
      return attrs, pos + 1, false
    elseif c == "/" then
      if html:sub(pos + 1, pos + 1) == ">" then
        return attrs, pos + 2, true
      end
      pos = pos + 1
    elseif c == "" then
      return attrs, len + 1, false
    else
      local name_s, name_e = html:find("^[^%s=/>]+", pos)
      if not name_s then
        pos = pos + 1
      else
        local name = html:sub(name_s, name_e):lower()
        pos = name_e + 1
        local eq_s, eq_e = html:find("^%s*=%s*", pos)
        local value = ""
        if eq_s then
          pos = eq_e + 1
          local q = html:sub(pos, pos)
          if q == '"' or q == "'" then
            local close = html:find(q, pos + 1, true)
            if not close then
              close = len + 1
            end
            value = html:sub(pos + 1, close - 1)
            pos = close + 1
          else
            local vs, ve = html:find("^[^%s>]+", pos)
            if vs then
              value = html:sub(vs, ve)
              pos = ve + 1
            end
          end
        end
        if attrs[name] == nil then
          attrs[name] = M.decode_entities(value)
        end
      end
    end
  end
  return attrs, pos, false
end

---@param html string
---@return table root
function M.parse(html)
  local root = { type = "root", tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  local lower -- lazily computed lowercase copy for raw-text end searches
  local len = #html
  local pos = 1

  local function top()
    return stack[#stack]
  end

  local function add_text(s)
    if s == "" then
      return
    end
    local parent = top()
    local last = parent.children[#parent.children]
    local text = M.decode_entities(s)
    if last and last.type == "text" then
      last.text = last.text .. text
    else
      table.insert(parent.children, { type = "text", text = text, parent = parent })
    end
  end

  local function pop_to(idx)
    for i = #stack, idx, -1 do
      stack[i] = nil
    end
  end

  local function close_tag(name)
    for i = #stack, 2, -1 do
      if stack[i].tag == name then
        pop_to(i)
        return
      end
    end
  end

  local function implied_close(tag)
    if CLOSES_P[tag] then
      -- close an open <p>, skipping over inline ancestors
      for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "p" then
          pop_to(i)
          break
        elseif not INLINE[t] then
          break
        end
      end
    end
    local rule = IMPLIED[tag]
    if rule then
      for i = #stack, 2, -1 do
        local t = stack[i].tag
        if rule.boundary[t] then
          break
        end
        if rule.close[t] then
          pop_to(i)
          break
        end
      end
    end
  end

  while pos <= len do
    local lt = html:find("<", pos, true)
    if not lt then
      add_text(html:sub(pos))
      break
    end
    if lt > pos then
      add_text(html:sub(pos, lt - 1))
    end
    local nextc = html:sub(lt + 1, lt + 1)
    if html:sub(lt, lt + 3) == "<!--" then
      local e = html:find("-->", lt + 4, true)
      pos = e and e + 3 or len + 1
    elseif nextc == "!" or nextc == "?" then
      if html:sub(lt, lt + 8) == "<![CDATA[" then
        local e = html:find("]]>", lt + 9, true)
        add_text(html:sub(lt + 9, (e or len + 1) - 1))
        pos = e and e + 3 or len + 1
      else
        local e = html:find(">", lt, true)
        pos = e and e + 1 or len + 1
      end
    elseif nextc == "/" then
      local s, e, name = html:find("^</%s*([%w:-]+)[^>]*>", lt)
      if s then
        close_tag(name:lower())
        pos = e + 1
      else
        add_text("<")
        pos = lt + 1
      end
    elseif nextc:match("%a") then
      local _, name_e, name = html:find("^<([%w:-]+)", lt)
      local tag = name:lower()
      local attrs, after, self_closing = parse_attrs(html, name_e + 1)
      pos = after
      if SKIP_RAW[tag] or KEEP_RAW[tag] then
        lower = lower or html:lower()
        local cs = lower:find("</" .. tag, pos, true)
        local content = html:sub(pos, (cs or len + 1) - 1)
        if KEEP_RAW[tag] then
          local el = new_el(tag, attrs, top())
          table.insert(top().children, el)
          table.insert(el.children, { type = "text", text = M.decode_entities(content), parent = el })
        end
        if cs then
          local ce = html:find(">", cs, true)
          pos = ce and ce + 1 or len + 1
        else
          pos = len + 1
        end
      else
        implied_close(tag)
        local parent = top()
        local el = new_el(tag, attrs, parent)
        table.insert(parent.children, el)
        if not VOID[tag] and not self_closing then
          table.insert(stack, el)
        end
      end
    else
      add_text("<")
      pos = lt + 1
    end
  end
  return root
end

-- DOM helpers ------------------------------------------------------------------------------

function M.has_class(node, cls)
  local c = node.attrs and node.attrs.class
  if not c then
    return false
  end
  for token in c:gmatch("%S+") do
    if token == cls then
      return true
    end
  end
  return false
end

--- Compile a simple compound selector: tag, .class, #id, [attr], [attr=value], combined
--- (e.g. "div.SearchSnippet", "a[href]", "#main-content"). Descendant combinators are
--- supported with spaces ("div.foo a").
local function compile_one(sel)
  local tag = sel:match("^([%w%-]+)")
  local id = sel:match("#([%w%-_:]+)")
  local classes = {}
  for c in sel:gmatch("%.([%w%-_]+)") do
    table.insert(classes, c)
  end
  local attrs = {}
  for name, op, val in sel:gmatch("%[([%w%-_:]+)([%^%*%$~]?=?)[\"']?([^%]\"']*)[\"']?%]") do
    table.insert(attrs, { name = name, op = op, val = val })
  end
  return function(node)
    if node.type ~= "element" then
      return false
    end
    if tag and tag ~= "*" and node.tag ~= tag then
      return false
    end
    if id and node.attrs.id ~= id then
      return false
    end
    for _, c in ipairs(classes) do
      if not M.has_class(node, c) then
        return false
      end
    end
    for _, a in ipairs(attrs) do
      local v = node.attrs[a.name]
      if v == nil then
        return false
      end
      if a.op == "=" and v ~= a.val then
        return false
      elseif a.op == "^=" and v:sub(1, #a.val) ~= a.val then
        return false
      elseif a.op == "*=" and not v:find(a.val, 1, true) then
        return false
      elseif a.op == "$=" and v:sub(-#a.val) ~= a.val then
        return false
      end
    end
    return true
  end
end

local selector_cache = {}
local function compile(sel)
  if type(sel) == "function" then
    return { sel }
  end
  if not selector_cache[sel] then
    local parts = {}
    for part in sel:gmatch("%S+") do
      table.insert(parts, compile_one(part))
    end
    selector_cache[sel] = parts
  end
  return selector_cache[sel]
end

local function walk(node, fn)
  local children = node.children
  if not children then
    return
  end
  for i = 1, #children do
    local child = children[i]
    if child.type == "element" then
      if fn(child) == false then
        return false
      end
      if walk(child, fn) == false then
        return false
      end
    end
  end
end
M.walk = walk

local function select_parts(roots, parts, idx, out, seen, first_only)
  local pred = parts[idx]
  for _, root in ipairs(roots) do
    local stop = walk(root, function(n)
      if pred(n) then
        if idx == #parts then
          if not seen[n] then
            seen[n] = true
            table.insert(out, n)
            if first_only then
              return false
            end
          end
        else
          if select_parts({ n }, parts, idx + 1, out, seen, first_only) == false then
            return false
          end
        end
      end
    end)
    if stop == false then
      return false
    end
  end
end

function M.select(root, sel)
  local out = {}
  select_parts({ root }, compile(sel), 1, out, {}, false)
  return out
end

function M.select_one(root, sel)
  local out = {}
  select_parts({ root }, compile(sel), 1, out, {}, true)
  return out[1]
end

function M.text(node)
  if node.type == "text" then
    return node.text
  end
  local buf = {}
  local function rec(n)
    for _, c in ipairs(n.children or {}) do
      if c.type == "text" then
        table.insert(buf, c.text)
      elseif c.tag == "br" then
        table.insert(buf, "\n")
      else
        rec(c)
      end
    end
  end
  rec(node)
  return table.concat(buf)
end

function M.clean_text(node)
  return (M.text(node):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function M.remove(node)
  local parent = node.parent
  if not parent then
    return
  end
  for i, c in ipairs(parent.children) do
    if c == node then
      table.remove(parent.children, i)
      break
    end
  end
  node.parent = nil
end

local function escape_attr(v)
  return (v:gsub("&", "&amp;"):gsub('"', "&quot;"))
end
local function escape_text(v)
  return (v:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- Serialize back to HTML (used for the pandoc converter).
function M.to_html(node)
  local buf = {}
  local function rec(n)
    if n.type == "text" then
      table.insert(buf, escape_text(n.text))
      return
    end
    if n.type == "element" then
      table.insert(buf, "<" .. n.tag)
      for k, v in pairs(n.attrs) do
        table.insert(buf, " " .. k .. '="' .. escape_attr(v) .. '"')
      end
      table.insert(buf, ">")
      if VOID[n.tag] then
        return
      end
    end
    for _, c in ipairs(n.children or {}) do
      rec(c)
    end
    if n.type == "element" then
      table.insert(buf, "</" .. n.tag .. ">")
    end
  end
  rec(node)
  return table.concat(buf)
end

M.INLINE = INLINE

return M
