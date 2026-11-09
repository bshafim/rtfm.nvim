--- Okapi BM25 over chunks. Pure Lua, serialisable to JSON.
local M = {}

local K1, B = 1.2, 0.75

local STOP = {}
for w in (
  "a an and are as at be by for from has have if in into is it its of on or that the this to was were will with you your can how do does what when which why i we"
):gmatch("%S+") do
  STOP[w] = true
end

--- Tokens: lowercase words, plus camelCase / snake_case parts ("WithTimeout" -> withtimeout, with, timeout).
function M.tokenize(text)
  local out = {}
  for word in text:gmatch("[%w_]+") do
    local lw = word:lower()
    if #lw > 1 and not STOP[lw] and #lw < 40 then
      table.insert(out, lw)
    end
    local parts = 0
    local split = {}
    for part in word:gsub("(%l)(%u)", "%1 %2"):gsub("_", " "):gmatch("%S+") do
      parts = parts + 1
      split[parts] = part:lower()
    end
    if parts > 1 then
      for _, p in ipairs(split) do
        if #p > 1 and not STOP[p] then
          table.insert(out, p)
        end
      end
    end
  end
  return out
end

function M.new()
  return { n = 0, total_len = 0, dl = {}, df = {}, postings = {} }
end

--- Add a document (chunk) with numeric id.
function M.add(idx, id, text)
  local tokens = M.tokenize(text)
  local tf = {}
  for _, t in ipairs(tokens) do
    tf[t] = (tf[t] or 0) + 1
  end
  idx.n = idx.n + 1
  idx.dl[id] = #tokens
  idx.total_len = idx.total_len + #tokens
  for t, c in pairs(tf) do
    idx.df[t] = (idx.df[t] or 0) + 1
    local p = idx.postings[t]
    if not p then
      p = { {}, {} }
      idx.postings[t] = p
    end
    table.insert(p[1], id)
    table.insert(p[2], c)
  end
end

---@return {id: integer, score: number}[]
function M.search(idx, query, k)
  k = k or 50
  if idx.n == 0 then
    return {}
  end
  local avgdl = idx.total_len / idx.n
  local scores = {}
  local seen_terms = {}
  for _, t in ipairs(M.tokenize(query)) do
    local p = idx.postings[t]
    if p and not seen_terms[t] then
      seen_terms[t] = true
      local df = idx.df[t]
      local idf = math.log(1 + (idx.n - df + 0.5) / (df + 0.5))
      local ids, tfs = p[1], p[2]
      for i = 1, #ids do
        local id, tf = ids[i], tfs[i]
        local dl = idx.dl[id] or avgdl
        local s = idf * (tf * (K1 + 1)) / (tf + K1 * (1 - B + B * dl / avgdl))
        scores[id] = (scores[id] or 0) + s
      end
    end
  end
  local out = {}
  for id, s in pairs(scores) do
    table.insert(out, { id = id, score = s })
  end
  table.sort(out, function(a, b)
    return a.score > b.score
  end)
  for i = #out, k + 1, -1 do
    out[i] = nil
  end
  return out
end

--- JSON can't have integer-keyed sparse maps reliably; store dl as an array.
function M.serialize(idx)
  local dl = {}
  for id, l in pairs(idx.dl) do
    dl[id] = l
  end
  return { n = idx.n, total_len = idx.total_len, dl = dl, df = idx.df, postings = idx.postings }
end

function M.deserialize(data)
  return { n = data.n, total_len = data.total_len, dl = data.dl or {}, df = data.df or {}, postings = data.postings or {} }
end

return M
