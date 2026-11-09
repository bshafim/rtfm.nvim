local bm25 = require("rtfm.index.bm25")
local chunk = require("rtfm.index.chunk")
local vec = require("rtfm.index.vec")

describe("chunker", function()
  it("splits by heading and keeps the heading path", function()
    local lines = {
      "# context",
      "",
      "Package context carries deadlines and cancellation signals across API boundaries.",
      "",
      "## func WithTimeout",
      "",
      "WithTimeout returns a copy of the parent context that is cancelled after the timeout elapses.",
      "```go",
      "ctx, cancel := context.WithTimeout(ctx, time.Second)",
      "```",
    }
    local chunks = chunk.chunk(lines, { WithTimeout = 5 }, { title = "context" })
    eq(2, #chunks)
    eq("context", chunks[1].heading)
    eq("context › func WithTimeout", chunks[2].heading)
    eq("WithTimeout", chunks[2].fragment)
    contains(chunks[2].text, "context.WithTimeout(ctx")
  end)

  it("skips link-only navigation sections", function()
    local lines = { "## Index", "- [func A](#A)", "- [func B](#B)", "- [func C](#C)", "- [type D](#D)" }
    eq(0, #chunk.chunk(lines, {}))
  end)

  it("splits long sections", function()
    local lines = { "# big" }
    for i = 1, 60 do
      lines[#lines + 1] = ("word "):rep(20) .. i
    end
    ok(#chunk.chunk(lines, {}, { max_tokens = 100 }) > 5)
  end)
end)

describe("bm25", function()
  it("tokenizes camelCase and snake_case", function()
    local toks = bm25.tokenize("WithTimeout read_to_string")
    ok(vim.tbl_contains(toks, "withtimeout"))
    ok(vim.tbl_contains(toks, "timeout"))
    ok(vim.tbl_contains(toks, "string"))
  end)

  it("ranks relevant chunks first and survives serialization", function()
    local idx = bm25.new()
    bm25.add(idx, 1, "Sort a slice using a custom less function")
    bm25.add(idx, 2, "WithTimeout cancels the context after a timeout")
    bm25.add(idx, 3, "Read lines from a file with a scanner")
    local r = bm25.search(idx, "cancel after timeout")
    eq(2, r[1].id)
    local round = bm25.deserialize(vim.json.decode(vim.json.encode(bm25.serialize(idx))))
    eq(3, bm25.search(round, "read file lines")[1].id)
  end)
end)

describe("vectors", function()
  it("finds nearest neighbours by cosine", function()
    local s = vec.new(3, 2)
    vec.add(s, { 1, 0, 0 })
    vec.add(s, { 0, 1, 0 })
    vec.add(s, { 0.9, 0.1, 0 })
    local r = vec.search(s, { 1, 0.05, 0 }, 2)
    eq(2, #r)
    eq(1, r[1].id)
    eq(3, r[2].id)
  end)

  it("round-trips the binary format", function()
    local s = vec.new(4)
    for i = 1, 10 do
      vec.add(s, { i, 1, 0, -i })
    end
    local back = vec.load(vec.dump(s))
    eq(10, back.n)
    eq(4, back.dim)
    eq(vec.search(s, { 3, 1, 0, -3 }, 1)[1].id, vec.search(back, { 3, 1, 0, -3 }, 1)[1].id)
  end)

  it("fuses rankings with RRF", function()
    local fused = vec.rrf({ { { id = 1 }, { id = 2 }, { id = 3 } }, { { id = 3 }, { id = 1 } } })
    eq(1, fused[1].id)
    eq(3, fused[2].id)
  end)
end)

describe("hybrid search", function()
  it("builds an index from installed pages and searches it", function()
    local offline = require("rtfm.offline")
    local index = require("rtfm.index")
    local util = require("rtfm.util")
    local source = { id = "test-docs", name = "Test docs", adapter = "sitemap", url = "https://t.example/sitemap.xml" }
    local dir = offline.dir(source)
    vim.fn.mkdir(dir .. "/pages", "p")
    local pages = {
      ["https://t.example/timeouts"] = "<main><h1>Timeouts</h1><p>" .. ("Use a deadline to cancel slow requests after a timeout. "):rep(5) .. "</p></main>",
      ["https://t.example/sorting"] = "<main><h1>Sorting</h1><p>" .. ("Sort slices with a custom comparison function. "):rep(5) .. "</p></main>",
    }
    local idx = {}
    for u, html in pairs(pages) do
      local file = vim.fn.sha256(u):sub(1, 24) .. ".json"
      util.write_json(dir .. "/pages/" .. file, { html = html, url = u, base = u, item = { url = u, title = u } })
      idx[u] = { file = file }
    end
    util.write_json(dir .. "/pages.json", idx)
    util.write_json(dir .. "/manifest.json", { id = source.id, name = source.name, pages = 2, source = source })
    require("rtfm.config").options.index.embed.provider = false
    local err, meta = await(function(cb)
      index.build(source, {}, cb)
    end)
    eq(nil, err)
    eq(2, meta.chunks)
    local serr, matches = await(function(cb)
      index.search(source, "cancel slow request", cb)
    end)
    eq(nil, serr)
    eq("Timeouts", matches[1].item.title)
    eq("https://t.example/timeouts", matches[1].item.url)
    require("rtfm.config").options.index.embed.provider = "ollama"
  end)
end)
