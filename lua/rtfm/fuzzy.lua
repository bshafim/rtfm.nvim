--- Fuzzy filtering on top of matchfuzzypos, with a few docs-specific boosts.
local M = {}

local function text_of(item)
  return item.search or item.title or ""
end

--- Last identifier-ish segment: "http.Client.Do()" -> "do"
local function last_segment(s)
  s = s:lower():gsub("%(.*%)$", "")
  return s:match("([^%.:/#%s]+)%s*$") or s
end

---@param items table[]
---@param query string
---@param limit? integer
---@return table[] matches each `{ item = item, positions = {...}, score = n }`
function M.filter(items, query, limit)
  limit = limit or 300
  query = vim.trim(query or "")
  if query == "" then
    local out = {}
    for i = 1, math.min(limit, #items) do
      out[i] = { item = items[i], positions = {}, score = 0 }
    end
    return out
  end

  -- matchfuzzy needs a string list; keep an index map
  local texts = {}
  for i, it in ipairs(items) do
    texts[i] = text_of(it)
  end
  local ok, res = pcall(vim.fn.matchfuzzypos, texts, query)
  if not ok then
    return {}
  end
  local matched, positions, scores = res[1], res[2], res[3]

  -- map matched text back to item indices (texts can repeat)
  local by_text = {}
  for i, t in ipairs(texts) do
    by_text[t] = by_text[t] or {}
    table.insert(by_text[t], i)
  end
  local used = {}
  local q = query:lower()
  local qlast = last_segment(q)
  local out = {}
  for i, t in ipairs(matched) do
    local idxs = by_text[t]
    local idx
    for _, cand in ipairs(idxs) do
      if not used[cand] then
        idx = cand
        used[cand] = true
        break
      end
    end
    if idx then
      local tl = t:lower()
      local score = scores[i]
      if tl == q then
        score = score + 10000
      elseif last_segment(tl) == qlast then
        score = score + 5000
      elseif tl:find(q, 1, true) == 1 then
        score = score + 2000
      elseif tl:find(q, 1, true) then
        score = score + 800
      end
      score = score - #t -- prefer shorter titles
      table.insert(out, { item = items[idx], positions = positions[i], score = score, order = i })
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.order < b.order
  end)
  if #out > limit then
    for i = #out, limit + 1, -1 do
      out[i] = nil
    end
  end
  return out
end

return M
