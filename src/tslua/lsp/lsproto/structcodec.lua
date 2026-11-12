local lsproto = require("tslua.lsp.lsproto")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")

-- Go marshals and unmarshals LSP values with encoding/json/v2 reflection plus the generated
-- MarshalJSONTo/UnmarshalJSONFrom methods. Lua has no reflection, so lsp_generated.lua describes
-- every type with Go type strings and this file interprets them. Value model (Go -> Lua):
--   * struct (pointer or value)  -> table with the lowerCamelCase Go field names, metatable
--                                   lsproto.<Name> (decoded values and lsproto.<Name>{...}
--                                   constructor results; plain tables marshal the same way)
--   * union struct               -> table with exactly one arm field set (Go: one non-nil
--                                   pointer field), e.g. { integer = 1 } for IntegerOrString;
--                                   no arm set = null for nullable unions
--   * *T / []T / map[K]V / any   -> the value or nil (nil slice marshals as [], nil map as {})
--   * string/int32/uint32/float64/bool/enums -> Lua string/integer/number/boolean
--   * literal types              -> the sentinel lsproto.<Name> (any non-nil value works)
--   * json.Value                 -> jsonrpc.Value
-- Missing non-pointer fields read as their Go zero value when marshaling.
--
-- Type strings: "*T", "[]T", "[2]T", "map[K]V", "struct{}", base names (string, bool, int32,
-- uint32, uint64, float64, any, DocumentUri, URI, Method), and named lsproto types (structs,
-- unions, literals, enums, aliases, and the custom types registered below).

lsproto.structSpecs = {}
lsproto.unionSpecs = {}
lsproto.literalSpecs = {}
lsproto.aliasSpecs = {}
lsproto.enumSpecs = {}
lsproto.customSpecs = {}

local baseTypes = {
    string = "string",
    DocumentUri = "string",
    URI = "string",
    Method = "string",
    int32 = "int",
    uint32 = "int",
    uint64 = "int",
    float64 = "float",
    bool = "bool",
    any = "any",
}

local intRanges = {
    int32 = { -2147483648, 2147483647 },
    uint32 = { 0, 4294967295 },
    uint64 = { 0, math.maxinteger },
}

---- Classes

local classMeta = {}

function classMeta.__call(class, t)
    return lsproto.construct(class.__name, t or {})
end

-- Returns the class table lsproto.<name>, creating it on first use.
function lsproto.classFor(name, class)
    local existing = class or rawget(lsproto, name)
    if existing == nil then
        existing = {}
        lsproto[name] = existing
    end
    existing.__index = existing
    existing.__name = name
    if existing.MarshalJSON == nil then
        existing.MarshalJSON = function(self)
            return lsproto.MarshalAs(name, self)
        end
    end
    if getmetatable(existing) == nil then
        setmetatable(existing, classMeta)
    end
    return existing
end

-- spec.fields entries are { luaField, goType, jsonTag [, lspTag] }.
function lsproto.defineStruct(name, strict, fields, class)
    local spec = {
        name = name,
        strict = strict,
        fields = {},
        byName = {},
        requiredNames = {},
        class = lsproto.classFor(name, class),
    }
    for _, f in ipairs(fields) do
        local jsonName, opts = string.match(f[3], "^([^,]*),?(.*)$")
        local fs = {
            field = f[1],
            goType = f[2],
            jsonName = jsonName,
            omitzero = opts == "omitzero",
            required = false,
            rejectNull = false,
        }
        local nullable = false
        for marker in string.gmatch(f[4] or "", "[^,]+") do
            if marker == "required" then
                fs.required = true
                spec.requiredNames[#spec.requiredNames + 1] = jsonName
            elseif marker == "nullable" then
                nullable = true
            end
        end
        -- A nilable field (pointer/slice/map) rejects an explicit JSON null
        -- unless the spec marks it nullable.
        local c = string.sub(f[2], 1, 1)
        if c == "*" or string.sub(f[2], 1, 2) == "[]" or string.sub(f[2], 1, 4) == "map[" then
            fs.rejectNull = not nullable
        end
        spec.fields[#spec.fields + 1] = fs
        if jsonName ~= "" and jsonName ~= "-" then
            spec.byName[jsonName] = fs
        end
    end
    lsproto.structSpecs[name] = spec
    return spec
end

-- Resolved* structs: all fields omitzero values; resolvedFrom names the source structure.
function lsproto.defineResolved(name, from, fields)
    local spec = lsproto.defineStruct(name, false, fields)
    spec.resolvedFrom = from
    return spec
end

-- arms are { luaField, memberGoType } (the Go field type is *memberGoType).
function lsproto.defineUnion(name, nullable, arms, unmarshal)
    local spec = { name = name, nullable = nullable, arms = {}, unmarshal = unmarshal, class = lsproto.classFor(name) }
    for _, a in ipairs(arms) do
        spec.arms[#spec.arms + 1] = { field = a[1], goType = a[2] }
    end
    lsproto.unionSpecs[name] = spec
    return spec
end

local literalMeta = {
    __call = function(self)
        return self
    end,
}

function lsproto.defineLiteral(name, raw)
    local lit = rawget(lsproto, name) or {}
    lit.__name = name
    lit.MarshalJSON = function()
        return raw, nil
    end
    setmetatable(lit, literalMeta)
    lsproto[name] = lit
    lsproto.literalSpecs[name] = { name = name, raw = raw, value = lit }
end

function lsproto.defineAlias(name, goType)
    lsproto.aliasSpecs[name] = goType
end

function lsproto.defineEnum(name, base)
    lsproto.enumSpecs[name] = base
end

-- spec: { encode = function(buf, v) -> err, decode = function(dec) -> v, err,
--         zero = function() -> v, isZero = function(v) -> bool }
function lsproto.defineCustom(name, spec)
    lsproto.customSpecs[name] = spec
end

---- Type strings

local typeCache = {}

-- Index (1-based) of the "]" matching the "[" at 1-based position i.
local function matchingBracket(s, i)
    local depth = 0
    for j = i, #s do
        local c = string.sub(s, j, j)
        if c == "[" then
            depth = depth + 1
        elseif c == "]" then
            depth = depth - 1
            if depth == 0 then
                return j
            end
        end
    end
    error("lsproto: malformed type " .. s, 0)
end

-- Parses a Go type string into a node { k = "ptr"|"slice"|"array"|"map"|"empty"|"named", ... }.
function lsproto.parseType(s)
    local t = typeCache[s]
    if t ~= nil then
        return t
    end
    if string.sub(s, 1, 1) == "*" then
        t = { k = "ptr", elem = lsproto.parseType(string.sub(s, 2)), s = s }
    elseif string.sub(s, 1, 2) == "[]" then
        t = { k = "slice", elem = lsproto.parseType(string.sub(s, 3)), s = s }
    elseif string.match(s, "^%[%d+%]") then
        local n, rest = string.match(s, "^%[(%d+)%](.*)$")
        t = { k = "array", n = tonumber(n), elem = lsproto.parseType(rest), s = s }
    elseif string.sub(s, 1, 4) == "map[" then
        local close = matchingBracket(s, 4)
        t = { k = "map", key = lsproto.parseType(string.sub(s, 5, close - 1)), elem = lsproto.parseType(string.sub(s, close + 1)), s = s }
    elseif s == "struct{}" then
        t = { k = "empty", s = s }
    else
        t = { k = "named", name = s, s = s }
    end
    typeCache[s] = t
    return t
end

-- Resolves a named node to its definition: sets t.r to one of "base", "struct", "union",
-- "literal", "custom" (with t.spec / t.base), following aliases and enums.
local function resolveNamed(t)
    if t.r ~= nil then
        return t
    end
    local name = t.name
    local alias = lsproto.aliasSpecs[name]
    if alias ~= nil then
        local target = lsproto.parseType(alias)
        if target.k == "named" then
            resolveNamed(target)
            t.r, t.spec, t.base, t.baseName = target.r, target.spec, target.base, target.baseName
        else
            t.r = "alias"
            t.target = target
        end
        return t
    end
    local enumBase = lsproto.enumSpecs[name]
    if enumBase ~= nil then
        t.r = "base"
        t.base = baseTypes[enumBase]
        t.baseName = enumBase
        return t
    end
    if baseTypes[name] ~= nil then
        t.r = "base"
        t.base = baseTypes[name]
        t.baseName = name
    elseif lsproto.structSpecs[name] ~= nil then
        t.r = "struct"
        t.spec = lsproto.structSpecs[name]
    elseif lsproto.unionSpecs[name] ~= nil then
        t.r = "union"
        t.spec = lsproto.unionSpecs[name]
    elseif lsproto.literalSpecs[name] ~= nil then
        t.r = "literal"
        t.spec = lsproto.literalSpecs[name]
    elseif lsproto.customSpecs[name] ~= nil then
        t.r = "custom"
        t.spec = lsproto.customSpecs[name]
    else
        error("lsproto: unknown type " .. name, 0)
    end
    return t
end

local function node(goType)
    local t = goType
    if type(t) == "string" then
        t = lsproto.parseType(t)
    end
    if t.k == "named" then
        resolveNamed(t)
        if t.r == "alias" then
            return node(t.target)
        end
    end
    return t
end

---- Zero values

function lsproto.zeroOf(t)
    t = node(t)
    local k = t.k
    if k == "ptr" or k == "slice" or k == "map" then
        return nil
    elseif k == "array" then
        local arr = {}
        for i = 1, t.n do
            arr[i] = lsproto.zeroOf(t.elem)
        end
        return arr
    elseif k == "empty" then
        return {}
    end
    local r = t.r
    if r == "base" then
        local b = t.base
        if b == "string" then
            return ""
        elseif b == "int" or b == "float" then
            return 0
        elseif b == "bool" then
            return false
        end
        return nil
    elseif r == "struct" then
        return lsproto.construct(t.name, {})
    elseif r == "union" then
        return setmetatable({}, t.spec.class)
    elseif r == "literal" then
        return t.spec.value
    elseif r == "custom" then
        if t.spec.zero ~= nil then
            return t.spec.zero()
        end
        return nil
    end
    return nil
end

-- Zero value of a Go type string (Lua-only API).
function lsproto.Zero(goType)
    return lsproto.zeroOf(goType)
end

-- Sets the metatable of t to the class of the named struct or union and fills in the Go zero
-- value of every missing field that is not nilable. Returns t.
function lsproto.construct(name, t)
    local spec = lsproto.structSpecs[name]
    if spec == nil then
        local u = lsproto.unionSpecs[name]
        if u == nil then
            error("lsproto: " .. name .. " is not a struct or union type", 0)
        end
        return setmetatable(t, u.class)
    end
    for _, f in ipairs(spec.fields) do
        if t[f.field] == nil then
            t[f.field] = lsproto.zeroOf(f.goType)
        end
    end
    return setmetatable(t, spec.class)
end

---- isZero (encoding/json/v2 omitzero)

function lsproto.isZero(t, v)
    t = node(t)
    if v == nil then
        return true
    end
    local k = t.k
    if k == "ptr" or k == "slice" or k == "map" then
        return false
    elseif k == "array" then
        for i = 1, t.n do
            if not lsproto.isZero(t.elem, v[i]) then
                return false
            end
        end
        return true
    elseif k == "empty" then
        return true
    end
    local r = t.r
    if r == "base" then
        local b = t.base
        if b == "string" then
            return v == ""
        elseif b == "int" or b == "float" then
            return v == 0
        elseif b == "bool" then
            return v == false
        end
        return false
    elseif r == "struct" then
        for _, f in ipairs(t.spec.fields) do
            if not lsproto.isZero(f.goType, v[f.field]) then
                return false
            end
        end
        return true
    elseif r == "union" then
        for _, a in ipairs(t.spec.arms) do
            if v[a.field] ~= nil then
                return false
            end
        end
        return true
    elseif r == "literal" then
        return true
    elseif r == "custom" then
        if t.spec.isZero ~= nil then
            return t.spec.isZero(v)
        end
        return false
    end
    return false
end

---- Encoding

local encode

local function encodeStruct(buf, spec, v)
    if spec.marshal ~= nil then
        return spec.marshal(buf, v or {})
    end
    buf[#buf + 1] = "{"
    local first = true
    for _, f in ipairs(spec.fields) do
        if f.jsonName ~= "-" then
            local fv = v ~= nil and v[f.field] or nil
            if not (f.omitzero and lsproto.isZero(f.goType, fv)) then
                if not first then
                    buf[#buf + 1] = ","
                end
                first = false
                buf[#buf + 1] = json.QuoteString(f.jsonName)
                buf[#buf + 1] = ":"
                local err = encode(buf, f.goType, fv)
                if err ~= nil then
                    return err
                end
            end
        end
    end
    buf[#buf + 1] = "}"
    return nil
end

-- marshalUnion: writes the single set arm; if nullable, an empty union marshals as null,
-- otherwise an empty union is a programming error.
local function encodeUnion(buf, spec, v)
    local set
    local count = 0
    if v ~= nil then
        for _, a in ipairs(spec.arms) do
            if v[a.field] ~= nil then
                count = count + 1
                if set == nil then
                    set = a
                end
            end
        end
    end
    if spec.nullable then
        lsproto.assertAtMostOne("more than one element of " .. spec.name .. " is set", count)
        if set == nil then
            buf[#buf + 1] = "null"
            return nil
        end
    else
        lsproto.assertOnlyOne("exactly one element of " .. spec.name .. " should be set", count)
    end
    return encode(buf, set.goType, v[set.field])
end

local function sortedKeys(m)
    local keys = {}
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

function encode(buf, t, v)
    t = node(t)
    local k = t.k
    if k == "ptr" then
        if v == nil or v == json.Null then
            buf[#buf + 1] = "null"
            return nil
        end
        return encode(buf, t.elem, v)
    elseif k == "slice" or k == "array" then
        buf[#buf + 1] = "["
        local n = k == "array" and t.n or (v ~= nil and #v or 0)
        for i = 1, n do
            if i > 1 then
                buf[#buf + 1] = ","
            end
            local e = v ~= nil and v[i] or nil
            if e == json.Null then
                e = nil
            end
            local err = encode(buf, t.elem, e)
            if err ~= nil then
                return err
            end
        end
        buf[#buf + 1] = "]"
        return nil
    elseif k == "map" then
        buf[#buf + 1] = "{"
        if v ~= nil then
            local first = true
            for _, key in ipairs(sortedKeys(v)) do
                if not first then
                    buf[#buf + 1] = ","
                end
                first = false
                buf[#buf + 1] = json.QuoteString(tostring(key))
                buf[#buf + 1] = ":"
                local err = encode(buf, t.elem, v[key])
                if err ~= nil then
                    return err
                end
            end
        end
        buf[#buf + 1] = "}"
        return nil
    elseif k == "empty" then
        buf[#buf + 1] = "{}"
        return nil
    end
    local r = t.r
    if r == "base" then
        local b = t.base
        if b == "string" then
            buf[#buf + 1] = json.QuoteString(v or "")
        elseif b == "int" then
            local i = math.tointeger(v or 0)
            if i == nil then
                return "json: cannot marshal " .. tostring(v) .. " as Go " .. t.baseName
            end
            buf[#buf + 1] = tostring(i)
        elseif b == "float" then
            local s, err = json.formatNumber(v or 0)
            if err ~= nil then
                return err
            end
            buf[#buf + 1] = s
        elseif b == "bool" then
            buf[#buf + 1] = v and "true" or "false"
        else
            if v == nil or v == json.Null then
                buf[#buf + 1] = "null"
                return nil
            end
            return json.encodeValue(buf, v)
        end
        return nil
    elseif r == "struct" then
        return encodeStruct(buf, t.spec, v)
    elseif r == "union" then
        return encodeUnion(buf, t.spec, v)
    elseif r == "literal" then
        buf[#buf + 1] = t.spec.raw
        return nil
    elseif r == "custom" then
        return t.spec.encode(buf, v)
    end
    return "lsproto: cannot marshal " .. t.s
end

lsproto.encode = encode

-- json.Marshal of a value of the given Go type (Lua-only API). Returns (string, err).
function lsproto.MarshalAs(goType, v)
    local buf = {}
    local err = encode(buf, goType, v)
    if err ~= nil then
        return nil, err
    end
    return table.concat(buf), nil
end

-- A value that tslua.json marshals as the given Go type (for values placed in `any` slots).
local Typed = {}
Typed.__index = Typed
lsproto.Typed = Typed

function Typed:MarshalJSON()
    return lsproto.MarshalAs(self.goType, self.value)
end

function lsproto.NewTyped(goType, value)
    return setmetatable({ goType = goType, value = value }, Typed)
end

---- Decoding

local decode

local function semanticError(t, kind)
    return "json: cannot unmarshal JSON " .. lsproto.kindString(kind) .. " into Go " .. t.s
end

local function decodeArrayInto(dec, t, n)
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    local arr = {}
    while dec:PeekKind() ~= "]" do
        if dec:PeekKind() == 0 then
            return nil, "jsontext: unexpected EOF"
        end
        local e
        e, err = decode(dec, t.elem)
        if err ~= nil then
            return nil, err
        end
        if e == nil then
            e = json.Null
        end
        arr[#arr + 1] = e
    end
    _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    if n ~= nil then
        if #arr < n then
            return nil, "json: cannot unmarshal JSON array into Go " .. t.s .. ": too few array elements"
        elseif #arr > n then
            return nil, "json: cannot unmarshal JSON array into Go " .. t.s .. ": too many array elements"
        end
    end
    return arr, nil
end

-- Reads an object member name. Returns (name, err).
local function readName(dec)
    local tok, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    if tok.kind ~= '"' then
        return nil, "jsontext: invalid character " .. jsonrpc.goQuote(tok.raw) .. " at start of object name"
    end
    return tok.value, nil
end

local function decodeDefaultStruct(dec, t, spec)
    local kind = dec:PeekKind()
    if kind == "n" then
        dec:ReadToken()
        return lsproto.construct(spec.name, {}), nil
    end
    if kind ~= "{" then
        return nil, semanticError(t, kind)
    end
    dec:ReadToken()
    local v = lsproto.construct(spec.name, {})
    local seen = {}
    while dec:PeekKind() ~= "}" do
        local name, err = readName(dec)
        if err ~= nil then
            return nil, err
        end
        if seen[name] then
            return nil, "jsontext: duplicate object member name " .. json.QuoteString(name)
        end
        seen[name] = true
        local fs = spec.byName[name]
        if fs == nil then
            err = dec:SkipValue()
            if err ~= nil then
                return nil, err
            end
        else
            local fv
            fv, err = decode(dec, fs.goType)
            if err ~= nil then
                return nil, err
            end
            v[fs.field] = fv
        end
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    return v, nil
end

-- unmarshalStruct decodes a JSON object into a new value of the struct, enforcing
-- object-kind, required-field, and non-nullable-field strictness as declared by lsp struct tags.
function lsproto.unmarshalStruct(spec, dec)
    local k = dec:PeekKind()
    if k ~= "{" then
        return nil, lsproto.errNotObject(k)
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end

    local v = lsproto.construct(spec.name, {})
    local seen = {}
    local seenNames = {}
    while dec:PeekKind() ~= "}" do
        local name
        name, err = readName(dec)
        if err ~= nil then
            return nil, err
        end
        if seenNames[name] then
            return nil, "jsontext: duplicate object member name " .. json.QuoteString(name)
        end
        seenNames[name] = true
        local fs = spec.byName[name]
        if fs == nil then
            err = dec:SkipValue()
            if err ~= nil then
                return nil, err
            end
        else
            if fs.required then
                seen[name] = true
            end
            if fs.rejectNull and dec:PeekKind() == "n" then
                return nil, lsproto.errNull(name)
            end
            local fv
            fv, err = decode(dec, fs.goType)
            if err ~= nil then
                return nil, err
            end
            v[fs.field] = fv
        end
    end
    _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end

    local missingProps = {}
    for _, n in ipairs(spec.requiredNames) do
        if not seen[n] then
            missingProps[#missingProps + 1] = n
        end
    end
    if #missingProps > 0 then
        return nil, lsproto.errMissing(missingProps)
    end
    return v, nil
end

function decode(dec, t)
    t = node(t)
    local k = t.k
    if k == "ptr" then
        if dec:PeekKind() == "n" then
            local _, err = dec:ReadToken()
            return nil, err
        end
        return decode(dec, t.elem)
    elseif k == "slice" or k == "array" then
        local kind = dec:PeekKind()
        if kind == "n" then
            local _, err = dec:ReadToken()
            if k == "array" then
                return lsproto.zeroOf(t), err
            end
            return nil, err
        end
        if kind ~= "[" then
            return nil, semanticError(t, kind)
        end
        return decodeArrayInto(dec, t, k == "array" and t.n or nil)
    elseif k == "map" then
        local kind = dec:PeekKind()
        if kind == "n" then
            local _, err = dec:ReadToken()
            return nil, err
        end
        if kind ~= "{" then
            return nil, semanticError(t, kind)
        end
        dec:ReadToken()
        local m = {}
        while dec:PeekKind() ~= "}" do
            local name, err = readName(dec)
            if err ~= nil then
                return nil, err
            end
            if m[name] ~= nil then
                return nil, "jsontext: duplicate object member name " .. json.QuoteString(name)
            end
            local ev
            ev, err = decode(dec, t.elem)
            if err ~= nil then
                return nil, err
            end
            m[name] = ev
        end
        local _, err = dec:ReadToken()
        if err ~= nil then
            return nil, err
        end
        return m, nil
    elseif k == "empty" then
        local kind = dec:PeekKind()
        if kind ~= "{" and kind ~= "n" then
            return nil, semanticError(t, kind)
        end
        local err = dec:SkipValue()
        if err ~= nil then
            return nil, err
        end
        return {}, nil
    end
    local r = t.r
    if r == "base" then
        local b = t.base
        local kind = dec:PeekKind()
        if b == "any" then
            return lsproto.decodeAny(dec)
        end
        if kind == "n" then
            local _, err = dec:ReadToken()
            return lsproto.zeroOf(t), err
        end
        if b == "string" then
            if kind ~= '"' then
                return nil, semanticError(t, kind)
            end
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            return tok.value, nil
        elseif b == "int" then
            if kind ~= "0" then
                return nil, semanticError(t, kind)
            end
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            local i = string.match(tok.raw, "^-?%d+$") and math.tointeger(tonumber(tok.raw)) or nil
            local range = intRanges[t.baseName]
            if i == nil or i < range[1] or i > range[2] then
                return nil, "json: cannot unmarshal JSON number " .. tok.raw .. " into Go " .. t.baseName
            end
            return i, nil
        elseif b == "float" then
            if kind ~= "0" then
                return nil, semanticError(t, kind)
            end
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            return tok.value, nil
        elseif b == "bool" then
            if kind ~= "t" and kind ~= "f" then
                return nil, semanticError(t, kind)
            end
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            return tok.value, nil
        end
    elseif r == "struct" then
        local spec = t.spec
        if spec.unmarshal ~= nil then
            return spec.unmarshal(dec)
        end
        if spec.strict then
            return lsproto.unmarshalStruct(spec, dec)
        end
        return decodeDefaultStruct(dec, t, spec)
    elseif r == "union" then
        local o = setmetatable({}, t.spec.class)
        local err = t.spec.unmarshal(o, dec)
        if err ~= nil then
            return nil, err
        end
        return o, nil
    elseif r == "literal" then
        local v, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        if v ~= t.spec.raw then
            return nil, lsproto.errLiteralMismatch(t.name, t.spec.raw, v)
        end
        return t.spec.value, nil
    elseif r == "custom" then
        return t.spec.decode(dec)
    end
    return nil, "lsproto: cannot unmarshal " .. t.s
end

lsproto.decode = decode

-- Decodes a value into `any`: objects become tables with the json.Object metatable (so that an
-- empty object marshals back as {}), arrays Lua arrays (null elements json.Null), numbers floats.
-- Null object members are dropped (Lua tables cannot hold nil).
function lsproto.decodeAny(dec)
    local kind = dec:PeekKind()
    if kind == "{" then
        dec:ReadToken()
        local obj = json.NewObject({})
        local seen = {}
        while dec:PeekKind() ~= "}" do
            local name, err = readName(dec)
            if err ~= nil then
                return nil, err
            end
            if seen[name] then
                return nil, "jsontext: duplicate object member name " .. json.QuoteString(name)
            end
            seen[name] = true
            local v
            v, err = lsproto.decodeAny(dec)
            if err ~= nil then
                return nil, err
            end
            obj[name] = v
        end
        local _, err = dec:ReadToken()
        if err ~= nil then
            return nil, err
        end
        return obj, nil
    elseif kind == "[" then
        dec:ReadToken()
        local arr = {}
        while dec:PeekKind() ~= "]" do
            if dec:PeekKind() == 0 then
                return nil, "jsontext: unexpected EOF"
            end
            local v, err = lsproto.decodeAny(dec)
            if err ~= nil then
                return nil, err
            end
            if v == nil then
                v = json.Null
            end
            arr[#arr + 1] = v
        end
        local _, err = dec:ReadToken()
        if err ~= nil then
            return nil, err
        end
        return arr, nil
    end
    local tok, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    if tok.kind == "}" or tok.kind == "]" then
        return nil, "jsontext: invalid character " .. jsonrpc.goQuote(tok.kind) .. " at start of value"
    end
    return tok.value, nil
end

-- json.UnmarshalDecode into a new value of the given Go type (Lua-only API). Returns (value, err).
function lsproto.UnmarshalDecodeAs(goType, dec)
    return decode(dec, goType)
end

-- json.Unmarshal of raw JSON text (or a jsonrpc.Value) into a new value of the given Go type
-- (Lua-only API). Returns (value, err).
function lsproto.UnmarshalAs(goType, data)
    if type(data) == "table" and getmetatable(data) == jsonrpc.Value then
        data = data.data
    end
    local dec = json.NewDecoder(data)
    if dec:PeekKind() == 0 then
        return nil, "jsontext: unexpected EOF"
    end
    local v, err = decode(dec, goType)
    if err ~= nil then
        return nil, err
    end
    dec:skipWS()
    if dec.pos <= #dec.s then
        return nil, "jsontext: invalid character " .. jsonrpc.goQuote(string.sub(dec.s, dec.pos, dec.pos)) .. " after top-level value"
    end
    return v, nil
end

-- Union arm helpers used by the generated UnmarshalJSONFrom functions.

-- o.X = new(T); return json.UnmarshalDecode(dec, o.X)
function lsproto.decodeArm(o, field, dec, goType)
    local v, err = decode(dec, goType)
    if err ~= nil then
        return err
    end
    o[field] = v
    return nil
end

-- o.X = new(T); return json.Unmarshal(data, o.X)
function lsproto.unmarshalArm(o, field, data, goType)
    local v, err = lsproto.UnmarshalAs(goType, data)
    if err ~= nil then
        return err
    end
    o[field] = v
    return nil
end

-- var vX T; if err := json.Unmarshal(data, &vX); err == nil { o.X = &vX; return nil }
function lsproto.tryUnmarshalArm(o, field, data, goType)
    local v, err = lsproto.UnmarshalAs(goType, data)
    if err ~= nil then
        return false
    end
    o[field] = v
    return true
end

-- marshalUnion and countNonNil are folded into encodeUnion above.

-- countNonNil returns the number of non-nil fields of the struct or union value v.
function lsproto.countNonNil(name, v)
    local count = 0
    local spec = lsproto.structSpecs[name] or lsproto.unionSpecs[name]
    for _, f in ipairs(spec.fields or spec.arms) do
        if v[f.field] ~= nil then
            count = count + 1
        end
    end
    return count
end

---- Resolved types

-- (*X).resolve(): a Resolved value with every field converted to a non-pointer value.
function lsproto.resolveStruct(name, v)
    local spec = lsproto.structSpecs[name]
    local out = {}
    for _, f in ipairs(spec.fields) do
        local t = node(f.goType)
        local src = v ~= nil and v[f.field] or nil
        if t.r == "struct" and t.spec.resolvedFrom ~= nil then
            out[f.field] = lsproto.resolveStruct(t.name, src)
        elseif src ~= nil then
            out[f.field] = src
        else
            out[f.field] = lsproto.zeroOf(t)
        end
    end
    return setmetatable(out, spec.class)
end

---- Custom types

lsproto.defineCustom("json.Value", {
    encode = function(buf, v)
        if v == nil or v.data == "" then
            buf[#buf + 1] = "null"
        else
            buf[#buf + 1] = v.data
        end
        return nil
    end,
    decode = function(dec)
        local v, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        return jsonrpc.NewValue(v), nil
    end,
    isZero = function(v)
        return v == nil or v.data == ""
    end,
})

lsproto.defineCustom("jsonrpc.ID", {
    encode = function(buf, v)
        local s, err = v:MarshalJSON()
        if err ~= nil then
            return err
        end
        buf[#buf + 1] = s
        return nil
    end,
    decode = function(dec)
        local v, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        return jsonrpc.UnmarshalID(v)
    end,
    zero = function()
        return jsonrpc.NewIDInt(0)
    end,
})

lsproto.defineCustom("Null", {
    encode = function(buf)
        buf[#buf + 1] = "null"
        return nil
    end,
    decode = function(dec)
        local data, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        if data ~= "null" then
            return nil, "expected null, got " .. data
        end
        return lsproto.Null, nil
    end,
    zero = function()
        return lsproto.Null
    end,
    isZero = function()
        return true
    end,
})

lsproto.defineCustom("NoParams", {
    encode = function(buf)
        buf[#buf + 1] = "{}"
        return nil
    end,
    decode = function(dec)
        local err = dec:SkipValue()
        return lsproto.NoParams, err
    end,
    zero = function()
        return lsproto.NoParams
    end,
    isZero = function()
        return true
    end,
})
