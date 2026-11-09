# lookup.nvim — Plan

> Have you ever had to read docs while coding?
> Have you ever wanted to never, ever leave Neovim?
> **lookup.nvim**: search and read any docs without leaving your editor.

## Goals

- Pick a doc source → type a query → see matching pages → read the page as Markdown in a buffer.
- No build step: pure Lua + `curl`. Install with lazy.nvim and it works.
- Reliable search. This is where `docfetch.nvim` failed (it scraped HTML search pages, which most
  docs sites render with JS). Here, every source uses an **adapter** that queries a real index or API.
- Fast: local indexes are filtered as you type, remote APIs are debounced, everything is async
  (never block the UI).
- Favorites, bookmarks, history, and an offline cache.

Non-goals (for v1): full JS rendering, images, rendering arbitrary non-docs websites well.

## Requirements

- Neovim ≥ 0.10 (`vim.system`, `vim.uv`, `vim.json`)
- `curl` on PATH
- Optional: `pandoc` (better HTML→Markdown), `render-markdown.nvim` / `markview.nvim` (prettier display)

## User flow

```
:Lookup                         ┌ Lookup ───────────────────────────┬─ Preview ──────────────────┐
                                │ [ Go ] context withcancel█         │ # func WithCancel          │
1. Type to filter sources       │────────────────────────────────────│                            │
   (favorites ★ first)          │ ▸ context.WithCancel      func     │ func WithCancel(parent     │
2. <Tab>/<CR> picks one → it    │   context.WithCancelCause func     │   Context) (ctx Context,   │
   becomes a chip in the prompt │   context.CancelFunc      type     │   cancel CancelFunc)       │
3. Type a query → results       │   context (package)       pkg      │                            │
4. <CR> open   <S-CR> split     │                                    │ WithCancel returns a       │
   <C-v> vsplit <C-t> tab       │                                    │ derived context that ...   │
   <BS> on empty prompt drops   │  4 results · devdocs               │                            │
   the chip → back to sources   └────────────────────────────────────┴────────────────────────────┘
```

Direct forms skip steps: `:Lookup go`, `:Lookup go context.WithCancel`, and `K`-style lookup of the
word under the cursor using a filetype → source map.

## Search adapters

Every source has the shape `{ id, name, adapter, opts }`. Adapters implement:

```lua
adapter.search(source, query, cb)   -- async → { {title, url, kind?, snippet?}, ... }
adapter.fetch(source, item, cb)     -- async → { title, markdown, url, links }
adapter.mode                        -- "local" (filter as you type) | "remote" (debounced/on-enter)
```

| Adapter | Covers | How |
|---|---|---|
| **devdocs** | ~600 docs (Go, Python, JS/MDN, Rust std, Lua, React, Node, Postgres, Docker…) | Catalog `devdocs.io/docs.json`; per-doc `index.json` downloaded once and cached, then fuzzy-searched locally (`matchfuzzy`). Pages are fetched lazily from `documents.devdocs.io/<slug>/<path>.html`. Optional "install for offline" downloads `db.json`. |
| **github_docs** | docs.github.com | Official search endpoint `/api/search/v1`. |
| **pkg_go** | pkg.go.dev (third-party Go modules) | Search-page scrape; this one worked in the old code. |
| **docs_rs** | Rust crates | crates.io API for search, docs.rs for pages. |
| **algolia** | Any site using Algolia DocSearch (React, Tailwind, Vite, Vue, Docusaurus sites…) | POST to the public DocSearch index with the site's public app ID and search key (the same values its search box uses). Built-in sources ship with verified keys; users can add their own. |
| **sitemap** | Any other URL a user adds | Fetch `sitemap.xml` (and sitemap indexes), derive titles from paths, cache, fuzzy-search locally. |

Users can add sources in config (`sources = { mydocs = { adapter = "sitemap", url = "…" } }`) or at
runtime with `:Lookup add <url>`, which auto-detects the adapter: DocSearch keys in the page →
algolia, otherwise sitemap.

## Rendering pages

- Fetch with curl → extract the main content (`main`, `article`, `[role=main]`, common docs
  selectors) → convert HTML to Markdown with a small tolerant Lua HTML tokenizer and converter
  (headings, code blocks with language, lists, tables, links, inline code, `dl`). Use `pandoc`
  when it's available and enabled.
- Open as a `nofile` buffer named `lookup://<source>/<path>` with `filetype=markdown`, so
  render-markdown and markview just work.
- Viewer keymaps (buffer-local, configurable):
  - `<CR>` / `gd`: follow the link under the cursor. Same-site links open inside lookup, other
    links open in the browser.
  - `<C-o>` / `<C-i>`: back/forward through the page history.
  - `gO`: table of contents (headings) in a float or loclist.
  - `gx`: open the current page in the browser. `yu`: yank its URL.
  - `ma`: bookmark the page. `q`: close.
- Open target is configurable: `buffer | split | vsplit | tab | float`, with per-key overrides.

## Persistence

- `stdpath("data")/lookup/`: `favorites.json` (sources), `bookmarks.json` (pages, with an
  optional note and tags), `history.json` (recent pages and queries), user-added sources.
- `stdpath("cache")/lookup/`: devdocs indexes, sitemaps, and rendered pages (TTL, default 7 days).
  Commands: `:Lookup cache clear`, `:Lookup update`.

## Commands and API

```
:Lookup [source] [query]       open picker / jump straight to a source / search directly
:Lookup bookmarks | history    picker over saved pages
:Lookup favorite [source]      toggle a source as favorite
:Lookup add <url> | remove <id>
:Lookup install <devdoc>       download a devdocs doc for offline use
:Lookup url <url>              render any URL
:Lookup cache clear | update
:checkhealth lookup
```

Lua: `require("lookup").setup(opts)`, `.open(opts)`, `.search(source, query)`, `.cword()`.

## Code layout

```
lua/lookup/
  init.lua            setup, public API
  config.lua          defaults + validation
  commands.lua        :Lookup subcommands + completion
  http.lua            async curl wrapper (vim.system), retries, UA, timeouts
  cache.lua  store.lua   on-disk cache / persistent JSON stores
  fuzzy.lua           matchfuzzy wrapper + scoring (favor title prefix, kind)
  sources/init.lua    registry, built-ins, user sources, auto-detect
  adapters/{devdocs,github_docs,pkg_go,docs_rs,algolia,sitemap}.lua
  html/{parse,extract,markdown}.lua   tokenizer → main content → markdown
  ui/picker.lua       floating prompt/results/preview, chip, keymaps, debounce
  ui/viewer.lua       doc buffers, link following, history, TOC
  health.lua
plugin/lookup.lua     lazy command registration
doc/lookup.txt        vimdoc
tests/                mini.test headless specs + recorded HTTP fixtures
```

## Phases

1. **Core + DevDocs (MVP).** http, cache, devdocs adapter, HTML→Markdown, the viewer, and the
   picker's full two-step flow. This alone covers most daily use.
2. **More adapters.** github_docs, algolia (with built-in verified sources), pkg_go, docs_rs,
   sitemap, `:Lookup add` auto-detection.
3. **Personal layer.** Favorites, bookmarks (with notes), history pickers, `K`/cword lookup with
   a filetype map, offline install.
4. **Polish.** Vimdoc, `:checkhealth`, README with GIFs, CI (headless tests on stable and nightly),
   optional pandoc path, and optional Telescope/snacks/fzf-lua frontends.

Each phase ends with passing headless tests and a manual run-through in a real Neovim.

## Testing

- Unit: HTML→Markdown against fixture pages (go.dev, MDN, GitHub Docs, Docusaurus), fuzzy
  scoring, URL resolution, store round-trips.
- Adapter tests use recorded JSON/HTML fixtures (no network in CI), plus an opt-in `LIVE=1` smoke
  test against the real endpoints.
- UI: headless Neovim drives the picker (feed keys, assert buffer contents).

## Prior art (and how this differs)

- `nvim-devdocs` / `devdocs.nvim`: DevDocs only. lookup adds GitHub Docs, Algolia sites, any
  sitemap site, and a fluid search-as-you-type picker over a remote page set.
- `docfetch.nvim` (your earlier attempt): Go binary + JSON-RPC + HTML search scraping. lookup
  drops the binary and replaces scraping with adapters.
