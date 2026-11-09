local symbol = require("rtfm.symbol")
local locate = require("rtfm.symbol.locate")
local imports = require("rtfm.symbol.imports")

describe("expression under cursor", function()
  it("expands across dots and colons", function()
    eq("http.NewRequest", symbol.expr_at("  req, _ := http.NewRequest(\"GET\")", 18))
    eq("http.NewRequest", symbol.expr_at("  req, _ := http.NewRequest(\"GET\")", 13))
    eq("std::fs::read_to_string", symbol.expr_at("let s = std::fs::read_to_string(p);", 18))
    eq("np.linalg.norm", symbol.expr_at("x = np.linalg.norm(v)", 6))
    eq(nil, symbol.expr_at("a = (b)", 4))
  end)
end)

describe("go", function()
  local lines = {
    "package http",
    "func NewRequest(method, url string) (*Request, error) {",
    "func (c *Client) Do(req *Request) (*Response, error) {",
    "func (s Set[T]) Has(v T) bool {",
    "type Client struct {",
    "\tTimeout time.Duration",
    "}",
  }
  it("derives pkg.go.dev anchors", function()
    eq("NewRequest", locate.go_anchor(lines, 2, "NewRequest"))
    eq("Client.Do", locate.go_anchor(lines, 3, "Do"))
    eq("Set.Has", locate.go_anchor(lines, 4, "Has"))
    eq("Client", locate.go_anchor(lines, 5, "Client"))
    eq("Client.Timeout", locate.go_anchor(lines, 6, "Timeout"))
  end)

  it("maps module cache and toolchain paths", function()
    local dir = TMP .. "/pkg/mod/github.com/!burnt!sushi/toml@v1.4.0"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "package toml", "func Decode(data string, v any) (MetaData, error) {" }, dir .. "/decode.go")
    local t = locate.go(dir .. "/decode.go", 2, "Decode")
    eq("gopkg:github.com/BurntSushi/toml@v1.4.0", t.source.id)
    eq("https://pkg.go.dev/github.com/BurntSushi/toml@v1.4.0#Decode", t.item.url)

    local tc = TMP .. "/pkg/mod/golang.org/toolchain@v0.0.1-go1.22.5.darwin-arm64/src/net/http"
    vim.fn.mkdir(tc, "p")
    vim.fn.writefile({ "package http", "func Get(url string) (*Response, error) {" }, tc .. "/client.go")
    t = locate.go(tc .. "/client.go", 2, "Get")
    eq("gopkg:std@go1.22.5", t.source.id)
    eq("https://pkg.go.dev/net/http@go1.22.5#Get", t.item.url)
  end)

  it("maps a GOROOT using its VERSION file", function()
    local goroot = TMP .. "/goroot"
    vim.fn.mkdir(goroot .. "/src/context", "p")
    vim.fn.writefile({ "go1.23.4", "time 2024" }, goroot .. "/VERSION")
    vim.fn.writefile({ "package context", "func WithTimeout(parent Context, d time.Duration) (Context, CancelFunc) {" }, goroot .. "/src/context/context.go")
    local t = locate.go(goroot .. "/src/context/context.go", 2, "WithTimeout")
    eq("gopkg:std@go1.23.4", t.source.id)
    eq("WithTimeout", t.item.fragment)
  end)

  it("parses imports with aliases", function()
    local imp = imports.go_imports([[
package main

import "fmt"
import yaml "gopkg.in/yaml.v3"

import (
	"net/http"
	eg "golang.org/x/sync/errgroup"
	_ "embed"
	"github.com/foo/bar/v2"
)
]])
    eq("fmt", imp.fmt)
    eq("gopkg.in/yaml.v3", imp.yaml)
    eq("net/http", imp.http)
    eq("golang.org/x/sync/errgroup", imp.eg)
    eq("github.com/foo/bar/v2", imp.bar)
    eq(nil, imp._)
  end)
end)

describe("python", function()
  it("builds qualified names", function()
    local lines = { "class JSONEncoder:", "    def encode(self, o):", "        pass", "def dumps(obj):" }
    eq("JSONEncoder.encode", locate.python_name(lines, 2, "encode"))
    eq("dumps", locate.python_name(lines, 4, "dumps"))
    eq("JSONEncoder", locate.python_name(lines, 1, "JSONEncoder"))
  end)

  it("parses imports", function()
    local imp = imports.python_imports("import numpy as np\nimport os.path\nfrom json import dumps, loads as L\nfrom a.b import (c,\n")
    eq("numpy", imp.np)
    eq("os", imp.os)
    eq("json.dumps", imp.dumps)
    eq("json.loads", imp.L)
  end)
end)

describe("rust", function()
  it("finds items and their owners", function()
    local lines = {
      "pub struct Map {}",
      "impl<K, V> Map<K, V> {",
      "    pub fn new() -> Self {",
      "    }",
      "}",
      "pub trait Read {",
      "    fn read(&mut self, buf: &mut [u8]) -> Result<usize>;",
      "}",
      "macro_rules! vec {",
    }
    eq({ name = "Map", kind = "struct", has_body = true }, locate.rust_item(lines, 1, "Map"))
    local m = locate.rust_item(lines, 3, "new")
    eq("Map", m.owner)
    eq("impl", m.owner_kind)
    local r = locate.rust_item(lines, 7, "read")
    eq("Read", r.owner)
    eq(false, r.has_body)
    eq("macro", locate.rust_item(lines, 9, "vec").kind)
  end)

  it("maps registry paths to docs.rs targets", function()
    local dir = TMP .. "/registry/src/index.crates.io-6f17d22bba15001f/serde-1.0.200/src/de"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "pub trait Deserialize<'de>: Sized {" }, dir .. "/mod.rs")
    local t = locate.rust(dir .. "/mod.rs", 1, "Deserialize")
    eq("docsrs:serde@1.0.200", t.source.id)
    eq("Deserialize", t.query)
    eq("de", t.module)
  end)

  it("parses use statements", function()
    local u = imports.rust_uses("use std::collections::{HashMap, BTreeMap as BT};\nuse serde::Deserialize;\n")
    eq("std::collections::HashMap", u.HashMap)
    eq("std::collections::BTreeMap", u.BT)
    eq("serde::Deserialize", u.Deserialize)
  end)
end)

describe("js", function()
  it("parses imports", function()
    local imp = imports.js_imports([[import React, { useState as uS } from "react";
const _ = require('lodash')
import type { X } from '@scope/pkg/sub']])
    eq("react", imp.React)
    eq("react", imp.useState)
    eq("lodash", imp._)
    eq("@scope/pkg/sub", imp.X)
  end)
end)
