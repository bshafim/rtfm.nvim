--- Local semantic search: chunk installed docs, BM25 + embeddings, hybrid retrieval.
---
--- Files per source under stdpath("data")/rtfm/index/<source>/:
---   meta.json     { id, name, chunks, model?, dim?, embedded, built_at, version }
---   chunks.json   [ { h = heading path, t = page title, s = snippet, i = item } ]
---   bm25.json     serialized BM25 index
---   vectors.f32   float32 rows (header: dim, n)
local bm25 = require("rtfm.index.bm25")
local chunker = require("rtfm.index.chunk")
local config = require("rtfm.config")
local embed = require("rtfm.index.embed")
local util = require("rtfm.util")
local vec = require("rtfm.index.vec")

local M = {}

M.VERSION = 1

local function safe(id)
  return (id:gsub("[^%w%._~@-]", "_"))
end

function M.dir(source)
  return util.data_dir("index") .. "/" .. safe(type(source) == "table" and source.id or source)
end

local meta_mem, loaded_mem = {}, {}

function M.status(source)
  if not source then
    return nil
  end
  local d = M.dir(source)
  if meta_mem[d] == nil then
    local m = util.read_json(d .. "/meta.json")
    meta_mem[d] = (m and m.version == M.VERSION) and m or false
  end
  return meta_mem[d] or nil
end

function M.forget(source)
  local d = M.dir(source)
  meta_mem[d], loaded_mem[d] = nil, nil
  vim.fn.delete(d, "rf")
end

function M.list()
  local root = util.data_dir("index")
  local out = {}
  for name, typ in vim.fs.dir(root) do
    if typ == "directory" then
      local m = util.read_json(root .. "/" .. name .. "/meta.json")
      if m and m.version == M.VERSION then
        table.insert(out, m)
      end
    end
  end
  return out
end

local function load(source)
  local d = M.dir(source)
  if loaded_mem[d] then
    return loaded_mem[d]
  end
  local meta = M.status(source)
  if not meta then
    return nil
  end
  local chunks = util.read_json(d .. "/chunks.json")
  local b = util.read_json(d .. "/bm25.json")
  if not chunks or not b then
    return nil
  end
  local vs = meta.embedded and meta.embedded > 0 and vec.load(util.read_file(d .. "/vectors.f32")) or nil
  loaded_mem[d] = { meta = meta, chunks = chunks, bm25 = bm25.deserialize(b), vec = vs }
  return loaded_mem[d]
end

-- building -----------------------------------------------------------------------------------

local function item_for(source, key, raw, fragment)
  local item
  if source.adapter == "devdocs" then
    local dd = require("rtfm.adapters.devdocs")
    item = { page = key, path = key .. (fragment and ("#" .. fragment) or ""), url = dd.web_url(source, key) }
  else
    item = vim.deepcopy(raw.item or {})
    item.url = (raw.url or item.url or key)
  end
  if fragment then
    item.fragment = fragment
    item.url = require("rtfm.url").strip_fragment(item.url) .. "#" .. fragment
  end
  return item
end

local function render_sync(raw)
  local md = require("rtfm.html.markdown")
  if raw.markdown then
    return md.from_markdown(raw.markdown, { base = raw.base, title = raw.title })
  end
  local P = require("rtfm.html.parser")
  local root = P.parse(raw.html or "")
  local node, title = root, raw.title
  if raw.extract ~= false then
    local t
    node, t = require("rtfm.html.extract").extract(root, { selector = raw.selector })
    title = t or title
  end
  return md.render(node, { base = raw.base, title = title })
end

local building = {}

--- Build (or rebuild) the index for an installed source.
---@param opts? {on_progress?: fun(msg: string), embed?: boolean}
---@param cb? fun(err: string|nil, meta: table|nil)
function M.build(source, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  local progress = opts.on_progress or function() end
  local offline = require("rtfm.offline")
  if building[source.id] then
    return cb("already indexing " .. source.id)
  end
  if not offline.is_installed(source) then
    return cb(source.id .. " is not installed; run :Rtfm install " .. source.id .. " first")
  end

  -- collect pages (cheap: just references)
  local pages = {}
  offline.each_page(source, function(key, raw)
    table.insert(pages, { key = key, raw = raw })
  end)
  if #pages == 0 then
    return cb("no pages found for " .. source.id)
  end
  building[source.id] = true

  local chunks, idx = {}, bm25.new()
  local max_tokens = config.options.index.chunk_tokens
  local i = 0
  local BATCH = 15

  local function done(err, meta)
    building[source.id] = nil
    cb(err, meta)
  end

  local function save(meta, store)
    local d = M.dir(source)
    vim.fn.mkdir(d, "p")
    util.write_json(d .. "/chunks.json", chunks)
    util.write_json(d .. "/bm25.json", bm25.serialize(idx))
    if store then
      util.write_file(d .. "/vectors.f32", vec.dump(store))
    end
    util.write_json(d .. "/meta.json", meta)
    meta_mem[d], loaded_mem[d] = nil, nil
  end

  local function embed_all(meta)
    local want = opts.embed ~= false and embed.enabled()
    if not want then
      save(meta)
      return done(nil, meta)
    end
    embed.check(function(ok, err, dim)
      if not ok then
        save(meta)
        util.warn("built a keyword-only index (no embeddings): " .. err)
        return done(nil, meta)
      end
      local store = vec.new(dim, #chunks)
      local batch = config.options.index.embed.batch
      local pos = 1
      local started = vim.uv.hrtime()
      local function next_batch()
        if pos > #chunks then
          meta.model, meta.dim, meta.embedded = embed.model_id(), dim, store.n
          save(meta, store)
          return done(nil, meta)
        end
        local texts = {}
        for j = pos, math.min(pos + batch - 1, #chunks) do
          local c = chunks[j]
          texts[#texts + 1] = (c.h ~= "" and (c.h .. "\n") or "") .. c._text
        end
        embed.embed_robust(texts, function(eerr, vecs)
          if eerr then
            -- keep what we have: BM25 still works
            meta.model, meta.dim, meta.embedded = embed.model_id(), dim, 0
            save(meta)
            return done("embedding failed after " .. (pos - 1) .. " chunks: " .. eerr)
          end
          for _, v in ipairs(vecs) do
            vec.add(store, v)
          end
          pos = pos + #vecs
          local elapsed = (vim.uv.hrtime() - started) / 1e9
          local rate = (pos - 1) / math.max(elapsed, 0.001)
          local eta = math.floor((#chunks - pos + 1) / math.max(rate, 0.001))
          progress(("embedding %d/%d chunks (~%ds left)"):format(pos - 1, #chunks, eta))
          next_batch()
        end)
      end
      next_batch()
    end)
  end

  local function step()
    local stop = math.min(i + BATCH, #pages)
    for j = i + 1, stop do
      local pg = pages[j]
      local ok, rendered = pcall(render_sync, pg.raw)
      if ok and rendered then
        local title = (rendered.lines[1] or ""):match("^#%s+(.+)$") or pg.key
        for _, c in ipairs(chunker.chunk(rendered.lines, rendered.anchors, { max_tokens = max_tokens, title = title })) do
          local id = #chunks + 1
          local snippet = c.text:gsub("%s+", " "):sub(1, 200)
          chunks[id] = {
            h = c.heading,
            t = title,
            s = snippet,
            i = item_for(source, pg.key, pg.raw, c.fragment),
            _text = c.text,
          }
          bm25.add(idx, id, c.heading .. "\n" .. c.text)
        end
      end
    end
    i = stop
    progress(("chunking %d/%d pages"):format(i, #pages))
    if i < #pages then
      return vim.schedule(step)
    end
    local meta = {
      version = M.VERSION,
      id = source.id,
      name = source.name,
      source = source,
      chunks = #chunks,
      pages = #pages,
      embedded = 0,
      built_at = os.time(),
    }
    -- texts are only needed for embedding; drop them before saving chunks.json
    local function strip_texts()
      for _, c in ipairs(chunks) do
        c._text = nil
      end
    end
    local orig_save = save
    save = function(m, s)
      strip_texts()
      orig_save(m, s)
    end
    embed_all(meta)
  end
  vim.schedule(step)
end

-- querying -----------------------------------------------------------------------------------

local function to_matches(source, data, ranked, limit)
  local out, seen_page = {}, {}
  for _, r in ipairs(ranked) do
    local c = data.chunks[r.id]
    if c then
      local key = (c.i.page or require("rtfm.url").strip_fragment(c.i.url or "")) .. "\0" .. (c.i.fragment or "")
      if not seen_page[key] then
        seen_page[key] = true
        local item = vim.deepcopy(c.i)
        local last = c.h:match("([^›]+)$")
        item.title = last and vim.trim(last) or c.t
        item.kind = c.t ~= item.title and c.t or nil
        item.detail = c.s
        table.insert(out, { item = item, positions = {}, score = r.score, semantic = true })
        if #out >= limit then
          break
        end
      end
    end
  end
  return out
end

--- Hybrid search in one source. cb(err, matches)
function M.search(source, query, cb, opts)
  opts = opts or {}
  local data = load(source)
  if not data then
    return vim.schedule(function()
      cb("no index for " .. source.id)
    end)
  end
  local k = config.options.index.top_k
  local lexical = bm25.search(data.bm25, query, k)
  local function finish(dense)
    local ranked = dense and vec.rrf({ dense, lexical }) or lexical
    cb(nil, to_matches(source, data, ranked, opts.limit or 40), { lexical = lexical, dense = dense })
  end
  if not data.vec or not embed.enabled() or data.meta.model ~= embed.model_id() then
    return vim.schedule(function()
      finish(nil)
    end)
  end
  embed.embed_query(query, function(err, qv)
    if err or #qv ~= data.vec.dim then
      return finish(nil)
    end
    finish(vec.search(data.vec, qv, k))
  end)
end

--- Search every indexed source and merge the results.
function M.search_all(query, cb)
  local metas = M.list()
  if #metas == 0 then
    return vim.schedule(function()
      cb("nothing is indexed yet — try :Rtfm index project or :Rtfm index <source>")
    end)
  end
  local results = {}
  util.parallel(metas, 4, function(meta, done)
    local source = meta.source or { id = meta.id, name = meta.name }
    M.search(source, query, function(err, matches)
      if not err then
        for rank, m in ipairs(matches) do
          m.item._source_id = source.id
          m.item._source_name = source.name
          m.rank = rank
          table.insert(results, m)
        end
      end
      done()
    end, { limit = 20 })
  end, nil, function()
    -- interleave by per-source rank, then by score
    table.sort(results, function(a, b)
      if a.rank ~= b.rank then
        return a.rank < b.rank
      end
      return a.score > b.score
    end)
    cb(nil, results)
  end)
end

return M
