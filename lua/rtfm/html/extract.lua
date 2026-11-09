--- Pick the main documentation content out of a full HTML page and strip chrome.
local P = require("rtfm.html.parser")

local M = {}

-- tried in order; first one with enough text wins
M.CONTENT_SELECTORS = {
  ".Documentation-content", -- pkg.go.dev
  "#main-content", -- rustdoc
  "article.main-page-content", -- MDN
  ".theme-doc-markdown", -- docusaurus
  ".markdown-body",
  ".md-content", -- mkdocs material
  ".rst-content", -- sphinx rtd
  "div.body[role=main]", -- sphinx
  ".vp-doc", -- vitepress
  ".docs-content",
  ".documentation",
  ".content-body",
  "#content",
  "main",
  "article",
  "[role=main]",
  ".content",
}

local DROP_TAGS = {}
for t in ("nav header footer aside script style noscript svg form button iframe select input dialog canvas video audio template"):gmatch("%S+") do
  DROP_TAGS[t] = true
end

-- class/id tokens that mark chrome
local DROP_TOKENS = {
  "sidebar", "breadcrumb", "breadcrumbs", "toc", "table-of-contents", "navbar", "nav", "footer",
  "cookie", "banner", "edit-this-page", "pagination", "pagination-nav", "skip-link", "feedback",
  "headerlink", "hash-link", "anchor-link", "copy-button", "copybutton", "sr-only", "visually-hidden",
  "theme-edit-this-page", "theme-last-updated", "prev-next", "on-this-page", "page-nav", "announcement",
  "UnitDoc-nav", "Documentation-sourceHeader", "jump-to", "side-nav", "rightside", "src", "out-of-band",
  "notranslate-anchor", "doc-sidebar", "md-sidebar", "md-header", "md-footer",
  "admonition-icon", "linenos", "hideme", "doc-anchor", "Documentation-idLink",
  "Documentation-exampleButtonsContainer", "Documentation-exampleError", "UnitDirectories", "copy-item-path",
  "permalink", "header-anchor", "anchorjs-link", "heading-anchor",
}
local DROP_SET = {}
for _, t in ipairs(DROP_TOKENS) do
  DROP_SET[t:lower()] = true
end

local function is_chrome(node)
  local a = node.attrs
  if a.hidden ~= nil or a["aria-hidden"] == "true" then
    return true
  end
  if a.role == "navigation" or a.role == "search" or a.role == "banner" or a.role == "contentinfo" then
    return true
  end
  if a.style and a.style:gsub("%s", ""):find("display:none", 1, true) then
    return true
  end
  for _, key in ipairs({ "class", "id" }) do
    local v = a[key]
    if v then
      for token in v:gmatch("%S+") do
        if DROP_SET[token:lower()] then
          return true
        end
      end
    end
  end
  return false
end

local function strip(node, keep_headers)
  local children = node.children
  if not children then
    return
  end
  local i = 1
  while i <= #children do
    local c = children[i]
    local drop = false
    if c.type == "element" then
      if DROP_TAGS[c.tag] and not (keep_headers and c.tag == "header") then
        drop = true
      elseif is_chrome(c) then
        drop = true
      end
    end
    if drop then
      table.remove(children, i)
    else
      strip(c, keep_headers)
      i = i + 1
    end
  end
end

local function text_len(node)
  local n = 0
  local function rec(x)
    for _, c in ipairs(x.children or {}) do
      if c.type == "text" then
        n = n + #(c.text:gsub("%s+", ""))
      else
        rec(c)
      end
    end
  end
  rec(node)
  return n
end

function M.title(root)
  local t = P.select_one(root, "title")
  local title = t and P.clean_text(t) or nil
  local h1 = P.select_one(root, "h1")
  local h1_text = h1 and P.clean_text(h1) or nil
  if h1_text and h1_text ~= "" and #h1_text < 120 then
    return h1_text
  end
  if title and title ~= "" then
    -- "Fetch API - Web APIs | MDN" -> "Fetch API"
    return (title:gsub("%s+[|·–—-]%s+.*$", ""))
  end
  return nil
end

--- Returns the content node (mutated in place: chrome removed) and the page title.
---@param root table parsed document
---@param opts? {selector?: string}
function M.extract(root, opts)
  opts = opts or {}
  strip(root, true)
  local title = M.title(root)
  local content
  if opts.selector then
    content = P.select_one(root, opts.selector)
  end
  if not content then
    for _, sel in ipairs(M.CONTENT_SELECTORS) do
      local node = P.select_one(root, sel)
      if node and text_len(node) > 200 then
        content = node
        break
      end
    end
  end
  content = content or P.select_one(root, "body") or root
  return content, title
end

return M
