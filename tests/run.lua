-- Minimal test runner: nvim --headless -u NONE -l tests/run.lua [pattern]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- isolate all state
local tmp = vim.fn.tempname()
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.cmd("filetype on")

local T = { passed = 0, failed = 0, failures = {} }
_G.T = T

local current = {}

function _G.describe(name, fn)
  table.insert(current, name)
  fn()
  table.remove(current)
end

function _G.it(name, fn)
  local full = table.concat(current, " › ") .. " › " .. name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    T.passed = T.passed + 1
    io.write(".")
  else
    T.failed = T.failed + 1
    table.insert(T.failures, { name = full, err = err })
    io.write("F")
  end
end

local function fmt(v)
  return type(v) == "string" and ("%q"):format(v) or vim.inspect(v)
end

_G.eq = function(want, got, msg)
  if not vim.deep_equal(want, got) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", fmt(want), fmt(got)), 2)
  end
end

_G.ok = function(v, msg)
  if not v then
    error(msg or "expected truthy value", 2)
  end
end

_G.contains = function(haystack, needle, msg)
  if type(haystack) == "table" then
    haystack = table.concat(haystack, "\n")
  end
  if not tostring(haystack):find(needle, 1, true) then
    error(("%sexpected to find %s in:\n%s"):format(msg and (msg .. ": ") or "", fmt(needle), tostring(haystack):sub(1, 1500)), 2)
  end
end

_G.fixture = function(name)
  local f = assert(io.open(root .. "/tests/fixtures/" .. name, "rb"), "missing fixture " .. name)
  local s = f:read("*a")
  f:close()
  return s
end

--- Wait for an async callback-style call. Returns the callback's arguments.
_G.await = function(fn, timeout)
  local res
  fn(function(...)
    res = { n = select("#", ...), ... }
  end)
  vim.wait(timeout or 5000, function()
    return res ~= nil
  end, 5)
  assert(res, "timed out waiting for callback")
  return unpack(res, 1, res.n)
end

_G.TMP = tmp

require("rtfm").setup({})

local pattern = arg[1]
local specs = vim.fn.glob(root .. "/tests/spec/*_spec.lua", false, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  if not pattern or spec:find(pattern, 1, true) then
    local name = vim.fn.fnamemodify(spec, ":t:r")
    describe(name, function()
      local chunk, err = loadfile(spec)
      if not chunk then
        it("loads", function()
          error(err)
        end)
      else
        chunk()
      end
    end)
  end
end

io.write("\n\n")
for _, f in ipairs(T.failures) do
  io.write("FAIL " .. f.name .. "\n" .. f.err .. "\n\n")
end
io.write(("%d passed, %d failed\n"):format(T.passed, T.failed))
vim.fn.delete(tmp, "rf")
os.exit(T.failed > 0 and 1 or 0)
