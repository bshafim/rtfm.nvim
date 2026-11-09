-- Smoke test against the real endpoints: nvim --headless -u NONE -l tests/live.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local tmp = vim.fn.tempname()
vim.env.XDG_DATA_HOME, vim.env.XDG_CACHE_HOME = tmp .. "/data", tmp .. "/cache"
require("rtfm").setup({})

local sources, search, page = require("rtfm.sources"), require("rtfm.search"), require("rtfm.page")
local failed = 0

local function wait(fn)
  local res
  fn(function(...)
    res = { ... }
  end)
  vim.wait(60000, function()
    return res ~= nil
  end, 20)
  return unpack(res or { "timeout" })
end

local function check(id, query, expect)
  local err, src = wait(function(cb)
    sources.get(id, cb)
  end)
  if err then
    failed = failed + 1
    return print("FAIL " .. id .. ": " .. err)
  end
  local qerr, matches = wait(function(cb)
    search.query(src, query, cb, 10)
  end)
  if qerr or not matches or not matches[1] then
    failed = failed + 1
    return print(("FAIL %s %q: %s"):format(id, query, qerr or "no results"))
  end
  local hit
  for _, m in ipairs(matches) do
    if (m.item.title or ""):find(expect, 1, true) then
      hit = m
      break
    end
  end
  if not hit then
    failed = failed + 1
    return print(("FAIL %s %q: %q not in top 10 (got %s)"):format(id, query, expect, matches[1].item.title))
  end
  local perr, p = wait(function(cb)
    page.load(src, hit.item, cb)
  end)
  if perr or #p.lines < 5 then
    failed = failed + 1
    return print(("FAIL %s page: %s"):format(id, perr or "empty page"))
  end
  print(("ok   %-34s %-28q → %s (%d lines)"):format(id, query, hit.item.title, #p.lines))
end

check("go", "WithCancel", "context.WithCancel")
check("python", "json.dumps", "json.dumps")
check("gopkg", "errgroup", "errgroup")
check("gopkg:std@go1.22.0", "net/http", "net/http")
check("docsrs", "serde", "serde")
check("docsrs:serde@1.0.200", "Deserialize", "Deserialize")
check("github", "actions cache", "cache")
check("mdn", "fetch", "Fetch")
check("docker-docs", "compose build", "Build")

vim.fn.delete(tmp, "rf")
print(failed == 0 and "all live checks passed" or (failed .. " live checks failed"))
os.exit(failed == 0 and 0 or 1)
