-- Prefetch everything the demos open, so the recordings don't wait on the network.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
require("rtfm").setup({})
local sources, page = require("rtfm.sources"), require("rtfm.page")
local function wait(fn)
  local done
  fn(function() done = true end)
  vim.wait(60000, function() return done end, 20)
end
wait(function(cb) require("rtfm.adapters.devdocs").catalog(cb) end)
local targets = {
  { "gopkg:std@go1.25.1", { url = "https://pkg.go.dev/net/http@go1.25.1", import_path = "net/http" } },
  { "gopkg:golang.org/x/sync@v0.17.0", { url = "https://pkg.go.dev/golang.org/x/sync@v0.17.0/errgroup", import_path = "golang.org/x/sync/errgroup" } },
}
for _, t in ipairs(targets) do
  local src
  wait(function(cb) sources.get(t[1], function(_, s) src = s; cb() end) end)
  wait(function(cb) require("rtfm.search").load(src, cb) end)
  wait(function(cb) page.load(src, t[2], cb) end)
end
wait(function(cb) require("rtfm.project").sources(0, cb) end)
print("caches warm")
