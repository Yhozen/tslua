-- Lua-only support code (no Go counterpart file). Go marshals and unmarshals the API protocol types
-- with encoding/json/v2 reflection over struct tags; Lua has no reflection, so proto.lua describes
-- every struct with Go type strings and this file interprets them, following json/v2 semantics:
--   * fields are written in declaration order;
--   * `omitzero` omits Go zero values, `omitempty` omits values that encode as null, "", {} or [];
--   * nil slices encode as [] and nil maps as {}; nil pointers/interfaces as null;
--   * missing non-pointer fields read as their Go zero value when marshaling;
--   * unmarshaling ignores unknown members, rejects duplicate names and mismatched kinds.
-- Value model: structs are Lua tables keyed by the lowerCamelCase Go field names (with the class
-- metatable api.<Name> when constructed through api.New<Name>-style helpers or decoded); nil
-- elements of slices are json.Null.
--
-- Type strings: "*T", "[]T", "map[string]T", base names (string, bool, int, int32, uint8, uint32,
-- uint64, float64, any, Tristate, json.Value) and named types registered below (structs, aliases,
-- custom types).
local api = require("tslua.api")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local core = require("tslua.core")
local collections = require("tslua.collections")

api.structSpecs = {}
api.aliasSpecs = {}
api.customSpecs = {}

local baseTypes = {
    string = "string",
    bool = "bool",
    int = "int",
    int32 = "int",
    uint8 = "int",
    uint32 = "int",
    uint64 = "int",
    float64 = "float",
    any = "any",
    Tristate = "tristate",
    ["json.Value"] = "raw",
}

local intRanges = {
    int = { math.mininteger, math.maxinteger },
    int32 = { -2147483648, 2147483647 },
    uint8 = { 0, 255 },
    uint32 = { 0, 4294967295 },
    uint64 = { 0, math.maxinteger },
}

-- defineStruct registers a struct type. fields entries are { luaField, goType, jsonTag }.
function api.defineStruct(name, fields)
    local class = rawget(api, name)
    if class == nil then
        class = {}
        api[name] = class
    end
    class.__index = class
    class.__name = "api." .. name
    class.MarshalJSON = function(self)
        return api.MarshalAs(name, self)
    end
    local spec = { name = name, fields = {}, byName = {}, class = class }
    for _, f in ipairs(fields) do
        local jsonName, opts = string.match(f[3], "^([^,]*),?(.*)$")
        local fs = {
            field = f[1],
            goType = f[2],
            jsonName = jsonName,
            omitzero = opts == "omitzero",
            omitempty = opts == "omitempty",
        }
        spec.fields[#spec.fields + 1] = fs
        spec.byName[jsonName] = fs
    end
    api.structSpecs[name] = spec
    return spec
end

function api.defineAlias(name, goType)
    api.aliasSpecs[name] = goType
end

-- spec: { encode = function(buf, v) -> err, decode = function(dec) -> (v, err),
--         isZero = function(v) -> bool }
function api.defineCustom(name, spec)
    api.customSpecs[name] = spec
end

---- Type strings

local typeCache = {}

local function parseType(s)
    local t = typeCache[s]
    if t ~= nil then
        return t
    end
    if string.sub(s, 1, 1) == "*" then
        t = { k = "ptr", elem = parseType(string.sub(s, 2)), s = s }
    elseif string.sub(s, 1, 2) == "[]" then
        t = { k = "slice", elem = parseType(string.sub(s, 3)), s = s }
    elseif string.sub(s, 1, 11) == "map[string]" then
        t = { k = "map", elem = parseType(string.sub(s, 12)), s = s }
    else
        local alias = api.aliasSpecs[s]
        if alias ~= nil then
            t = parseType(alias)
            typeCache[s] = t
            return t
        end
        if baseTypes[s] ~= nil then
            t = { k = "base", base = baseTypes[s], name = s, s = s }
        elseif api.structSpecs[s] ~= nil then
            t = { k = "struct", spec = api.structSpecs[s], s = s }
        elseif api.customSpecs[s] ~= nil then
            t = { k = "custom", spec = api.customSpecs[s], s = s }
        else
            error("api: unknown type " .. s, 0)
        end
    end
    typeCache[s] = t
    return t
end
api.parseType = parseType

---- isZero

local function isZero(t, v)
    if v == nil or v == json.Null then
        return true
    end
    local k = t.k
    if k == "ptr" or k == "slice" or k == "map" then
        return false
    elseif k == "base" then
        local b = t.base
        if b == "string" then
            return v == ""
        elseif b == "int" or b == "float" then
            return v == 0
        elseif b == "bool" then
            return v == false
        elseif b == "tristate" then
            return v == core.Tristate.TSUnknown
        elseif b == "raw" then
            return v:Len() == 0
        end
        return false
    elseif k == "struct" then
        for _, f in ipairs(t.spec.fields) do
            if not isZero(parseType(f.goType), v[f.field]) then
                return false
            end
        end
        return true
    elseif k == "custom" then
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
    buf[#buf + 1] = "{"
    local first = true
    for _, f in ipairs(spec.fields) do
        local ft = parseType(f.goType)
        local fv = v ~= nil and v[f.field] or nil
        if not (f.omitzero and isZero(ft, fv)) then
            local sub = {}
            local err = encode(sub, ft, fv)
            if err ~= nil then
                return err
            end
            local s = table.concat(sub)
            if not (f.omitempty and (s == "null" or s == '""' or s == "{}" or s == "[]")) then
                if not first then
                    buf[#buf + 1] = ","
                end
                first = false
                buf[#buf + 1] = json.QuoteString(f.jsonName)
                buf[#buf + 1] = ":"
                buf[#buf + 1] = s
            end
        end
    end
    buf[#buf + 1] = "}"
    return nil
end

function encode(buf, t, v)
    if v == json.Null then
        v = nil
    end
    local k = t.k
    if k == "ptr" then
        if v == nil then
            buf[#buf + 1] = "null"
            return nil
        end
        return encode(buf, t.elem, v)
    elseif k == "slice" then
        buf[#buf + 1] = "["
        if v ~= nil then
            for i = 1, #v do
                if i > 1 then
                    buf[#buf + 1] = ","
                end
                local err = encode(buf, t.elem, v[i])
                if err ~= nil then
                    return err
                end
            end
        end
        buf[#buf + 1] = "]"
        return nil
    elseif k == "map" then
        buf[#buf + 1] = "{"
        if v ~= nil then
            -- Go map iteration order is random; json/v2 does not sort by default, so any
            -- order matches Go. Sort for determinism.
            local keys = {}
            for key in pairs(v) do
                keys[#keys + 1] = key
            end
            table.sort(keys)
            for i, key in ipairs(keys) do
                if i > 1 then
                    buf[#buf + 1] = ","
                end
                buf[#buf + 1] = json.QuoteString(key)
                buf[#buf + 1] = ":"
                local err = encode(buf, t.elem, v[key])
                if err ~= nil then
                    return err
                end
            end
        end
        buf[#buf + 1] = "}"
        return nil
    elseif k == "struct" then
        return encodeStruct(buf, t.spec, v)
    elseif k == "custom" then
        return t.spec.encode(buf, v)
    end
    local b = t.base
    if b == "string" then
        buf[#buf + 1] = json.QuoteString(v or "")
    elseif b == "int" then
        local i = math.tointeger(v or 0)
        if i == nil then
            return "json: cannot marshal " .. tostring(v) .. " as Go " .. t.name
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
    elseif b == "tristate" then
        local s = core.Tristate_MarshalJSON(v or core.Tristate.TSUnknown)
        buf[#buf + 1] = s
    elseif b == "raw" then
        if v == nil or v:Len() == 0 then
            buf[#buf + 1] = "null"
        else
            buf[#buf + 1] = v.data
        end
    else -- any
        if v == nil then
            buf[#buf + 1] = "null"
            return nil
        end
        return json.encodeValue(buf, v)
    end
    return nil
end

-- MarshalAs is json.Marshal of a value of the given Go type. Returns (string, err).
function api.MarshalAs(goType, v)
    local buf = {}
    local err = encode(buf, parseType(goType), v)
    if err ~= nil then
        return nil, err
    end
    return table.concat(buf), nil
end

-- Typed wraps a value so that tslua.json marshals it as the given Go type (for values placed in
-- `any` slots, e.g. handler results).
local Typed = {}
Typed.__index = Typed
api.TypedValue = Typed

function Typed:MarshalJSON()
    return api.MarshalAs(self.goType, self.value)
end

function api.Typed(goType, value)
    return setmetatable({ goType = goType, value = value }, Typed)
end

---- Decoding

local decode

local function kindName(kind)
    return jsonrpc.kindName(kind)
end

local function semanticError(t, kind)
    return "json: cannot unmarshal JSON " .. kindName(kind) .. " into Go " .. t.s
end

local function decodeStruct(dec, t)
    local spec = t.spec
    local v = setmetatable({}, spec.class)
    local kind = dec:PeekKind()
    if kind == "n" then
        dec:ReadToken()
        api.fillZeroFields(spec, v)
        return v, nil
    end
    if kind ~= "{" then
        local _, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        return nil, semanticError(t, kind)
    end
    dec:ReadToken()
    local seen = {}
    while dec:PeekKind() ~= "}" do
        if dec:PeekKind() == 0 then
            return nil, "jsontext: unexpected EOF"
        end
        local tok, err = dec:ReadToken()
        if err ~= nil then
            return nil, err
        end
        if tok.kind ~= '"' then
            return nil, "jsontext: invalid character " .. tok.raw .. " at start of object name"
        end
        local name = tok.value
        if seen[name] then
            return nil, "jsontext: duplicate object member name " .. json.QuoteString(name)
        end
        seen[name] = true
        local f = spec.byName[name]
        if f == nil then
            err = dec:SkipValue()
            if err ~= nil then
                return nil, err
            end
        else
            local fv
            fv, err = decode(dec, parseType(f.goType))
            if err ~= nil then
                return nil, err
            end
            v[f.field] = fv
        end
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    api.fillZeroFields(spec, v)
    return v, nil
end

-- zeroValue returns the Go zero value of a type (nil for pointers, slices, maps, any).
function api.zeroValue(t)
    local k = t.k
    if k == "base" then
        local b = t.base
        if b == "string" then
            return ""
        elseif b == "int" or b == "float" then
            return 0
        elseif b == "bool" then
            return false
        elseif b == "tristate" then
            return core.Tristate.TSUnknown
        end
        return nil
    elseif k == "struct" then
        local v = setmetatable({}, t.spec.class)
        api.fillZeroFields(t.spec, v)
        return v
    elseif k == "custom" and t.spec.zero ~= nil then
        return t.spec.zero()
    end
    return nil
end

-- fillZeroFields sets every missing field of a decoded struct to its Go zero value.
function api.fillZeroFields(spec, v)
    for _, f in ipairs(spec.fields) do
        if v[f.field] == nil then
            v[f.field] = api.zeroValue(parseType(f.goType))
        end
    end
end

local function zeroBase(t)
    local b = t.base
    if b == "string" then
        return ""
    elseif b == "int" or b == "float" then
        return 0
    elseif b == "bool" then
        return false
    elseif b == "tristate" then
        return core.Tristate.TSUnknown
    end
    return nil
end

function decode(dec, t)
    local kind = dec:PeekKind()
    local k = t.k
    if k == "ptr" then
        if kind == "n" then
            dec:ReadToken()
            return nil, nil
        end
        return decode(dec, t.elem)
    elseif k == "slice" then
        if kind == "n" then
            dec:ReadToken()
            return nil, nil
        end
        if kind ~= "[" then
            local _, err = dec:ReadValue()
            if err ~= nil then
                return nil, err
            end
            return nil, semanticError(t, kind)
        end
        dec:ReadToken()
        local arr = {}
        while dec:PeekKind() ~= "]" do
            if dec:PeekKind() == 0 then
                return nil, "jsontext: unexpected EOF"
            end
            local e, err = decode(dec, t.elem)
            if err ~= nil then
                return nil, err
            end
            if e == nil then
                e = json.Null
            end
            arr[#arr + 1] = e
        end
        dec:ReadToken()
        return arr, nil
    elseif k == "map" then
        if kind == "n" then
            dec:ReadToken()
            return nil, nil
        end
        if kind ~= "{" then
            local _, err = dec:ReadValue()
            if err ~= nil then
                return nil, err
            end
            return nil, semanticError(t, kind)
        end
        dec:ReadToken()
        local m = {}
        while dec:PeekKind() ~= "}" do
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            local e
            e, err = decode(dec, t.elem)
            if err ~= nil then
                return nil, err
            end
            m[tok.value] = e
        end
        dec:ReadToken()
        return m, nil
    elseif k == "struct" then
        return decodeStruct(dec, t)
    elseif k == "custom" then
        return t.spec.decode(dec)
    end
    local b = t.base
    if b == "any" then
        return json.UnmarshalDecode(dec)
    elseif b == "raw" then
        local raw, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        return jsonrpc.NewValue(raw), nil
    end
    local tok, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    if tok.kind == "n" then
        return zeroBase(t), nil
    end
    if b == "string" then
        if tok.kind ~= '"' then
            return nil, semanticError(t, tok.kind)
        end
        return tok.value, nil
    elseif b == "bool" then
        if tok.kind ~= "t" and tok.kind ~= "f" then
            return nil, semanticError(t, tok.kind)
        end
        return tok.value, nil
    elseif b == "tristate" then
        if tok.kind ~= "t" and tok.kind ~= "f" then
            return nil, semanticError(t, tok.kind)
        end
        return core.Tristate_UnmarshalJSON(tok.raw), nil
    elseif b == "int" then
        if tok.kind ~= "0" then
            return nil, semanticError(t, tok.kind)
        end
        local i = math.tointeger(tok.value)
        local r = intRanges[t.name]
        if i == nil or i < r[1] or i > r[2] then
            return nil, "json: cannot unmarshal JSON number " .. tok.raw .. " into Go " .. t.name
        end
        return i, nil
    elseif b == "float" then
        if tok.kind ~= "0" then
            return nil, semanticError(t, tok.kind)
        end
        return tok.value, nil
    end
    return nil, "api: cannot unmarshal into " .. t.s
end

-- UnmarshalAs is json.Unmarshal into a value of the given Go type. Returns (value, err).
function api.UnmarshalAs(goType, data)
    local dec = json.NewDecoder(data)
    local ok, v, err = pcall(decode, dec, parseType(goType))
    if not ok then
        if type(v) == "table" and v.jsonError ~= nil then
            return nil, v.jsonError
        end
        error(v, 0)
    end
    if err ~= nil then
        return nil, err
    end
    dec:skipWS()
    if dec.pos <= #dec.s then
        return nil, "jsontext: invalid character after top-level value"
    end
    return v, nil
end

-- UnmarshalDecodeAs is json.UnmarshalDecode into a value of the given Go type. Returns (value, err).
function api.UnmarshalDecodeAs(goType, dec)
    return decode(dec, parseType(goType))
end

---- Custom types shared by the protocol

-- *core.CompilerOptions: marshaled by its MarshalJSON; unmarshaled from its json tags.
api.defineCustom("core.CompilerOptions", {
    encode = function(buf, v)
        local s, err = v:MarshalJSON()
        if err ~= nil then
            return err
        end
        buf[#buf + 1] = s
        return nil
    end,
    decode = function(dec)
        local opts = core.NewCompilerOptions()
        local kind = dec:PeekKind()
        if kind == "n" then
            dec:ReadToken()
            return opts, nil
        end
        if kind ~= "{" then
            return nil, "json: cannot unmarshal JSON " .. kindName(kind) .. " into Go core.CompilerOptions"
        end
        local byJSON = {}
        for _, field in ipairs(core.CompilerOptions.Fields) do
            byJSON[field.json] = field
        end
        dec:ReadToken()
        while dec:PeekKind() ~= "}" do
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            local field = byJSON[tok.value]
            if field == nil then
                err = dec:SkipValue()
            else
                local goType
                if field.kind == "tristate" then
                    goType = "Tristate"
                elseif field.kind == "string" then
                    goType = "string"
                elseif field.kind == "stringlist" then
                    goType = "[]string"
                elseif field.kind == "intptr" then
                    goType = "*int"
                elseif field.kind == "map" then
                    goType = "pathsMap"
                else
                    goType = "int32"
                end
                local v
                v, err = decode(dec, parseType(goType))
                if err == nil then
                    opts[field.name] = v
                end
            end
            if err ~= nil then
                return nil, err
            end
        end
        dec:ReadToken()
        return opts, nil
    end,
})

-- *collections.OrderedMap[string, []string] (CompilerOptions.Paths).
api.defineCustom("pathsMap", {
    encode = function(buf, v)
        local s, err = json.Marshal(v)
        if err ~= nil then
            return err
        end
        buf[#buf + 1] = s
        return nil
    end,
    decode = function(dec)
        if dec:PeekKind() == "n" then
            dec:ReadToken()
            return nil, nil
        end
        if dec:PeekKind() ~= "{" then
            return nil, "json: cannot unmarshal JSON " .. kindName(dec:PeekKind()) .. " into Go collections.OrderedMap[string,[]string]"
        end
        local m = collections.NewOrderedMapWithSizeHint(0)
        dec:ReadToken()
        while dec:PeekKind() ~= "}" do
            local tok, err = dec:ReadToken()
            if err ~= nil then
                return nil, err
            end
            local v
            v, err = decode(dec, parseType("[]string"))
            if err ~= nil then
                return nil, err
            end
            m:Set(tok.value, v)
        end
        dec:ReadToken()
        return m, nil
    end,
})

local function encodeWith(buf, v)
    local s, err = json.Marshal(v)
    if err ~= nil then
        return err
    end
    buf[#buf + 1] = s
    return nil
end

-- *core.TypeAcquisition and *core.ProjectReference are encoded from their Go struct tags.
api.defineStruct("core.TypeAcquisition", {
    { "enable", "Tristate", "enable,omitzero" },
    { "include", "[]string", "include,omitzero" },
    { "exclude", "[]string", "exclude,omitzero" },
    { "disableFilenameBasedTypeAcquisition", "Tristate", "disableFilenameBasedTypeAcquisition,omitzero" },
})
api.defineStruct("core.ProjectReference", {
    { "path", "string", "path" },
    { "originalPath", "string", "originalPath" },
    { "circular", "bool", "circular" },
})

-- `any` values built by tslua.json / tslua.collections (OrderedMap) marshal themselves.
api.defineCustom("anyValue", {
    encode = encodeWith,
    decode = function(dec)
        return json.UnmarshalDecode(dec)
    end,
})
