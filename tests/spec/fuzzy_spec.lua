local fuzzy = require("rtfm.fuzzy")

local items = {
  { title = "context.WithCancelCause()" },
  { title = "context.WithCancel()" },
  { title = "context.WithoutCancel()" },
  { title = "http.Client" },
  { title = "sort.Slice()" },
}

it("ranks exact last segment first", function()
  local r = fuzzy.filter(items, "WithCancel")
  eq("context.WithCancel()", r[1].item.title)
end)

it("returns positions for highlighting", function()
  local r = fuzzy.filter(items, "client")
  eq("http.Client", r[1].item.title)
  ok(#r[1].positions == 6)
end)

it("empty query returns everything up to limit", function()
  eq(3, #fuzzy.filter(items, "", 3))
end)

it("handles duplicate titles", function()
  local dup = { { title = "a", id = 1 }, { title = "a", id = 2 } }
  local r = fuzzy.filter(dup, "a")
  eq(2, #r)
  ok(r[1].item.id ~= r[2].item.id)
end)

it("uses the search field when present", function()
  local r = fuzzy.filter({ { title = "Cache", search = "Cache build docker" } }, "docker")
  eq(1, #r)
end)
