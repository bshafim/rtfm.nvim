if vim.g.loaded_rtfm then
  return
end
vim.g.loaded_rtfm = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("rtfm.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Rtfm", function(opts)
  require("rtfm.commands").run(opts)
end, {
  nargs = "*",
  bang = true,
  desc = "Search and read documentation",
  complete = function(arglead, cmdline)
    return require("rtfm.commands").complete(arglead, cmdline)
  end,
})

vim.keymap.set("n", "<Plug>(rtfm-symbol)", function()
  require("rtfm").symbol()
end, { desc = "rtfm: docs for symbol under cursor" })

vim.keymap.set("n", "<Plug>(rtfm-open)", function()
  require("rtfm").open()
end, { desc = "rtfm: open picker" })

vim.keymap.set("n", "<Plug>(rtfm-ask)", function()
  require("rtfm").ask()
end, { desc = "rtfm: ask your docs" })
