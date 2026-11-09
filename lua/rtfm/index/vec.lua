--- Dense vector store: normalized float32 rows, brute-force cosine top-k.
--- Uses LuaJIT FFI when available (fast), plain Lua tables otherwise.
local M = {}

local has_ffi, ffi = pcall(require, "ffi")
M.has_ffi = has_ffi

local function normalize(v)
  local s = 0
  for i = 1, #v do
    s = s + v[i] * v[i]
  end
  s = math.sqrt(s)
  if s == 0 then
    return v
  end
  local out = {}
  for i = 1, #v do
    out[i] = v[i] / s
  end
  return out
end
M.normalize = normalize

---@class rtfm.VecStore
---@field dim integer
---@field n integer
---@field data any float[] (ffi) or Lua array

function M.new(dim, capacity)
  local self = { dim = dim, n = 0, cap = capacity or 1024 }
  if has_ffi then
    self.data = ffi.new("float[?]", self.cap * dim)
  else
    self.data = {}
  end
  return self
end

local function grow(self)
  local new_cap = self.cap * 2
  local nd = ffi.new("float[?]", new_cap * self.dim)
  ffi.copy(nd, self.data, self.n * self.dim * 4)
  self.data, self.cap = nd, new_cap
end

function M.add(self, v)
  assert(#v == self.dim, ("vector has dim %d, store has %d"):format(#v, self.dim))
  v = normalize(v)
  if has_ffi then
    if self.n >= self.cap then
      grow(self)
    end
    local base = self.n * self.dim
    for i = 1, self.dim do
      self.data[base + i - 1] = v[i]
    end
  else
    local base = self.n * self.dim
    for i = 1, self.dim do
      self.data[base + i] = v[i]
    end
  end
  self.n = self.n + 1
  return self.n -- 1-based row id
end

---@return {id: integer, score: number}[]
function M.search(self, q, k)
  k = k or 50
  q = normalize(q)
  local dim, data, n = self.dim, self.data, self.n
  local top = {} -- ascending by score, size <= k
  local min = -math.huge
  local qa
  if has_ffi then
    qa = ffi.new("float[?]", dim)
    for i = 1, dim do
      qa[i - 1] = q[i]
    end
  end
  for row = 0, n - 1 do
    local s = 0
    local base = row * dim
    if has_ffi then
      for i = 0, dim - 1 do
        s = s + data[base + i] * qa[i]
      end
    else
      for i = 1, dim do
        s = s + data[base + i] * q[i]
      end
    end
    if #top < k or s > min then
      -- insert keeping ascending order
      local pos = #top + 1
      while pos > 1 and top[pos - 1].score > s do
        pos = pos - 1
      end
      table.insert(top, pos, { id = row + 1, score = s })
      if #top > k then
        table.remove(top, 1)
      end
      min = top[1].score
    end
  end
  local out = {}
  for i = #top, 1, -1 do
    table.insert(out, top[i])
  end
  return out
end

--- Binary serialization: 8-byte header (dim, n as uint32) + float32 rows.
function M.dump(self)
  if has_ffi then
    local header = ffi.new("uint32_t[2]", self.dim, self.n)
    return ffi.string(header, 8) .. ffi.string(self.data, self.n * self.dim * 4)
  end
  return vim.json.encode({ dim = self.dim, n = self.n, data = self.data })
end

function M.load(str)
  if not str or #str < 8 then
    return nil
  end
  if str:sub(1, 1) == "{" then
    local d = vim.json.decode(str)
    local self = M.new(d.dim, math.max(d.n, 1))
    if has_ffi then
      for i = 1, d.n * d.dim do
        self.data[i - 1] = d.data[i]
      end
    else
      self.data = d.data
    end
    self.n = d.n
    return self
  end
  if not has_ffi then
    return nil
  end
  local header = ffi.new("uint32_t[2]")
  ffi.copy(header, str, 8)
  local dim, n = tonumber(header[0]), tonumber(header[1])
  if #str ~= 8 + dim * n * 4 then
    return nil
  end
  local self = M.new(dim, math.max(n, 1))
  ffi.copy(self.data, str:sub(9), dim * n * 4)
  self.n = n
  return self
end

--- Reciprocal rank fusion of several ranked lists of {id=...}.
function M.rrf(lists, k)
  k = k or 60
  local scores = {}
  for _, list in ipairs(lists) do
    for rank, r in ipairs(list) do
      scores[r.id] = (scores[r.id] or 0) + 1 / (k + rank)
    end
  end
  local out = {}
  for id, s in pairs(scores) do
    table.insert(out, { id = id, score = s })
  end
  table.sort(out, function(a, b)
    return a.score > b.score
  end)
  return out
end

return M
