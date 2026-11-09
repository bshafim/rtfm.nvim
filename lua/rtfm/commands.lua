--- :Rtfm command dispatch and completion.
local M = {}

local function rtfm()
  return require("rtfm")
end

local function rest(args, from)
  return table.concat(args, " ", from)
end

M.subcommands = {
  symbol = function()
    rtfm().symbol()
  end,
  ask = function(args)
    rtfm().ask(rest(args, 2))
  end,
  project = function()
    rtfm().project()
  end,
  install = function(args)
    if not args[2] then
      return require("rtfm.util").warn("usage: :Rtfm install <source>|project")
    end
    rtfm().install(args[2], { index = args[2] == "project" })
  end,
  uninstall = function(args)
    if not args[2] then
      return require("rtfm.util").warn("usage: :Rtfm uninstall <source>")
    end
    rtfm().uninstall(args[2])
  end,
  installed = function()
    rtfm().installed()
  end,
  index = function(args)
    if not args[2] then
      return require("rtfm.util").warn("usage: :Rtfm index <source>|project")
    end
    rtfm().index(args[2])
  end,
  bookmarks = function()
    rtfm().bookmarks()
  end,
  history = function()
    rtfm().history()
  end,
  favorite = function(args)
    local store, util = require("rtfm.store"), require("rtfm.util")
    local id = args[2] or vim.b.rtfm_source
    if not id then
      return util.warn("usage: :Rtfm favorite <source>")
    end
    util.notify((store.toggle_favorite(id) and "★ favorited " or "unfavorited ") .. id)
  end,
  add = function(args)
    local util = require("rtfm.util")
    if not args[2] then
      return util.warn("usage: :Rtfm add <url> [name]")
    end
    require("rtfm.sources").add_url(args[2], args[3], function(err, src)
      if err then
        return util.error(err)
      end
      util.notify(("added source '%s' (%s)"):format(src.id, src.url))
    end)
  end,
  remove = function(args)
    local util = require("rtfm.util")
    if require("rtfm.store").remove_source(args[2] or "") then
      util.notify("removed source " .. args[2])
    else
      util.warn("no user-added source named " .. tostring(args[2]))
    end
  end,
  url = function(args)
    if not args[2] then
      return require("rtfm.util").warn("usage: :Rtfm url <url>")
    end
    rtfm().open_url(args[2])
  end,
  cache = function(args)
    if args[2] == "clear" then
      require("rtfm.cache").clear()
      require("rtfm.page").clear()
      require("rtfm.util").notify("cache cleared")
    else
      require("rtfm.util").warn("usage: :Rtfm cache clear")
    end
  end,
  offline = function(args)
    local v = args[2]
    rtfm().set_offline(v == "on" and true or v == "off" and false or nil)
  end,
}

function M.run(opts)
  require("rtfm").ensure_setup()
  local args = opts.fargs
  local sub = args[1]
  if not sub then
    return rtfm().open()
  end
  local fn = M.subcommands[sub]
  if fn then
    return fn(args)
  end
  -- :Rtfm <source> [query]   /   :Rtfm! <source> <query>
  local query = rest(args, 2)
  if opts.bang then
    return rtfm().search(sub, query, { first = true })
  end
  rtfm().search(sub, query ~= "" and query or nil)
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = false })
  local n = #words
  local function filter(list)
    return vim.tbl_filter(function(s)
      return s:find(arglead, 1, true) == 1
    end, list)
  end
  local ids = function()
    return require("rtfm.sources").complete_ids()
  end
  if n <= 2 then
    local subs = vim.tbl_keys(M.subcommands)
    table.sort(subs)
    return filter(vim.list_extend(subs, ids()))
  end
  local sub = words[2]
  if n == 3 then
    if sub == "install" or sub == "index" then
      return filter(vim.list_extend({ "project" }, ids()))
    elseif sub == "uninstall" then
      local out = {}
      for _, m in ipairs(require("rtfm.offline").list()) do
        table.insert(out, m.id)
      end
      return filter(out)
    elseif sub == "favorite" then
      return filter(ids())
    elseif sub == "remove" then
      return filter(vim.tbl_keys(require("rtfm.store").user_sources()))
    elseif sub == "cache" then
      return filter({ "clear" })
    elseif sub == "offline" then
      return filter({ "on", "off" })
    end
  end
  return {}
end

return M
