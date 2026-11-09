local M = {}

---@class rtfm.Config
M.defaults = {
  -- where pages open by default: "buffer" | "split" | "vsplit" | "tab" | "float"
  open = "buffer",
  -- never touch the network; only installed/cached docs are used
  offline = false,

  ui = {
    width = 0.85,
    height = 0.8,
    border = "rounded",
    preview = true,
    results_width = 0.42,
    debounce = 250, -- ms, remote search
    preview_debounce = 120,
    max_results = 300,
    icons = {
      prompt = "> ",
      favorite = "★",
      project = "⚑",
      installed = "●",
      semantic = "≈",
    },
  },

  keymaps = {
    -- picker (insert mode in the prompt). Set a key to false to disable it.
    picker = {
      ["<CR>"] = "open",
      ["<S-CR>"] = "open_split",
      ["<C-s>"] = "open_split",
      ["<C-v>"] = "open_vsplit",
      ["<C-t>"] = "open_tab",
      ["<C-y>"] = "open_float",
      ["<Tab>"] = "select_source",
      ["<C-n>"] = "next",
      ["<Down>"] = "next",
      ["<C-p>"] = "prev",
      ["<Up>"] = "prev",
      ["<C-d>"] = "preview_down",
      ["<C-u>"] = "preview_up",
      ["<C-f>"] = "toggle_favorite",
      ["<C-b>"] = "bookmark",
      ["<C-x>"] = "delete",
      ["<C-e>"] = "toggle_semantic",
      ["<C-g>"] = "browser",
      ["<BS>"] = "backspace",
      ["<Esc>"] = "close",
      ["<C-c>"] = "close",
    },
    -- doc buffers (normal mode)
    viewer = {
      ["<CR>"] = "follow",
      ["gd"] = "follow",
      ["<C-o>"] = "back",
      ["<C-i>"] = "forward",
      ["gO"] = "toc",
      ["gx"] = "browser",
      ["yu"] = "yank_url",
      ["ma"] = "bookmark",
      ["gs"] = "search",
      ["q"] = "close",
    },
  },

  viewer = {
    -- window-local options for doc windows
    wo = { wrap = true, linebreak = true, conceallevel = 2, spell = false, number = false, relativenumber = false, signcolumn = "no" },
    float = { width = 0.8, height = 0.85 },
  },

  -- what following a link does: "rtfm" (render inside nvim) or "browser"
  links = { same_site = "rtfm", other_site = "browser" },

  html = {
    converter = "builtin", -- "builtin" | "pandoc" | "auto"
  },

  devdocs = {
    enabled = true,
    latest_only = true, -- list only the newest version of each doc
    only = nil, -- restrict to these slugs, e.g. { "go", "lua~5.1" }
  },

  project = {
    enabled = true,
    -- markers used to find the project root
    markers = { "go.mod", "Cargo.toml", "package.json", "pyproject.toml", "requirements.txt", ".git" },
  },

  symbol = {
    open = "split", -- how :Rtfm symbol opens pages
    lsp = true,
    timeout = 1500, -- ms to wait for LSP
    keymap = nil, -- e.g. "gK" to map symbol lookup globally
  },

  index = {
    -- embedding backend: "ollama" | "openai" | false (BM25 only)
    embed = {
      provider = "ollama",
      model = "all-minilm",
      url = nil, -- defaults: http://localhost:11434 (ollama), http://localhost:8080/v1 (openai)
      api_key = nil, -- for OpenAI-compatible servers that want one
      batch = 32,
      -- inputs are clipped to this many characters; small models (all-minilm) only take 256 tokens
      max_chars = 1000,
    },
    chunk_tokens = 300,
    -- queries with at least this many words go to hybrid/semantic search automatically
    semantic_min_words = 4,
    top_k = 50,
  },

  offline_install = {
    concurrency = 4,
    delay = 100, -- ms between crawl requests per worker
    max_pages = 5000,
  },

  cache = {
    ttl = 7 * 24 * 3600,
  },

  http = {
    timeout = 20,
    user_agent = "rtfm.nvim/0.1 (Neovim docs reader)",
  },

  -- extra/overridden sources. Set a builtin id to false to hide it.
  -- { vue = { name = "Vue", adapter = "sitemap", url = "https://vuejs.org/sitemap.xml" } }
  sources = {},

  -- filetype -> source id, used by :Rtfm symbol's fuzzy fallback and :Rtfm (no args) preselect
  filetypes = {
    go = "gopkg",
    lua = "lua~5.1",
    python = "python",
    rust = "docsrs",
    javascript = "javascript",
    javascriptreact = "react",
    typescript = "typescript",
    typescriptreact = "react",
    c = "c",
    cpp = "cpp",
    sh = "bash",
    bash = "bash",
    zsh = "bash",
    html = "html",
    css = "css",
    ruby = "ruby",
    php = "php",
    java = "openjdk",
    kotlin = "kotlin",
    elixir = "elixir",
    haskell = "haskell",
    sql = "postgresql",
    zig = "zig",
  },
}

---@type rtfm.Config
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  local keymaps, sources = opts.keymaps, opts.sources
  opts.keymaps, opts.sources = nil, nil
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- keymaps merge one level deep so users can disable single keys with `false`
  for _, kind in ipairs({ "picker", "viewer" }) do
    for k, v in pairs((keymaps or {})[kind] or {}) do
      M.options.keymaps[kind][k] = v
    end
  end
  M.options.sources = sources or {}

  local valid_open = { buffer = true, split = true, vsplit = true, tab = true, float = true }
  for _, key in ipairs({ "open" }) do
    if not valid_open[M.options[key]] then
      vim.notify("rtfm: invalid `" .. key .. "` value " .. tostring(M.options[key]), vim.log.levels.WARN)
      M.options[key] = "buffer"
    end
  end
  if not valid_open[M.options.symbol.open] then
    M.options.symbol.open = "split"
  end
  return M.options
end

return M
