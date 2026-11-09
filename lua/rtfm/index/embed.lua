--- Embeddings from a local model server (Ollama or any OpenAI-compatible endpoint).
local config = require("rtfm.config")
local http = require("rtfm.http")

local M = {}

local function opts()
  return config.options.index.embed
end

function M.enabled()
  local o = opts()
  return o and o.provider ~= false and o.provider ~= nil
end

function M.model_id()
  local o = opts()
  return ("%s:%s"):format(o.provider, o.model)
end

local function base_url()
  local o = opts()
  if o.url then
    return (o.url:gsub("/$", ""))
  end
  return o.provider == "ollama" and "http://localhost:11434" or "http://localhost:8080/v1"
end

--- Embed a list of strings. cb(err, vectors)
function M.embed(texts, cb)
  local o = opts()
  if not M.enabled() then
    return vim.schedule(function()
      cb("embeddings are disabled (index.embed.provider = false)")
    end)
  end
  if o.provider == "ollama" then
    return http.post_json(base_url() .. "/api/embed", { model = o.model, input = texts, truncate = true }, function(err, data)
      if err then
        return cb(err)
      end
      if data.error then
        return cb("ollama: " .. tostring(data.error))
      end
      if type(data.embeddings) ~= "table" or #data.embeddings ~= #texts then
        return cb("ollama returned no embeddings")
      end
      cb(nil, data.embeddings)
    end, { force = true, timeout = 300 })
  elseif o.provider == "openai" then
    local headers = {}
    if o.api_key then
      headers.Authorization = "Bearer " .. o.api_key
    end
    return http.post_json(base_url() .. "/embeddings", { model = o.model, input = texts }, function(err, data)
      if err then
        return cb(err)
      end
      local out = {}
      for _, d in ipairs((data or {}).data or {}) do
        out[(d.index or #out) + 1] = d.embedding
      end
      if #out ~= #texts then
        return cb("embedding server returned " .. #out .. " vectors for " .. #texts .. " inputs")
      end
      cb(nil, out)
    end, { force = true, timeout = 300, headers = headers })
  end
  vim.schedule(function()
    cb("unknown embedding provider " .. tostring(o.provider))
  end)
end

local function too_long(err)
  return err and (err:find("context length", 1, true) or err:find("too long", 1, true) or err:find("maximum context", 1, true))
end

--- Embed for indexing: clips inputs, and when the server rejects a batch for length,
--- retries each input on its own, shrinking it until the model accepts it.
function M.embed_robust(texts, cb)
  local max = opts().max_chars or 1000
  local clipped = {}
  for i, t in ipairs(texts) do
    clipped[i] = #t > max and t:sub(1, max) or t
  end
  M.embed(clipped, function(err, vecs)
    if not err or not too_long(err) then
      return cb(err, vecs)
    end
    local out, i = {}, 0
    local function next_one()
      i = i + 1
      if i > #clipped then
        return cb(nil, out)
      end
      local text = clipped[i]
      local function attempt()
        M.embed({ text }, function(e, v)
          if not e then
            out[i] = v[1]
            return next_one()
          end
          if too_long(e) and #text > 40 then
            text = text:sub(1, math.floor(#text * 0.6))
            return attempt()
          end
          cb(e)
        end)
      end
      attempt()
    end
    next_one()
  end)
end

--- Is the model server reachable? cb(ok, err)
function M.check(cb)
  M.embed({ "ping" }, function(err, vecs)
    if err then
      local hint = opts().provider == "ollama"
          and ((" (is Ollama running? try `ollama serve` and `ollama pull %s`)"):format(opts().model))
        or ""
      return cb(false, err .. hint)
    end
    cb(true, nil, #vecs[1])
  end)
end

local query_cache = require("rtfm.util").lru(64)

function M.embed_query(text, cb)
  local key = M.model_id() .. "\0" .. text
  local hit = query_cache.get(key)
  if hit then
    return vim.schedule(function()
      cb(nil, hit)
    end)
  end
  M.embed({ text }, function(err, vecs)
    if err then
      return cb(err)
    end
    query_cache.set(key, vecs[1])
    cb(nil, vecs[1])
  end)
end

return M
