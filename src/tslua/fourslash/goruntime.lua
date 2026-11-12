-- Lua-only support code (no Go counterpart file): the small Go runtime/stdlib surface used by the
-- fourslash tests converted from Go by scripts/gen/fourslash.mjs (tests/fourslash/**) and by the
-- converted tests/util package. Index values stay 0-based like Go (docs/PORTING.md).
local core = require("tslua.core")

local M = {}

-- A construct the converter could not translate; failing loudly keeps the test from passing.
function M.Unsupported(what)
    error("not implemented: converted Go test uses an unsupported construct: " .. tostring(what), 2)
end

-- Go `defer deferred()` followed by the rest of the function body (body): runs body, then the
-- deferred call, also when body raised (the error is re-raised afterwards, like a panic or
-- t.FailNow unwinding through deferred calls).
function M.Defer(deferred, body)
    local results = table.pack(xpcall(body, function(err)
        if type(err) == "string" then
            return debug.traceback(err, 2)
        end
        return err
    end))
    deferred()
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

-- for i, v := range xs (xs may be a nil slice). Yields the 1-based storage index.
function M.ipairs(xs)
    if xs == nil then
        return function() return nil end
    end
    return ipairs(xs)
end

function M.pairs(m)
    if m == nil then
        return function() return nil end
    end
    return pairs(m)
end

-- for i, r := range s: 0-based byte index and rune.
function M.runes(s)
    local pos = 0
    local n = #s
    return function()
        if pos >= n then
            return nil
        end
        local r, size = core.DecodeRune(s, pos)
        local i = pos
        pos = pos + size
        return i, r
    end
end

-- Go integer division and remainder (truncated toward zero).
function M.idiv(a, b)
    local q = a // b
    if q < 0 and q * b ~= a then
        q = q + 1
    end
    return q
end

function M.imod(a, b)
    return a - M.idiv(a, b) * b
end

function M.toInt(x)
    if x >= 0 then
        return math.floor(x)
    end
    return math.ceil(x)
end

function M.bytesToString(bytes)
    if type(bytes) == "string" then
        return bytes
    end
    local parts = {}
    for i, b in ipairs(bytes) do
        parts[i] = string.char(b)
    end
    return table.concat(parts)
end

-- v, ok := m[k]
function M.MapLookup(m, k, zero)
    if m == nil then
        return zero, false
    end
    local v = m[k]
    if v == nil then
        return zero, false
    end
    return v, true
end

function M.delete(m, k)
    if m ~= nil then
        m[k] = nil
    end
end

function M.unpack(xs)
    if xs == nil then
        return
    end
    return table.unpack(xs)
end

function M.len(x)
    if x == nil then
        return 0
    end
    if type(x) == "string" then
        return #x
    end
    if #x > 0 or next(x) == nil then
        return #x
    end
    local n = 0
    for _ in pairs(x) do
        n = n + 1
    end
    return n
end

-- append(s, x...) appends in place to a non-nil s and returns it (the `xs = append(xs, x)` idiom;
-- Go may alias too). A nil s starts a new array.
function M.append(s, ...)
    local result = s or {}
    local n = #result
    for i = 1, select("#", ...) do
        result[n + i] = select(i, ...)
    end
    return result
end

function M.appendSlice(s, other)
    local result = s or {}
    if other ~= nil then
        if type(other) == "string" then
            for i = 1, #other do
                result[#result + 1] = string.byte(other, i)
            end
        else
            table.move(other, 1, #other, #result + 1, result)
        end
    end
    return result
end

function M.makeSlice(n, zero)
    local result = {}
    for i = 1, n do
        result[i] = zero()
    end
    return result
end

function M.slice(xs, lo, hi)
    local result = {}
    if xs == nil then
        return nil
    end
    hi = hi or #xs
    for i = lo + 1, hi do
        result[#result + 1] = xs[i]
    end
    return result
end

-- Go defers registered in nested blocks: body runs, then the deferred calls in reverse order,
-- also when body raised (the error is re-raised afterwards).
function M.WithDefers(defers, body)
    local results = table.pack(xpcall(body, function(err)
        if type(err) == "string" then
            return debug.traceback(err, 2)
        end
        return err
    end))
    for i = #defers, 1, -1 do
        defers[i]()
    end
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

-- Go struct value copy (shallow; keeps the metatable).
function M.CloneStruct(v)
    if type(v) ~= "table" then
        return v
    end
    local c = {}
    for k, x in pairs(v) do
        c[k] = x
    end
    return setmetatable(c, getmetatable(v))
end

-- Type switch / type assertion helpers. IsStruct: a *T (or T) of the Lua class mod.name; when
-- the package has no class table for the type, any table without a metatable matches.
function M.IsStruct(v, mod, name)
    if type(v) ~= "table" then
        return false
    end
    local class = require(mod)[name]
    local mt = getmetatable(v)
    if type(class) == "table" and class.__index ~= nil then
        return mt == class
    end
    return mt == nil and (next(v) == nil or v[1] == nil)
end

-- IsSlice: a Lua array (no metatable); elemCheck, when given, tests the first element.
function M.IsSlice(v, elemCheck)
    if type(v) ~= "table" or getmetatable(v) ~= nil then
        return false
    end
    if next(v) ~= nil and v[1] == nil then
        return false
    end
    if elemCheck ~= nil and v[1] ~= nil then
        return elemCheck(v[1])
    end
    return true
end

function M.IsMap(v)
    return type(v) == "table" and getmetatable(v) == nil
end

-- A converted test file (path relative to the repository root), loaded once: other files of
-- the same Go test package refer to its package-level declarations through .P.
local testFiles = {}

function M.TestFile(rel)
    local mod = testFiles[rel]
    if mod == nil then
        local repo = require("tslua.repo")
        local chunk, err = loadfile(repo.TsluaRootPath() .. "/" .. rel)
        if chunk == nil then
            error(err, 0)
        end
        mod = chunk()
        testFiles[rel] = mod
    end
    return mod
end

function M.NewBuilder()
    return core.NewStringBuilder()
end

-- ---------------------------------------------------------------------------
-- fmt

local function quote(s)
    local parts = { '"' }
    for _, r in utf8.codes(s, true) do
        local c
        if r == 34 then
            c = '\\"'
        elseif r == 92 then
            c = "\\\\"
        elseif r == 10 then
            c = "\\n"
        elseif r == 13 then
            c = "\\r"
        elseif r == 9 then
            c = "\\t"
        elseif r < 0x20 or r == 0x7f then
            c = string.format("\\x%02x", r)
        else
            c = utf8.char(r)
        end
        parts[#parts + 1] = c
    end
    parts[#parts + 1] = '"'
    return table.concat(parts)
end

local function formatValue(v, verb)
    if verb == "q" then
        return quote(tostring(v))
    end
    if v == nil then
        return "<nil>"
    end
    local tv = type(v)
    if tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if math.type(v) == "integer" then
            return string.format("%d", v)
        end
        local jsnum = require("tslua.jsnum")
        return jsnum.Number_String(v)
    elseif tv == "table" then
        if v.Error ~= nil then
            return v:Error()
        end
        if v.String ~= nil then
            return v:String()
        end
        local parts = {}
        for i, x in ipairs(v) do
            parts[i] = formatValue(x, "v")
        end
        return "[" .. table.concat(parts, " ") .. "]"
    end
    return tostring(v)
end

M.fmt = {}

function M.fmt.Sprintf(format, ...)
    local args = table.pack(...)
    local i = 0
    return (string.gsub(format, "%%([%-%+# 0]*%d*%.?%d*)([%a%%])", function(_, verb)
        if verb == "%" then
            return "%"
        end
        i = i + 1
        return formatValue(args[i], verb)
    end))
end

function M.fmt.Sprint(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = formatValue(select(i, ...), "v")
    end
    return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- strings / strconv

M.strings = {}

function M.strings.Index(s, sub)
    local i = string.find(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

function M.strings.Contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

function M.strings.HasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function M.strings.HasSuffix(s, suffix)
    return suffix == "" or string.sub(s, -#suffix) == suffix
end

function M.strings.Join(xs, sep)
    if xs == nil then
        return ""
    end
    return table.concat(xs, sep)
end

function M.strings.Repeat(s, n)
    return string.rep(s, n)
end

function M.strings.ReplaceAll(s, old, new)
    if old == "" then
        error("not implemented: strings.ReplaceAll with empty old")
    end
    local parts = {}
    local pos = 1
    while true do
        local a, b = string.find(s, old, pos, true)
        if a == nil then
            break
        end
        parts[#parts + 1] = string.sub(s, pos, a - 1)
        parts[#parts + 1] = new
        pos = b + 1
    end
    parts[#parts + 1] = string.sub(s, pos)
    return table.concat(parts)
end

M.strconv = {}

function M.strconv.Quote(s)
    return quote(s)
end

function M.strconv.Itoa(i)
    return string.format("%d", i)
end

-- ---------------------------------------------------------------------------
-- slices

M.slices = {}

function M.slices.Concat(...)
    local result = nil
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if s ~= nil and #s > 0 then
            result = result or {}
            table.move(s, 1, #s, #result + 1, result)
        end
    end
    if result == nil and select("#", ...) > 0 then
        return nil
    end
    return result
end

function M.slices.Clone(s)
    if s == nil then
        return nil
    end
    return table.move(s, 1, #s, 1, {})
end

-- Stable merge sort with a Go cmp function (negative/zero/positive).
local function mergeSort(xs, cmp)
    local n = #xs
    if n < 2 then
        return
    end
    local tmp = {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width, n + 1)
            local hi = math.min(i + 2 * width, n + 1)
            local a, b, k = i, mid, i
            while a < mid and b < hi do
                if cmp(xs[b], xs[a]) < 0 then
                    tmp[k] = xs[b]
                    b = b + 1
                else
                    tmp[k] = xs[a]
                    a = a + 1
                end
                k = k + 1
            end
            while a < mid do
                tmp[k] = xs[a]
                a = a + 1
                k = k + 1
            end
            while b < hi do
                tmp[k] = xs[b]
                b = b + 1
                k = k + 1
            end
            i = i + 2 * width
        end
        for j = 1, n do
            xs[j] = tmp[j]
        end
        width = width * 2
    end
end

function M.slices.SortStableFunc(xs, cmp)
    if xs ~= nil then
        mergeSort(xs, cmp)
    end
end

-- Go's sort is unstable, but every caller in the tests orders by a total order.
M.slices.SortFunc = M.slices.SortStableFunc

function M.slices.Contains(xs, x)
    for _, v in M.ipairs(xs) do
        if v == x then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- gotest.tools/v3/assert

M.assert = {}

local function assertMessage(msgAndArgs, n)
    if n == 0 then
        return ""
    end
    if n == 1 then
        return tostring(msgAndArgs[1])
    end
    return M.fmt.Sprintf(table.unpack(msgAndArgs, 1, n))
end

function M.assert.Equal(t, x, y, ...)
    t:Helper()
    if x ~= y then
        local msg = assertMessage({ ... }, select("#", ...))
        local text = "assertion failed: " .. M.fmt.Sprintf("%v", x) .. " (actual) != " .. M.fmt.Sprintf("%v", y) .. " (expected)"
        if msg ~= "" then
            text = text .. ": " .. msg
        end
        t:Fatal(text)
    end
end

function M.assert.Assert(t, cond, ...)
    t:Helper()
    if not cond then
        local msg = assertMessage({ ... }, select("#", ...))
        t:Fatal("assertion failed" .. (msg ~= "" and (": " .. msg) or ""))
    end
end

function M.assert.Check(t, cond, ...)
    t:Helper()
    if not cond then
        local msg = assertMessage({ ... }, select("#", ...))
        t:Error("assertion failed" .. (msg ~= "" and (": " .. msg) or ""))
        return false
    end
    return true
end

function M.assert.DeepEqual(t, x, y, ...)
    t:Helper()
    local diff = M.cmp.Diff(x, y)
    if diff ~= "" then
        t:Fatal("assertion failed: \n" .. diff)
    end
end

function M.assert.NilError(t, err, ...)
    t:Helper()
    if err ~= nil then
        t:Fatal("assertion failed: error is not nil: " .. M.fmt.Sprintf("%v", err))
    end
end

-- ---------------------------------------------------------------------------
-- github.com/google/go-cmp/cmp (Diff with FilterPath/Ignore options on the last path step)

M.cmp = {}

local IgnoreOption = {}

function M.cmp.Ignore()
    return IgnoreOption
end

-- PathStep: { name = ".Field" or "[i]" or "[key]" }
local PathStep = {}
PathStep.__index = PathStep

function PathStep:String()
    return self.name
end

function M.cmp.Path_Last(p)
    return p[#p] or setmetatable({ name = "" }, PathStep)
end

function M.cmp.FilterPath(filter, opt)
    return { filter = filter, opt = opt }
end

-- Go field names of Lua fields (lowerCamel -> Go name) are not recoverable in general; the
-- path step uses the Lua field name with its first letter upper-cased, which matches the Go
-- name for the fields the harness filters (Kind, SortText, Data, Detail, ...).
local function goFieldName(k)
    if type(k) ~= "string" then
        return k
    end
    return string.upper(string.sub(k, 1, 1)) .. string.sub(k, 2)
end

local function ignored(opts, path)
    for _, o in ipairs(opts) do
        if o.opt == IgnoreOption and o.filter(path) then
            return true
        end
    end
    return false
end

local function show(v)
    if type(v) == "string" then
        return quote(v)
    end
    if type(v) == "table" then
        local ok, json = pcall(require, "tslua.json")
        if ok then
            local okm, s = pcall(json.Marshal, v)
            if okm and type(s) == "string" then
                return s
            end
        end
    end
    return formatValue(v, "v")
end

local function diff(x, y, opts, path, out)
    if ignored(opts, path) then
        return
    end
    if rawequal(x, y) then
        return
    end
    local where = {}
    for i, step in ipairs(path) do
        where[i] = step.name
    end
    local loc = table.concat(where)
    if type(x) ~= "table" or type(y) ~= "table" then
        if x ~= y then
            out[#out + 1] = "  " .. (loc == "" and "value" or loc) .. ":\n  - " .. show(x) .. "\n  + " .. show(y)
        end
        return
    end
    local keys, seen = {}, {}
    for k in pairs(x) do
        if not seen[k] then
            seen[k] = true
            keys[#keys + 1] = k
        end
    end
    for k in pairs(y) do
        if not seen[k] then
            seen[k] = true
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
            return a < b
        end
        return type(a) < type(b)
    end)
    for _, k in ipairs(keys) do
        local name
        if type(k) == "number" then
            name = "[" .. tostring(k - 1) .. "]"
        else
            name = "." .. tostring(goFieldName(k))
        end
        path[#path + 1] = setmetatable({ name = name }, PathStep)
        diff(x[k], y[k], opts, path, out)
        path[#path] = nil
    end
end

-- Diff returns "" when x and y are deeply equal (ignoring the filtered paths), else a report.
function M.cmp.Diff(x, y, ...)
    local opts = { ... }
    local out = {}
    diff(x, y, opts, {}, out)
    if #out == 0 then
        return ""
    end
    return "(-actual +expected):\n" .. table.concat(out, "\n")
end

function M.cmp.Compare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

return M
