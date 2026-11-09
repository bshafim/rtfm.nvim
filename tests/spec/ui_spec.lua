-- Drives the picker and viewer headlessly with a fake, network-free adapter.
vim.o.columns, vim.o.lines = 160, 45

local PAGES = {
  ["fake://docs/alpha"] = "<h1>Alpha</h1><p>Alpha intro.</p><h2 id='details'>Details</h2><p>See <a href='fake://docs/beta#usage'>beta usage</a>.</p>",
  ["fake://docs/beta"] = "<h1>Beta</h1><p>Beta intro.</p>" .. ("<p>filler</p>"):rep(40) .. "<h2 id='usage'>Usage</h2><p>Use it.</p>",
}

package.loaded["rtfm.adapters.fake"] = {
  mode = "local",
  load = function(_, cb)
    vim.schedule(function()
      cb(nil, {
        { title = "alpha", kind = "page", url = "fake://docs/alpha" },
        { title = "alpha details", kind = "section", url = "fake://docs/alpha#details", fragment = "details" },
        { title = "beta", kind = "page", url = "fake://docs/beta" },
      })
    end)
  end,
  page_key = function(_, item)
    return (item.url:gsub("#.*$", ""))
  end,
  fetch = function(_, item, cb)
    local u = item.url:gsub("#.*$", "")
    vim.schedule(function()
      cb(nil, { html = PAGES[u], url = u, base = u, extract = false })
    end)
  end,
  resolve = function(_, u)
    if u:match("^fake://") then
      return { item = { url = u, title = u, fragment = u:match("#(.*)$") } }
    end
  end,
}

require("rtfm.config").options.sources = { fake = { name = "Fake Docs", adapter = "fake" } }
require("rtfm.config").options.devdocs.enabled = false

local picker = require("rtfm.ui.picker")
local viewer = require("rtfm.ui.viewer")

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function wait(cond)
  return vim.wait(3000, cond, 5)
end

local function type_text(s)
  local P = picker._state()
  vim.api.nvim_buf_set_lines(P.bufs.prompt, 0, -1, false, { s })
  wait(function()
    return picker._state() and picker._state().req > 0 and #picker._state().matches > 0
  end)
  vim.wait(50)
end

it("source mode lists sources and filters them", function()
  picker.open({})
  wait(function()
    return picker._state() and #picker._state().sources > 0
  end)
  type_text("fake")
  local P = picker._state()
  contains(lines(P.bufs.results)[1], "Fake Docs")
  picker.actions.select_source()
  eq("search", picker._state().mode)
  eq("fake", picker._state().source.id)
  picker.close()
  eq(false, picker.is_open())
end)

it("searches a local source, previews and opens at the anchor", function()
  picker.open({ source = "fake" })
  wait(function()
    return picker._state() and picker._state().mode == "search" and #picker._state().matches > 0
  end)
  type_text("details")
  local P = picker._state()
  eq("alpha details", P.matches[1].item.title)
  wait(function()
    return #lines(P.bufs.preview) > 3
  end)
  contains(lines(P.bufs.preview), "## Details")
  picker.actions.open_vsplit()
  wait(function()
    return vim.b.rtfm_url ~= nil
  end)
  eq("fake://docs/alpha", vim.b.rtfm_url)
  eq("## Details", vim.api.nvim_get_current_line())
  eq(2, #vim.api.nvim_tabpage_list_wins(0))
end)

it("follows links into other pages and goes back", function()
  local buf = vim.api.nvim_get_current_buf()
  local l = vim.fn.search("beta usage")
  ok(l > 0)
  vim.api.nvim_win_set_cursor(0, { l, 6 })
  viewer.actions.follow()
  wait(function()
    return vim.b.rtfm_url == "fake://docs/beta"
  end)
  eq("## Usage", vim.api.nvim_get_current_line())
  viewer.actions.back()
  wait(function()
    return vim.api.nvim_get_current_buf() == buf
  end)
  eq(l, vim.api.nvim_win_get_cursor(0)[1])
  viewer.actions.forward()
  wait(function()
    return vim.b.rtfm_url == "fake://docs/beta"
  end)
  eq("fake://docs/beta", vim.b.rtfm_url)
end)

it("builds a table of contents", function()
  local items = viewer.toc_items(vim.api.nvim_get_current_buf())
  eq("Beta", items[1].text)
  eq("  Usage", items[2].text)
end)

it("records history and bookmarks", function()
  local store = require("rtfm.store")
  ok(#store.history("fake") >= 2)
  store.add_bookmark("fake", { url = "fake://docs/beta" }, "Beta", "note")
  ok(store.is_bookmarked("fake", { url = "fake://docs/beta" }))
  require("rtfm").bookmarks()
  wait(function()
    return picker._state() and #picker._state().matches == 1
  end)
  contains(lines(picker._state().bufs.results)[1], "Beta")
  -- list entries carry only a source id; the preview must still resolve and load
  wait(function()
    return table.concat(lines(picker._state().bufs.preview), "\n"):find("# Beta") ~= nil
  end)
  contains(lines(picker._state().bufs.preview), "# Beta")
  picker.actions.delete()
  eq(0, #store.bookmarks())
  picker.close()
end)

it("closes doc windows it created", function()
  viewer.actions.close()
  eq(1, #vim.api.nvim_tabpage_list_wins(0))
end)

it("finds links under the cursor", function()
  eq("https://x.y/z", viewer.link_at("see [docs](https://x.y/z) now", 6))
  eq("#a", viewer.link_at("[a](#a)", 0))
  eq("https://bare.dev/p", viewer.link_at("go to https://bare.dev/p.", 8))
  eq(nil, viewer.link_at("no links here", 3))
end)
