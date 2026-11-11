-- Lua-only support code for the compiler package (no Go counterpart).
--
--   * Go strings.HasPrefix/HasSuffix/TrimPrefix/TrimSuffix/Contains -> compiler.hasPrefix, ...
--   * module.ModeAwareCache[T] (map[ModeAwareCacheKey]T) -> a Lua table keyed by
--     compiler.modeAwareCacheKey(name, mode); compiler.decodeModeAwareCacheKey(key) -> name, mode.
--     compiler.modeAwareCachePairs(cache) iterates (name, mode, value) in a deterministic order.
--   * module.PackageId used as a map key -> compiler.packageIdKey(id)
--   * deterministic iteration of Go maps keyed by strings -> compiler.sortedKeys(t)
--   * Go `args ...any` stored in slices -> compiler.unpackArgs(args)
local compiler = require("tslua.compiler")

function compiler.hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function compiler.hasSuffix(s, suffix)
    return suffix == "" or string.sub(s, -#suffix) == suffix
end

function compiler.trimPrefix(s, prefix)
    if compiler.hasPrefix(s, prefix) then
        return string.sub(s, #prefix + 1)
    end
    return s
end

function compiler.trimSuffix(s, suffix)
    if suffix ~= "" and compiler.hasSuffix(s, suffix) then
        return string.sub(s, 1, #s - #suffix)
    end
    return s
end

function compiler.contains(s, substr)
    return string.find(s, substr, 1, true) ~= nil
end

-- strings.Join(xs, sep)
function compiler.join(xs, sep)
    if xs == nil then
        return ""
    end
    return table.concat(xs, sep)
end

function compiler.modeAwareCacheKey(name, mode)
    return tostring(mode) .. "|" .. name
end

function compiler.decodeModeAwareCacheKey(key)
    local mode, name = string.match(key, "^(%-?%d+)|(.*)$")
    return name, math.tointeger(tonumber(mode))
end

-- Iterates a ModeAwareCache as (name, mode, value), sorted by key for determinism.
function compiler.modeAwareCachePairs(cache)
    local keys = compiler.sortedKeys(cache)
    local i = 0
    return function()
        i = i + 1
        local key = keys[i]
        if key == nil then
            return nil
        end
        local name, mode = compiler.decodeModeAwareCacheKey(key)
        return name, mode, cache[key]
    end
end

function compiler.packageIdName(id)
    if id == nil then
        return ""
    end
    return id.name or ""
end

function compiler.packageIdKey(id)
    return (id.name or "") .. "\0" .. (id.subModuleName or "") .. "\0" .. (id.version or "") .. "\0" .. (id.peerDependencies or "")
end

-- (*PackageId).String(), tolerant of a nil/zero PackageId.
function compiler.packageIdString(id)
    if id.String ~= nil then
        return id:String()
    end
    local name = id.name or ""
    if (id.subModuleName or "") ~= "" then
        name = name .. "/" .. id.subModuleName
    end
    return name .. "@" .. (id.version or "") .. (id.peerDependencies or "")
end

function compiler.sortedKeys(t)
    local keys = {}
    if t == nil then
        return keys
    end
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- Number of entries of a Go map represented as a Lua table.
function compiler.mapLen(t)
    if t == nil then
        return 0
    end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

function compiler.unpackArgs(args)
    if args == nil then
        return
    end
    return table.unpack(args, 1, args.n or #args)
end

-- Go fmt.Fprint(w, ...) / fmt.Fprintln(w, ...) on an io.Writer (a table with :Write(s)).
function compiler.fprint(w, ...)
    local parts = table.pack(...)
    local buf = {}
    for i = 1, parts.n do
        buf[i] = tostring(parts[i])
    end
    w:Write(table.concat(buf))
end

function compiler.fprintln(w, ...)
    local parts = table.pack(...)
    local buf = {}
    for i = 1, parts.n do
        buf[i] = tostring(parts[i])
    end
    w:Write(table.concat(buf, " ") .. "\n")
end

-- Stable merge sort with a Go-style comparator (cmp(a, b) < 0 means a sorts first). Used where Go
-- uses slices.SortFunc so that ties keep a deterministic (input) order.
function compiler.sortStable(xs, cmp)
    local n = #xs
    if n < 2 then
        return xs
    end
    local src, dst = xs, {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width, n + 1)
            local hi = math.min(i + 2 * width, n + 1)
            local a, b, k = i, mid, i
            while a < mid and b < hi do
                if cmp(src[b], src[a]) < 0 then
                    dst[k] = src[b]
                    b = b + 1
                else
                    dst[k] = src[a]
                    a = a + 1
                end
                k = k + 1
            end
            while a < mid do
                dst[k] = src[a]
                a = a + 1
                k = k + 1
            end
            while b < hi do
                dst[k] = src[b]
                b = b + 1
                k = k + 1
            end
            i = i + 2 * width
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= xs then
        for i = 1, n do
            xs[i] = src[i]
        end
    end
    return xs
end

-- Go json.Marshal of a string (HTML-safe escaping, like encoding/json).
function compiler.jsonMarshalString(s)
    local out = { '"' }
    local i = 1
    local n = #s
    while i <= n do
        local c = string.byte(s, i)
        if c == 0x22 then
            out[#out + 1] = '\\"'
        elseif c == 0x5C then
            out[#out + 1] = "\\\\"
        elseif c == 0x0A then
            out[#out + 1] = "\\n"
        elseif c == 0x0D then
            out[#out + 1] = "\\r"
        elseif c == 0x09 then
            out[#out + 1] = "\\t"
        elseif c < 0x20 or c == 0x3C or c == 0x3E or c == 0x26 then
            out[#out + 1] = string.format("\\u%04x", c)
        elseif c == 0xE2 and string.byte(s, i + 1) == 0x80 and (string.byte(s, i + 2) == 0xA8 or string.byte(s, i + 2) == 0xA9) then
            out[#out + 1] = string.byte(s, i + 2) == 0xA8 and "\\u2028" or "\\u2029"
            i = i + 2
        else
            out[#out + 1] = string.char(c)
        end
        i = i + 1
    end
    out[#out + 1] = '"'
    return table.concat(out)
end
