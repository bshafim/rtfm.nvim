local go = require("rtfm.project.go")
local rust = require("rtfm.project.rust")
local node = require("rtfm.project.node")
local python = require("rtfm.project.python")
local project = require("rtfm.project")

describe("go.mod", function()
  it("parses go version, toolchain, requires and replaces", function()
    local r = go.parse_gomod([=[
module example.com/m

go 1.22

toolchain go1.22.5

require github.com/pkg/errors v0.9.1

require (
	golang.org/x/sync v0.10.0
	github.com/stretchr/testify v1.9.0 // indirect
)

replace github.com/pkg/errors => github.com/fork/errors v0.9.2
]=])
    eq("example.com/m", r.module)
    eq("1.22.5", r.lang_version)
    eq(3, #r.deps)
    eq({ eco = "go", name = "github.com/pkg/errors", version = "v0.9.2", direct = true, docs_name = "github.com/fork/errors" }, r.deps[1])
    eq(false, r.deps[3].direct)
  end)

  it("unescapes module cache paths", function()
    eq("github.com/BurntSushi/toml", go.unescape("github.com/!burnt!sushi/toml"))
  end)
end)

describe("cargo", function()
  it("parses Cargo.lock and Cargo.toml", function()
    local lock = rust.parse_lock([=[
version = 3

[[package]]
name = "serde"
version = "1.0.200"
dependencies = [
 "serde_derive",
]

[[package]]
name = "serde_derive"
version = "1.0.200"

[[package]]
name = "tokio"
version = "1.37.0"
]=])
    eq({ serde = "1.0.200", serde_derive = "1.0.200", tokio = "1.37.0" }, lock)
    local deps = rust.parse_manifest([=[
[package]
name = "x"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
anyhow = "1"
renamed = { package = "real-name", version = "0.2" }

[dependencies.tokio]
version = "1.37"
]=])
    eq({ { name = "serde", req = "1.0" }, { name = "anyhow", req = "1" }, { name = "real-name", req = "0.2" }, { name = "tokio", req = "1.37" } }, deps)
  end)
end)

describe("node", function()
  it("reads exact versions from lockfiles", function()
    local npm = node.parse_npm_lock([[{"packages":{"":{},"node_modules/react":{"version":"18.2.0"},"node_modules/a/node_modules/react":{"version":"16.0.0"}}}]])
    eq({ react = "18.2.0" }, npm)
    eq("18.3.1", node.version_from_pnpm("importers:\n  .:\n    dependencies:\n      react:\n        specifier: ^18.2.0\n        version: 18.3.1\n", "react"))
    eq("4.17.21", node.version_from_yarn('\n"lodash@^4.17.0":\n  version "4.17.21"\n  resolved "x"\n\n', "lodash"))
  end)
end)

describe("python", function()
  it("parses pyproject, requirements and locks", function()
    local deps, py = python.parse_pyproject([=[
[project]
name = "x"
requires-python = ">=3.11"
dependencies = [
  "requests>=2.31",
  "numpy==1.26.4",
  "rich[jupyter]; python_version > '3.8'",
]
]=])
    eq("3.11", py)
    eq({ { name = "requests", version = "2.31" }, { name = "numpy", version = "1.26.4" }, { name = "rich" } }, deps)
    eq({ { name = "Django", version = "5.0.1" } }, python.parse_requirements("# c\nDjango==5.0.1\n-r other.txt\n"))
    eq({ numpy = "2.0.0" }, python.parse_lock('[[package]]\nname = "numpy"\nversion = "2.0.0"\n'))
  end)
end)

describe("detect", function()
  it("detects a mixed project from disk and maps sources", function()
    local root = TMP .. "/proj"
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "module m", "", "go 1.21", "", "require golang.org/x/sync v0.10.0" }, root .. "/go.mod")
    vim.fn.writefile({ '{"dependencies":{"react":"^18.2.0"},"engines":{"node":">=20"}}' }, root .. "/package.json")
    vim.fn.writefile({ "3.12.4" }, root .. "/.python-version")
    vim.cmd("edit " .. root .. "/main.go")
    local p = project.detect(0)
    eq(vim.uv.fs_realpath(root), vim.uv.fs_realpath(p.root))
    eq("1.21", p.langs.go)
    eq("20", p.langs.node)
    eq("3.12.4", p.langs.python)
    eq("golang.org/x/sync", project.go_module_for(p, "golang.org/x/sync/errgroup").name)
    vim.cmd("bwipe!")
  end)

  it("picks the closest devdocs version", function()
    local catalog = {
      { slug = "python~3.13", name = "Python", version = "3.13" },
      { slug = "python~3.12", name = "Python", version = "3.12" },
      { slug = "python~3.10", name = "Python", version = "3.10" },
      { slug = "react", name = "React", version = "" },
      { slug = "react~17", name = "React", version = "17" },
    }
    local e, exact = project.pick_devdocs(catalog, "python", "3.12.4")
    eq("python~3.12", e.slug)
    eq(true, exact)
    e, exact = project.pick_devdocs(catalog, "python", "3.11")
    eq("python~3.10", e.slug)
    eq(false, exact)
    e = project.pick_devdocs(catalog, "python", "3.9")
    eq("python~3.10", e.slug, "falls back to the oldest above")
    e = project.pick_devdocs(catalog, "react", "17.0.2")
    eq("react~17", e.slug)
    e = project.pick_devdocs(catalog, "react", "18.2.0")
    eq("react~17", e.slug, "17 is the newest at or below 18")
  end)
end)
