local collections = require("tslua.collections")
local json = require("tslua.json")

-- OrderedMap is an insertion ordered map.
-- Fields: keys (array of keys in insertion order), mp (key -> value). nil values are stored as
-- an internal sentinel so that Has/Get report presence like Go. Methods tolerate a nil receiver
-- where Go's do (call as collections.OrderedMap.Size(m) when m may be nil).
-- Keys()/Values()/Entries() return Lua iterators (for k in m:Keys() do ... end); like Go, they
-- enumerate items added during iteration. Values()/Entries() stop early at a nil value.
local OrderedMap = {}
OrderedMap.__index = OrderedMap
collections.OrderedMap = OrderedMap

local NIL = setmetatable({}, {
    __tostring = function()
        return "collections.nil"
    end,
})

local function wrap(v)
    if v == nil then
        return NIL
    end
    return v
end

local function unwrap(v)
    if v == NIL then
        return nil
    end
    return v
end

-- NewOrderedMapWithSizeHint creates a new OrderedMap with a hint for the number of elements it will contain.
function collections.NewOrderedMapWithSizeHint(hint)
    return collections.newMapWithSizeHint(hint)
end

function collections.newMapWithSizeHint(hint)
    return setmetatable({ keys = {}, mp = {} }, OrderedMap)
end

-- Zero value (Go `var m collections.OrderedMap[K, V]` / `&collections.OrderedMap[K, V]{}`).
function collections.NewOrderedMap()
    return collections.newMapWithSizeHint(0)
end

-- MapEntry: { key = K, value = V }

-- items is an array of { key = ..., value = ... }.
function collections.NewOrderedMapFromList(items)
    local mp = collections.NewOrderedMapWithSizeHint(#items)
    for _, item in ipairs(items) do
        mp:Set(item.key, item.value)
    end
    return mp
end

-- Set sets a key-value pair in the map.
function OrderedMap:Set(key, value)
    if self.mp == nil then
        self.mp = {}
    end
    if self.keys == nil then
        self.keys = {}
    end

    if self.mp[key] == nil then
        self.keys[#self.keys + 1] = key
    end
    self.mp[key] = wrap(value)
end

-- Get retrieves a value from the map. Returns (value, ok).
function OrderedMap:Get(key)
    if self == nil or self.mp == nil then
        return nil, false
    end
    local v = self.mp[key]
    if v == nil then
        return nil, false
    end
    return unwrap(v), true
end

-- GetOrZero retrieves a value from the map, or returns the zero value of the value type if the key is not present.
function OrderedMap:GetOrZero(key)
    if self == nil or self.mp == nil then
        return nil
    end
    return unwrap(self.mp[key])
end

-- EntryAt retrieves the key-value pair at the specified (0-based) index. Returns (key, value, ok).
function OrderedMap:EntryAt(index)
    if self == nil or self.keys == nil or index < 0 or index >= #self.keys then
        return nil, nil, false
    end

    local key = self.keys[index + 1]
    local value = unwrap(self.mp[key])
    return key, value, true
end

-- Has returns true if the map contains the key.
function OrderedMap:Has(key)
    if self == nil or self.mp == nil then
        return false
    end
    return self.mp[key] ~= nil
end

-- Delete removes a key-value pair from the map. Returns (value, ok).
function OrderedMap:Delete(key)
    if self.mp == nil then
        return nil, false
    end
    local v = self.mp[key]
    if v == nil then
        return nil, false
    end

    self.mp[key] = nil
    local keys = self.keys
    for i = 1, #keys do
        if keys[i] == key then
            table.remove(keys, i)
            break
        end
    end

    return unwrap(v), true
end

-- Keys returns an iterator over the keys in the map.
-- An array of the keys can be obtained by calling `core.Collect`.
function OrderedMap:Keys()
    local i = 0
    return function()
        if self == nil or self.keys == nil then
            return nil
        end
        -- We use an index here to ensure we enumerate new items added during iteration.
        i = i + 1
        return self.keys[i]
    end
end

-- Values returns an iterator over the values in the map.
function OrderedMap:Values()
    local i = 0
    return function()
        if self == nil or self.keys == nil then
            return nil
        end
        i = i + 1
        local key = self.keys[i]
        if key == nil then
            return nil
        end
        return unwrap(self.mp[key])
    end
end

-- Entries returns an iterator over the key-value pairs in the map.
function OrderedMap:Entries()
    local i = 0
    return function()
        if self == nil or self.keys == nil then
            return nil
        end
        i = i + 1
        local key = self.keys[i]
        if key == nil then
            return nil
        end
        return key, unwrap(self.mp[key])
    end
end

-- Clear removes all key-value pairs from the map.
function OrderedMap:Clear()
    self.keys = {}
    self.mp = {}
end

-- Size returns the number of key-value pairs in the map.
function OrderedMap:Size()
    if self == nil or self.keys == nil then
        return 0
    end

    return #self.keys
end

-- Clone returns a shallow copy of the map.
function OrderedMap:Clone()
    if self == nil then
        return nil
    end

    return self:clone()
end

function OrderedMap:clone()
    local keys, mp = {}, {}
    if self.keys ~= nil then
        for i, k in ipairs(self.keys) do
            keys[i] = k
            mp[k] = self.mp[k]
        end
    end
    return setmetatable({ keys = keys, mp = mp }, OrderedMap)
end

-- Go MarshalJSONTo: an object with members in insertion order. Returns (string, err).
function OrderedMap:MarshalJSON()
    local parts = {}
    for i, k in ipairs(self.keys or {}) do
        local keyString, err = collections.resolveKeyName(k)
        if err ~= nil then
            return nil, err
        end
        local value
        value, err = json.Marshal(unwrap(self.mp[k]))
        if err ~= nil then
            return nil, err
        end
        parts[i] = json.QuoteString(keyString) .. ":" .. value
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end

function collections.resolveKeyName(k)
    if type(k) == "string" then
        return k, nil
    end
    if type(k) == "table" and type(k.MarshalText) == "function" then
        return k:MarshalText()
    end
    if math.type(k) == "integer" then
        return string.format("%d", k), nil
    end
    error("unexpected map key type", 0)
end

-- Go UnmarshalJSONFrom: decodes the next value of dec (a json.Decoder) into m. Values are
-- decoded generically (see tslua.json). Returns err.
function OrderedMap:UnmarshalJSONFrom(dec)
    local token, err = dec:ReadToken()
    if err ~= nil then
        return err
    end
    if token:Kind() == "n" then
        -- By convention, to approximate the behavior of Unmarshal itself,
        -- Unmarshalers implement UnmarshalJSON([]byte("null")) as a no-op.
        return nil
    end
    if token:Kind() ~= "{" then
        return "cannot unmarshal non-object JSON value into Map"
    end
    while dec:PeekKind() ~= "}" do
        local key, value
        key, err = json.UnmarshalDecode(dec)
        if err ~= nil then
            return err
        end
        value, err = json.UnmarshalDecode(dec)
        if err ~= nil then
            return err
        end
        self:Set(key, value)
    end
    local _
    _, err = dec:ReadToken()
    if err ~= nil then
        return err
    end
    return nil
end

function collections.DiffOrderedMaps(m1, m2, onAdded, onRemoved, onModified)
    collections.DiffOrderedMapsFunc(m1, m2, function(a, b)
        return a == b
    end, onAdded, onRemoved, onModified)
end

function collections.DiffOrderedMapsFunc(m1, m2, equalValues, onAdded, onRemoved, onModified)
    for k, v2 in OrderedMap.Entries(m2) do
        local _, ok = OrderedMap.Get(m1, k)
        if not ok then
            onAdded(k, v2)
        end
    end
    for k, v1 in OrderedMap.Entries(m1) do
        local v2, ok = OrderedMap.Get(m2, k)
        if ok then
            if not equalValues(v1, v2) then
                onModified(k, v1, v2)
            end
        else
            onRemoved(k, v1)
        end
    end
end
