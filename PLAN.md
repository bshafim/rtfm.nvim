# rtfm.nvim — Plan

> Have you ever had to read docs while coding?
> Have you ever wanted to never, ever leave Neovim?
> **rtfm.nvim**: read the f***ing manual without leaving your editor.

## What makes it different

There are already devdocs-in-Neovim plugins, so search-and-open alone isn't enough. rtfm is built
around four things:

1. **Version-aware docs.** It reads `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml` (and
   their lockfiles) and opens docs for the exact version you're using, not the latest.
2. **Docs for the symbol under the cursor.** Put the cursor on `http.NewRequest`, press `K`
   (or `:Rtfm symbol`), and the right page opens in a split, jumped to the right section. No search needed.
3. **Local semantic search.** Docs are chunked, indexed and embedded with a small local model, so
   "how do I cancel a request after a timeout" finds `context.WithTimeout` even when you don't know
   the API name. Hybrid ranking (BM25 + embeddings) so it still works without a model.
4. **Fully offline.** Install docs once (`:Rtfm install`, or `:Rtfm install project` for exactly the
   versions you depend on). Search, reading, link following, and semantic search then work on a plane.

Plus the original flow: a fast floating picker (pick a source → type → results → read as Markdown
in a buffer), favorites, bookmarks, history.

## Stack

- Pure Lua, Neovim ≥ 0.10. No build step. `curl` for network.
- LuaJIT FFI for vector math (float32 arrays, fast cosine top-k); pure-Lua fallback.
- Embeddings come from a **local** model server:
  - default: **Ollama** (`all-minilm` / `nomic-embed-text`) on `localhost:11434`
  - or any OpenAI-compatible `/v1/embeddings` endpoint (llama.cpp server, LM Studio, …)
  - no model configured → lexical BM25 only (still useful, still offline)
- Optional: `pandoc` (better HTML→Markdown), `render-markdown.nvim` / `markview.nvim`.

## User flow

```
:Rtfm                           ┌ rtfm ──────────────────────────────┬─ Preview ──────────────────┐
                                │ [ Go 1.22 ] cancel after timeout█  │ # func WithTimeout         │
1. Type to filter sources       │────────────────────────────────────│                            │
   (project deps ⚑, favorites ★ │ ▸ context.WithTimeout   ≈ semantic │ func WithTimeout(parent    │
   first)                       │   context.WithDeadline  ≈ semantic │   Context, timeout ...     │
2. <Tab>/<CR> picks one → chip  │   http.Client.Timeout   ≈ semantic │                            │
3. Type a query → results       │   context.WithCancel      func     │ WithTimeout returns ...    │
4. <CR> open   <S-CR>/<C-s> split, <C-v> vsplit, <C-t> tab, <C-y> float (all configurable)
   <BS> on an empty prompt drops the chip → back to sources
```

- `:Rtfm go context.WithCancel` jumps straight in. `:Rtfm! go WithCancel` opens the best match.
- `:Rtfm ask <question>` runs semantic search across every installed doc.
- `K` / `:Rtfm symbol` opens docs for the symbol under the cursor (see below).

## Sources and adapters

Every source is `{ id, name, adapter, version?, ... }`. Adapters implement:

```lua
adapter.mode                          -- "local" (fuzzy as you type) | "remote" (debounced)
adapter.load(source, cb)              -- local: full entry list (title, path, kind)
adapter.search(source, query, cb)     -- remote: results
adapter.fetch(source, item, cb)       -- page: { html | markdown, url, base, fragment }
adapter.resolve(source, url)          -- link under cursor → item in this source (or nil)
adapter.pages(source, cb)             -- full page set, for offline install + indexing
adapter.versioned(source, version)    -- source pinned to a version (if supported)
```

| Adapter | Covers | How | Versions |
|---|---|---|---|
| **devdocs** | ~800 docs (Python, JS/MDN, Rust std, Lua, React, Node, Postgres…) | `docs.json` catalog, per-doc `index.json`, pages from `documents.devdocs.io`, `db.json` for offline | Versioned slugs (`python~3.12`, `node~20_lts`, `react~18`) |
| **gopkg** | Go stdlib + all Go modules | pkg.go.dev search + package pages (symbol anchors) | `pkg@v1.2.3`, `std@go1.22.0` |
| **docsrs** | Rust crates | crates.io search, docs.rs pages, crate `search-index` for symbols | `docs.rs/<crate>/<version>` |
| **github** | docs.github.com | Official search API, article bodies come back as Markdown | n/a |
| **mdn** | MDN Web Docs | MDN search API + page extraction | n/a |
| **sitemap** | Any site you add | `sitemap.xml`, cached, fuzzy over paths | n/a |
| **algolia** | Sites with Algolia DocSearch | Uses the app ID, key and index **the user configures** (nothing scraped or shipped) | n/a |

## Version awareness (`rtfm.project`)

Walks up from the current buffer to the nearest project root and parses:

| File | Gives |
|---|---|
| `go.mod` | Go version (`go 1.22`) → `std@go1.22.x`; `require` lines → module versions |
| `Cargo.toml` / `Cargo.lock` | crate versions (lockfile wins) → docs.rs at that version |
| `package.json` / `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock` | `react`, `vue`, `node` engines… → the matching devdocs slug (`react~18`) |
| `pyproject.toml` / `.python-version` / `requirements*.txt` | Python version → `python~3.12`; packages for display |

- Project deps show up first in the source picker with a ⚑ and their version (`[ Go 1.22 ]`).
- Version → slug matching picks the closest devdocs version at or below the one in use, and says
  when it falls back.
- Results are cached per root and invalidated when the manifest's mtime changes.

## Symbol under the cursor (`rtfm.symbol`)

A resolution chain. The first step that succeeds wins:

1. **LSP.** `textDocument/definition` gives the defining file. Its path identifies the dependency
   and the exact version:
   - `$GOROOT/src/net/http/request.go` → stdlib `net/http` at the project's Go version
   - `.../pkg/mod/github.com/x/y@v1.2.3/z.go` → `pkg.go.dev/github.com/x/y@v1.2.3/z#Symbol`
   - `.cargo/registry/src/*/serde-1.0.200/...` → `docs.rs/serde/1.0.200/...`
   - `node_modules/<pkg>/...` or `site-packages/<pkg>/...` → that package's docs
   - The symbol name and container come from the hover response or document symbols.
2. **Imports.** Treesitter reads the buffer's imports to expand aliases (`http` → `net/http`,
   `np` → `numpy`), then combines that with the project version.
3. **Fuzzy fallback.** Search the filetype's source for the text under the cursor. One exact match
   opens directly; otherwise the picker opens prefilled.

The page opens in a split (configurable) and jumps to the symbol's anchor.

## Local semantic search (`rtfm.index`)

- **Chunking.** Pages are split by heading into sections of about 200–400 tokens, keeping the
  heading path ("context › WithTimeout") as context. Code blocks stay with their prose.
- **Lexical.** A BM25 inverted index (pure Lua, JSON on disk) per doc. Always available.
- **Embeddings.** Batched requests to the local model. Vectors are normalized float32, stored as one
  binary file per doc plus a JSON sidecar (chunk → page/anchor). Indexing runs in the background,
  is resumable, and shows progress.
- **Query.** Embed the query → brute-force cosine top-k with LuaJIT FFI (tens of thousands of
  chunks in milliseconds) → fuse with BM25 using reciprocal rank fusion → group results by page.
- In the picker, a source with an index gets a semantic toggle (`<C-e>`). Long, natural-language
  queries switch to hybrid mode automatically.
- `:Rtfm index <source>`, `:Rtfm index project`, `:Rtfm ask …` searches all indexed docs.

## Offline (`rtfm.offline`)

- `:Rtfm install <source>[@version]` downloads everything:
  - devdocs: the `index.json` and `db.json` files
  - gopkg: every package page of the module version
  - docsrs: the crate's pages
  - sitemap: a polite crawl (concurrency limit, robots-friendly delay)
  - Everything goes into `stdpath("data")/rtfm/docs/<source>/<version>/`.
- `:Rtfm install project` installs and indexes every detected dependency at its exact version.
- Installed docs are always read locally. Versioned docs are immutable and never expire.
- `offline = true` (or no network) means rtfm never touches the network and says clearly when
  something isn't installed.
- `:Rtfm installed` lists installed docs, their size, and whether they're indexed. You can remove or
  update from there.

## Reading pages

- HTML → main content extraction → Markdown, via a tolerant Lua HTML parser. Optional pandoc.
- `nofile` buffer `rtfm://<source>/<path>`, `filetype=markdown`.
- Keymaps (all configurable):
  - `<CR>`/`gd`: follow a link. Same site opens in rtfm, other sites open in the browser.
  - `<C-o>`/`<C-i>`: back/forward.
  - `gO`: table of contents.
  - `gx`: open in the browser. `yu`: yank the URL.
  - `ma`: bookmark. `gs`: search this source. `q`: close.

## Persistence

- `stdpath("data")/rtfm/`: favorites, bookmarks (with notes), history, user sources, installed
  docs, indexes.
- `stdpath("cache")/rtfm/`: HTTP cache with TTL; a stale copy is used when offline.

## Commands

```
:Rtfm [source] [query]     picker (source may be "go", "python~3.12", "gopkg:github.com/x/y@v1.2.3")
:Rtfm! source query        open best match directly
:Rtfm symbol               docs for symbol under cursor (also <Plug>(rtfm-symbol))
:Rtfm ask {question}       semantic search across installed + indexed docs
:Rtfm project              show detected deps + versions, pick one
:Rtfm install {source|project} / uninstall / installed
:Rtfm index {source|project}
:Rtfm bookmarks | history | favorite [source]
:Rtfm add {url} | remove {id}
:Rtfm url {url}
:Rtfm cache clear
:checkhealth rtfm
```

## Code layout

```
lua/rtfm/
  init.lua config.lua commands.lua health.lua util.lua
  http.lua cache.lua store.lua url.lua fuzzy.lua
  sources.lua            registry (builtin, devdocs catalog, user, project)
  page.lua               fetch → convert → render pipeline (+ in-memory LRU)
  adapters/{devdocs,gopkg,docsrs,github,mdn,sitemap,algolia,web}.lua
  html/{parser,extract,markdown}.lua
  project/{init,go,rust,node,python}.lua
  symbol/{init,lsp,imports}.lua
  index/{chunk,bm25,vec,embed,init}.lua
  offline.lua
  ui/{picker,viewer,layout}.lua
plugin/rtfm.lua  doc/rtfm.txt  tests/
```

## Build order

1. Core: config, http, cache, store, url, fuzzy, the HTML→Markdown pipeline.
2. Adapters: devdocs, gopkg, docsrs, github, mdn, sitemap, algolia, web.
3. UI: viewer and picker. Commands.
4. Project detection and version-aware sources.
5. Symbol resolution (LSP → imports → fuzzy).
6. Offline install.
7. Index: chunking, BM25, embeddings, hybrid search, `:Rtfm ask`.
8. Favorites, bookmarks, history, health, vimdoc, README, tests, CI.

## Testing

- Headless `nvim -l` test runner, no dependencies.
- Unit tests:
  - HTML→Markdown against fixture pages
  - URL resolution and fuzzy ranking
  - manifest parsers (go.mod, Cargo.lock, package-lock, pyproject)
  - LSP path → doc mapping
  - chunker, BM25, vector top-k, rank fusion
- Adapter tests use recorded fixtures. `RTFM_LIVE=1` runs smoke tests against the real endpoints.
- UI: drive the picker headlessly with a fake source.
