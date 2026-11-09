--- Split a rendered markdown page into heading-scoped chunks for indexing.
local M = {}

local function approx_tokens(s)
  local words = select(2, s:gsub("%S+", ""))
  return math.floor(words * 1.3)
end
M.approx_tokens = approx_tokens

local function clean(line)
  -- drop link targets, keep link text
  line = line:gsub("%[([^%]]*)%]%b()", "%1")
  line = line:gsub("[*_`]+", "")
  return line
end

---@param lines string[] rendered markdown
---@param anchors table<string, integer> anchor id -> line
---@param opts? {max_tokens?: integer, title?: string}
---@return {heading: string, fragment: string|nil, text: string, line: integer}[]
function M.chunk(lines, anchors, opts)
  opts = opts or {}
  local max_tokens = opts.max_tokens or 300
  -- line -> best anchor id (prefer non-slug, i.e. real ids)
  local line_anchor = {}
  for id, l in pairs(anchors or {}) do
    local cur = line_anchor[l]
    if not cur or (#id < #cur) then
      line_anchor[l] = id
    end
  end

  local chunks = {}
  local stack = {} -- heading texts by level
  local buf, buf_tokens, start_line = {}, 0, 1
  local link_lines, text_lines = 0, 0
  local fragment = nil
  local in_fence = false

  local function heading_path()
    local parts = {}
    for lvl = 1, 6 do
      if stack[lvl] then
        table.insert(parts, stack[lvl])
      end
    end
    if #parts == 0 and opts.title then
      parts = { opts.title }
    end
    return table.concat(parts, " › ")
  end

  local function flush()
    local text = vim.trim(table.concat(buf, "\n"))
    -- skip navigation-like sections (lists of links: "Index", "See also", ...)
    local navigational = text_lines > 2 and link_lines / text_lines > 0.6
    link_lines, text_lines = 0, 0
    if text ~= "" and approx_tokens(text) >= 8 and not navigational then
      table.insert(chunks, { heading = heading_path(), fragment = fragment, text = text, line = start_line })
    end
    buf, buf_tokens = {}, 0
  end

  for i, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_fence = not in_fence
    end
    local hashes, htext = nil, nil
    if not in_fence then
      hashes, htext = line:match("^(#+)%s+(.+)$")
    end
    if hashes then
      flush()
      local lvl = math.min(#hashes, 6)
      stack[lvl] = clean(htext)
      for l = lvl + 1, 6 do
        stack[l] = nil
      end
      fragment = line_anchor[i] or fragment
      if lvl == 1 then
        -- the page title: open at the top, no fragment needed
        fragment = i > 3 and line_anchor[i] or nil
      end
      start_line = i
    else
      local t = approx_tokens(line)
      if buf_tokens + t > max_tokens and buf_tokens > max_tokens / 3 and not in_fence then
        flush()
        start_line = i
      end
      if line ~= "" and not in_fence then
        text_lines = text_lines + 1
        local stripped = line:gsub("%[[^%]]*%]%b()", ""):gsub("^%s*[-*%d%.]+%s*", "")
        if line:find("](", 1, true) and not stripped:match("%w%w%w") then
          link_lines = link_lines + 1
        end
      end
      local is_fence = line:match("^%s*```") or line:match("^%s*~~~")
      if not is_fence and (line ~= "" or #buf > 0) then
        table.insert(buf, clean(line))
        buf_tokens = buf_tokens + t
      end
    end
  end
  flush()
  return chunks
end

return M
