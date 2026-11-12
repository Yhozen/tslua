-- Lua-only helpers (no Go counterpart file) standing in for Go's reflection-based json.Marshal /
-- json.Unmarshal of the content mapper protocol structs. Raw JSON (Go json.Value) is a Lua string in
-- struct fields ("" for an empty value) and a jsonrpc.Value on the wire API (ipc.Conn params/results).
-- Encoding builds compact JSON member by member in Go field order (codec.Object); decoding follows the
-- go-json-experiment/json defaults: case-sensitive member names, unknown members ignored, JSON null
-- leaves the Go zero value, duplicate names and type mismatches are errors.
local contentmapper = require("tslua.contentmapper")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")

local codec = {}
contentmapper.codec = codec

local function newError(msg)
    return jsonrpc.NewError(msg)
end

---- Encoding

local Object = {}
Object.__index = Object
codec.Object = Object

-- NewObject starts the JSON text of a Go struct.
function codec.NewObject()
    return setmetatable({ parts = {}, err = nil }, Object)
end

-- Raw appends a member whose value is raw JSON text.
function Object:Raw(name, raw)
    self.parts[#self.parts + 1] = json.QuoteString(name) .. ":" .. raw
    return self
end

-- Value appends a member marshaled with json.Marshal (tables with MarshalJSON are honored).
function Object:Value(name, v)
    local raw, err = json.Marshal(v)
    if err ~= nil then
        if self.err == nil then
            self.err = err
        end
        return self
    end
    return self:Raw(name, raw)
end

function Object:String(name, s)
    return self:Raw(name, json.QuoteString(s))
end

function Object:Int(name, n)
    return self:Raw(name, string.format("%d", n))
end

function Object:Bool(name, b)
    return self:Raw(name, b and "true" or "false")
end

-- Array appends a member holding an array whose elements are encoded by elem(v) -> (raw, err).
function Object:Array(name, xs, elem)
    local raw, err = codec.Array(xs, elem)
    if err ~= nil then
        if self.err == nil then
            self.err = err
        end
        return self
    end
    return self:Raw(name, raw)
end

-- Result returns (jsonText, err).
function Object:Result()
    if self.err ~= nil then
        return nil, self.err
    end
    return "{" .. table.concat(self.parts, ",") .. "}", nil
end

-- Array encodes xs (possibly nil: Go v2 marshals a nil slice as []) with elem(v) -> (raw, err).
function codec.Array(xs, elem)
    local parts = {}
    for i, v in ipairs(xs or {}) do
        local raw, err = elem(v)
        if err ~= nil then
            return nil, err
        end
        parts[i] = raw
    end
    return "[" .. table.concat(parts, ",") .. "]", nil
end

function codec.EncodeString(s)
    return json.QuoteString(s), nil
end

function codec.EncodeRaw(raw)
    if raw == nil or raw == "" then
        return "null", nil
    end
    return raw, nil
end

-- structValue adapts a struct encoder to tslua.json Marshal (so it can be an ipc params/result value).
local structValue = {}
structValue.__index = structValue

function structValue:MarshalJSON()
    return self.encode(self.value)
end

-- Marshaler wraps value so json.Marshal encodes it with encode(value) -> (raw, err).
function codec.Marshaler(value, encode)
    return setmetatable({ value = value, encode = encode }, structValue)
end

---- Decoding

local function typeName(v)
    if v == nil or v == json.Null then
        return "null"
    end
    local tv = type(v)
    if tv == "table" then
        if getmetatable(v) == nil and (#v > 0 or next(v) == nil) then
            return "array"
        end
        return "object"
    end
    return tv
end

-- RawString returns the raw text of a json.Value-ish input (string, jsonrpc.Value, or nil -> "").
function codec.RawString(v)
    if v == nil then
        return ""
    end
    if type(v) == "table" then
        return v.data or ""
    end
    return v
end

-- IsNull reports whether raw is absent or the JSON null literal.
function codec.IsNull(raw)
    if raw == nil or raw == "" then
        return true
    end
    return (string.match(raw, "^%s*null%s*$")) ~= nil
end

-- DecodeObject splits a JSON object into its members' raw texts. Returns (members, err) where members
-- maps name -> raw JSON text; JSON null yields nil members (the Go zero struct) without error.
function codec.DecodeObject(raw)
    raw = codec.RawString(raw)
    if raw == "" then
        return nil, newError("unexpected end of JSON input")
    end
    local dec = json.NewDecoder(raw)
    local kind = dec:PeekKind()
    if kind == "n" then
        return nil, nil
    end
    if kind ~= "{" then
        return nil, newError("json: cannot unmarshal JSON " .. jsonrpc.kindName(kind) .. " into Go struct")
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, newError(err)
    end
    local members = {}
    while dec:PeekKind() ~= "}" do
        if dec:PeekKind() == 0 then
            return nil, newError("jsontext: unexpected EOF")
        end
        local name, nerr = dec:ReadToken()
        if nerr ~= nil then
            return nil, newError(nerr)
        end
        if name.kind ~= '"' then
            return nil, newError("jsontext: invalid character at start of object name")
        end
        if members[name.value] ~= nil then
            return nil, newError("jsontext: duplicate object member name " .. json.QuoteString(name.value))
        end
        local value, verr = dec:ReadValue()
        if verr ~= nil then
            return nil, newError(verr)
        end
        members[name.value] = value
    end
    dec:ReadToken()
    dec:skipWS()
    if dec.pos <= #dec.s then
        return nil, newError("jsontext: invalid character after top-level value")
    end
    return members, nil
end

-- DecodeFields decodes the members named in spec (an array of { name, decoder } pairs, decoded in
-- order; decoder(raw) -> (value, err)). Returns (table keyed by member name, err); absent members stay
-- unset so callers apply Go zero values.
function codec.DecodeFields(raw, spec)
    local members, err = codec.DecodeObject(raw)
    if err ~= nil then
        return nil, err
    end
    local out = {}
    if members == nil then
        return out, nil
    end
    for _, field in ipairs(spec) do
        local r = members[field[1]]
        if r ~= nil then
            local v, derr = field[2](r)
            if derr ~= nil then
                return nil, derr
            end
            out[field[1]] = v
        end
    end
    return out, nil
end

local function decodeAny(raw)
    local v, err = json.Unmarshal(raw)
    if err ~= nil then
        return nil, newError(err)
    end
    return v, nil
end

-- DecodeString decodes a Go string. Returns (string, err).
function codec.DecodeString(raw)
    if codec.IsNull(raw) then
        return "", nil
    end
    local v, err = decodeAny(raw)
    if err ~= nil then
        return "", err
    end
    if type(v) ~= "string" then
        return "", newError("json: cannot unmarshal JSON " .. typeName(v) .. " into Go string")
    end
    return v, nil
end

-- DecodeIntRange decodes a Go integer bounded by [lo, hi]. Returns (int, err).
function codec.DecodeIntRange(raw, lo, hi, goType)
    if codec.IsNull(raw) then
        return 0, nil
    end
    local v, err = decodeAny(raw)
    if err ~= nil then
        return 0, err
    end
    if type(v) ~= "number" then
        return 0, newError("json: cannot unmarshal JSON " .. typeName(v) .. " into Go " .. goType)
    end
    if v ~= math.floor(v) or v < lo or v > hi then
        return 0, newError("json: cannot unmarshal JSON number " .. json.formatNumber(v) .. " into Go " .. goType)
    end
    return math.tointeger(v), nil
end

function codec.DecodeInt(raw)
    return codec.DecodeIntRange(raw, math.mininteger, math.maxinteger, "int")
end

function codec.DecodeInt32(raw)
    return codec.DecodeIntRange(raw, -2147483648, 2147483647, "int32")
end

function codec.DecodeUint8(raw)
    return codec.DecodeIntRange(raw, 0, 255, "uint8")
end

-- DecodeBool decodes a Go bool. Returns (bool, err).
function codec.DecodeBool(raw)
    if codec.IsNull(raw) then
        return false, nil
    end
    local v, err = decodeAny(raw)
    if err ~= nil then
        return false, err
    end
    if type(v) ~= "boolean" then
        return false, newError("json: cannot unmarshal JSON " .. typeName(v) .. " into Go bool")
    end
    return v, nil
end

-- DecodeRaw keeps a member's raw JSON text (Go json.Value).
function codec.DecodeRaw(raw)
    return raw, nil
end

-- DecodeRawSlice decodes a Go []json.Value into an array of raw element texts (nil for null).
function codec.DecodeRawSlice(raw)
    if codec.IsNull(raw) then
        return nil, nil
    end
    local dec = json.NewDecoder(raw)
    local kind = dec:PeekKind()
    if kind ~= "[" then
        return nil, newError("json: cannot unmarshal JSON " .. jsonrpc.kindName(kind) .. " into Go slice")
    end
    dec:ReadToken()
    local result = {}
    while dec:PeekKind() ~= "]" do
        if dec:PeekKind() == 0 then
            return nil, newError("jsontext: unexpected EOF")
        end
        local value, err = dec:ReadValue()
        if err ~= nil then
            return nil, newError(err)
        end
        result[#result + 1] = value
    end
    return result, nil
end

-- DecodeSlice decodes a Go []T with elem(raw) -> (value, err). Returns (array or nil, err).
function codec.DecodeSlice(raw, elem)
    local raws, err = codec.DecodeRawSlice(raw)
    if err ~= nil or raws == nil then
        return nil, err
    end
    local result = {}
    for i, r in ipairs(raws) do
        local v, eerr = elem(r)
        if eerr ~= nil then
            return nil, eerr
        end
        result[i] = v
    end
    return result, nil
end

function codec.DecodeStringSlice(raw)
    return codec.DecodeSlice(raw, codec.DecodeString)
end

-- SliceOf returns a decoder for []T given the element decoder.
function codec.SliceOf(elem)
    return function(raw)
        return codec.DecodeSlice(raw, elem)
    end
end

-- RawKind returns the kind of raw JSON text like jsontext.Value.Kind: 'n', 'f', 't', '"', '0', '{', '['
-- (or 0 when empty).
function codec.RawKind(raw)
    return jsonrpc.NewValue(raw or ""):Kind()
end

-- DecodeOrderedMap decodes a Go *collections.OrderedMap[string, json.Value] (nil for null): values are
-- raw JSON texts. Returns (map, err).
function codec.DecodeOrderedMapOfRaw(raw)
    local collections = require("tslua.collections")
    if codec.IsNull(raw) then
        return nil, nil
    end
    local dec = json.NewDecoder(raw)
    local kind = dec:PeekKind()
    if kind ~= "{" then
        return nil, newError("json: cannot unmarshal JSON " .. jsonrpc.kindName(kind) .. " into Go map")
    end
    dec:ReadToken()
    local m = collections.NewOrderedMapWithSizeHint(0)
    while dec:PeekKind() ~= "}" do
        if dec:PeekKind() == 0 then
            return nil, newError("jsontext: unexpected EOF")
        end
        local name, nerr = dec:ReadToken()
        if nerr ~= nil then
            return nil, newError(nerr)
        end
        if m:Has(name.value) then
            return nil, newError("jsontext: duplicate object member name " .. json.QuoteString(name.value))
        end
        local value, verr = dec:ReadValue()
        if verr ~= nil then
            return nil, newError(verr)
        end
        m:Set(name.value, value)
    end
    return m, nil
end
