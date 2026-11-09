--- Minimal URL parsing and RFC 3986 relative resolution.
local M = {}

---@return {scheme?:string, host?:string, path:string, query?:string, fragment?:string}
function M.parse(u)
  local out = {}
  local rest = u
  local frag_start = rest:find("#", 1, true)
  if frag_start then
    out.fragment = rest:sub(frag_start + 1)
    rest = rest:sub(1, frag_start - 1)
  end
  local q = rest:find("?", 1, true)
  if q then
    out.query = rest:sub(q + 1)
    rest = rest:sub(1, q - 1)
  end
  local scheme, after = rest:match("^(%a[%w+.-]*):(.*)$")
  if scheme and not scheme:match("^%a$") then -- avoid treating "c:" as a scheme
    out.scheme = scheme:lower()
    rest = after
  end
  local host, path = rest:match("^//([^/]*)(.*)$")
  if host then
    out.host = host
    rest = path
  end
  out.path = rest
  return out
end

function M.format(p)
  local s = ""
  if p.scheme then
    s = s .. p.scheme .. ":"
  end
  if p.host then
    s = s .. "//" .. p.host
  end
  s = s .. (p.path or "")
  if p.query then
    s = s .. "?" .. p.query
  end
  if p.fragment then
    s = s .. "#" .. p.fragment
  end
  return s
end

local function remove_dot_segments(path)
  local out = {}
  local abs = path:sub(1, 1) == "/"
  local trailing = path:match("/%.?%.?$") ~= nil or path == "." or path == ".."
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      if #out > 0 then
        table.remove(out)
      end
    elseif seg ~= "." then
      table.insert(out, seg)
    end
  end
  local res = table.concat(out, "/")
  if abs then
    res = "/" .. res
  end
  if trailing and #out > 0 then
    res = res .. "/"
  end
  if res == "" and abs then
    res = "/"
  end
  return res
end

local function merge(base, ref_path)
  if base.host and (base.path == "" or base.path == nil) then
    return "/" .. ref_path
  end
  local dir = (base.path or ""):match("^(.*/)") or ""
  return dir .. ref_path
end

--- Resolve `ref` against absolute `base`.
function M.join(base, ref)
  if not ref or ref == "" then
    return base
  end
  local r = M.parse(ref)
  if r.scheme then
    r.path = remove_dot_segments(r.path)
    return M.format(r)
  end
  local b = M.parse(base)
  local t = { scheme = b.scheme }
  if r.host then
    t.host, t.path, t.query = r.host, remove_dot_segments(r.path), r.query
  else
    t.host = b.host
    if r.path == "" then
      t.path = b.path
      t.query = r.query or b.query
    else
      if r.path:sub(1, 1) == "/" then
        t.path = remove_dot_segments(r.path)
      else
        t.path = remove_dot_segments(merge(b, r.path))
      end
      t.query = r.query
    end
  end
  t.fragment = r.fragment
  return M.format(t)
end

function M.host(u)
  return (M.parse(u).host or ""):lower()
end

function M.strip_fragment(u)
  return (u:gsub("#.*$", ""))
end

function M.fragment(u)
  return u:match("#(.*)$")
end

function M.encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

function M.decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

function M.is_http(u)
  return u:match("^https?://") ~= nil
end

return M
