local jsonrpc = require("tslua.jsonrpc")
local json = require("tslua.json")

-- Package jsonrpc provides generic JSON-RPC 2.0 types and utilities
-- that can be shared between LSP and other JSON-RPC based protocols.
--
-- json.Value (raw JSON text) is represented by jsonrpc.Value, a wrapper around the raw string
-- (field `data`) that tslua.json marshals verbatim.

local Value = {}
Value.__index = Value
jsonrpc.Value = Value

function jsonrpc.NewValue(data)
    return setmetatable({ data = data }, Value)
end

function Value:MarshalJSON()
    if self.data == "" then
        return "null", nil
    end
    return self.data, nil
end

function Value:String()
    return self.data
end

function Value:Len()
    return #self.data
end

-- jsontext.Value.Kind: the kind of the first token ('n', 'f', 't', '"', '0', '{', '[') or 0.
function Value:Kind()
    local c = string.match(self.data, "^[ \t\r\n]*(.)")
    if c == nil then
        return 0
    elseif c == "-" or string.match(c, "%d") then
        return "0"
    elseif c == "n" or c == "f" or c == "t" or c == '"' or c == "{" or c == "[" then
        return c
    end
    return 0
end

-- JSONRPCVersion represents the JSON-RPC version field, always "2.0".
local JSONRPCVersion = {}
JSONRPCVersion.__index = JSONRPCVersion
jsonrpc.JSONRPCVersion = JSONRPCVersion

jsonrpc.jsonRPCVersion = '"2.0"'

function JSONRPCVersion:MarshalJSON()
    return jsonrpc.jsonRPCVersion, nil
end

jsonrpc.ErrInvalidJSONRPCVersion = jsonrpc.NewError("invalid JSON-RPC version")

function JSONRPCVersion:UnmarshalJSON(data)
    if data ~= jsonrpc.jsonRPCVersion then
        return jsonrpc.ErrInvalidJSONRPCVersion
    end
    return nil
end

-- ID represents a JSON-RPC message ID, which can be either a string or integer.
local ID = {}
ID.__index = ID
jsonrpc.ID = ID

local function newID(str, int)
    return setmetatable({ str = str, int = int }, ID)
end

-- NewID creates an ID from an IntegerOrString value.
function jsonrpc.NewID(rawValue)
    if rawValue.string ~= nil then
        return newID(rawValue.string, 0)
    end
    return newID("", rawValue.integer)
end

-- NewIDString creates a string ID.
function jsonrpc.NewIDString(str)
    return newID(str, 0)
end

-- NewIDInt creates an integer ID.
function jsonrpc.NewIDInt(i)
    return newID("", i)
end

function ID:String()
    if self.str ~= "" then
        return self.str
    end
    return tostring(self.int)
end

-- Map key for map[jsonrpc.ID]T (Go compares the struct by value).
function ID:Key()
    if self.str ~= "" then
        return "s" .. self.str
    end
    return "i" .. tostring(self.int)
end

function ID:MarshalJSON()
    if self.str ~= "" then
        return json.Marshal(self.str)
    end
    return json.Marshal(self.int)
end

-- Fills self from raw JSON. Returns err.
function ID:UnmarshalJSON(data)
    self.str = ""
    self.int = 0
    if #data > 0 and string.sub(data, 1, 1) == '"' then
        local v, err = json.Unmarshal(data)
        if err ~= nil then
            return err
        end
        self.str = v
        return nil
    end
    local v, err = json.Unmarshal(data)
    if err ~= nil then
        return err
    end
    if v == nil then
        return nil
    end
    local i = math.tointeger(v)
    if type(v) ~= "number" or i == nil or i < -2147483648 or i > 2147483647 then
        return "json: cannot unmarshal JSON " .. data .. " into Go int32"
    end
    self.int = i
    return nil
end

-- Decodes an ID from raw JSON. Returns (id, err).
function jsonrpc.UnmarshalID(data)
    local id = newID("", 0)
    local err = id:UnmarshalJSON(data)
    if err ~= nil then
        return nil, err
    end
    return id, nil
end

-- Returns (int, ok).
function ID:TryInt()
    if self == nil or self.str ~= "" then
        return 0, false
    end
    return self.int, true
end

function ID:MustInt()
    if self.str ~= "" then
        error("ID is not an integer", 0)
    end
    return self.int
end

-- IntegerOrString is a helper type for creating IDs: { integer = n } or { string = s }.

-- ResponseError represents a JSON-RPC error response.
local ResponseError = {}
ResponseError.__index = ResponseError
jsonrpc.ResponseError = ResponseError

function jsonrpc.NewResponseError(code, message, data)
    return setmetatable({ code = code or 0, message = message or "", data = data }, ResponseError)
end

function ResponseError:String()
    if self == nil then
        return ""
    end
    local data, err = json.Marshal(self.data)
    if err ~= nil then
        return "[" .. tostring(self.code) .. "]: " .. self.message .. "\n" .. tostring(data)
    end
    return "[" .. tostring(self.code) .. "]: " .. self.message
end

function ResponseError:Error()
    return self:String()
end

function ResponseError:MarshalJSON()
    local parts = { '{"code":', tostring(self.code or 0), ',"message":', json.QuoteString(self.message or "") }
    if self.data ~= nil then
        local data, err = json.Marshal(self.data)
        if err ~= nil then
            return nil, err
        end
        parts[#parts + 1] = ',"data":'
        parts[#parts + 1] = data
    end
    parts[#parts + 1] = "}"
    return table.concat(parts), nil
end

-- Decodes a ResponseError object from the decoder. Returns (responseError, err).
function jsonrpc.decodeResponseError(dec)
    if dec:PeekKind() == "n" then
        dec:ReadToken()
        return nil, nil
    end
    local v, err = json.UnmarshalDecode(dec)
    if err ~= nil then
        return nil, err
    end
    if type(v) ~= "table" then
        return nil, "json: cannot unmarshal JSON value into Go jsonrpc.ResponseError"
    end
    local code = v.code
    if code ~= nil then
        code = math.tointeger(code)
        if code == nil then
            return nil, "json: cannot unmarshal JSON number into Go int32"
        end
    end
    return jsonrpc.NewResponseError(code or 0, type(v.message) == "string" and v.message or "", v.data), nil
end

-- MessageKind indicates what type of message this is (jsonrpc.MessageKind.*).

-- Message represents a raw JSON-RPC message that can be a request, notification, or response.
-- Unlike lsproto.Message, this keeps params/result as raw JSON (jsonrpc.Value) for generic handling.
local Message = {}
Message.__index = Message
jsonrpc.Message = Message

function jsonrpc.NewMessage(fields)
    local m = setmetatable(fields or {}, Message)
    if m.method == nil then
        m.method = ""
    end
    return m
end

-- Kind returns the kind of message this is.
function Message:Kind()
    if self.id ~= nil and self.method == "" then
        return jsonrpc.MessageKind.Response
    end
    if self.id == nil then
        return jsonrpc.MessageKind.Notification
    end
    return jsonrpc.MessageKind.Request
end

-- IsRequest returns true if this message is a request (has ID and method).
function Message:IsRequest()
    return self.id ~= nil and self.method ~= ""
end

-- IsNotification returns true if this message is a notification (has method but no ID).
function Message:IsNotification()
    return self.id == nil and self.method ~= ""
end

-- IsResponse returns true if this message is a response (has ID but no method).
function Message:IsResponse()
    return self.id ~= nil and self.method == ""
end

local function isZeroValue(v)
    return v == nil or (getmetatable(v) == Value and v.data == "")
end

-- Field order and omitzero handling of the Go struct tags.
function Message:MarshalJSON()
    local parts = { '{"jsonrpc":"2.0"' }
    local function add(name, v)
        local s, err = json.Marshal(v)
        if err ~= nil then
            return err
        end
        parts[#parts + 1] = ',"' .. name .. '":' .. s
        return nil
    end
    local err
    if self.id ~= nil then
        err = add("id", self.id)
    end
    if err == nil and self.method ~= "" then
        err = add("method", self.method)
    end
    if err == nil and not isZeroValue(self.params) then
        err = add("params", self.params)
    end
    if err == nil and not isZeroValue(self.result) then
        err = add("result", self.result)
    end
    if err == nil and self.error ~= nil then
        err = add("error", self.error)
    end
    if err ~= nil then
        return nil, err
    end
    parts[#parts + 1] = "}"
    return table.concat(parts), nil
end

-- Decodes the members of a JSON-RPC message object, keeping params/result raw. Shared by
-- jsonrpc.Message and lsproto.Message. Returns (raw, err) where raw has the fields jsonrpc
-- (bool, true when present), id, method, params, result, error.
function jsonrpc.decodeRawMessage(data)
    local dec = json.NewDecoder(data)
    local raw = { method = "" }
    local kind = dec:PeekKind()
    if kind == "n" then
        return raw, nil
    end
    if kind ~= "{" then
        return nil, "json: cannot unmarshal JSON " .. jsonrpc.kindName(kind) .. " into Go struct"
    end
    dec:ReadToken()
    local seen = {}
    while dec:PeekKind() ~= "}" do
        local tok, err = dec:ReadToken()
        if err ~= nil then
            return nil, err
        end
        if tok.kind ~= '"' then
            return nil, "jsontext: invalid character " .. jsonrpc.goQuote(tok.raw) .. " at start of object name"
        end
        local name = tok.value
        if seen[name] then
            return nil, "jsontext: duplicate object member name " .. json.QuoteString(name)
        end
        seen[name] = true
        local value
        value, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        if name == "jsonrpc" then
            err = JSONRPCVersion.UnmarshalJSON(nil, value)
            raw.jsonrpc = true
        elseif name == "method" then
            if value ~= "null" then
                local s
                s, err = json.Unmarshal(value)
                if err == nil and type(s) ~= "string" then
                    err = "json: cannot unmarshal JSON " .. value .. " into Go string"
                end
                raw.method = s or ""
            end
        elseif name == "id" then
            if value ~= "null" then
                raw.id, err = jsonrpc.UnmarshalID(value)
            end
        elseif name == "params" then
            raw.params = jsonrpc.NewValue(value)
        elseif name == "result" then
            raw.result = jsonrpc.NewValue(value)
        elseif name == "error" then
            raw.error, err = jsonrpc.decodeResponseError(json.NewDecoder(value))
        end
        if err ~= nil then
            return nil, err
        end
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end
    dec:skipWS()
    if dec.pos <= #dec.s then
        return nil, "jsontext: invalid character after top-level value"
    end
    return raw, nil
end

-- jsontext.Kind.String
function jsonrpc.kindName(k)
    if k == "n" then
        return "null"
    elseif k == "f" then
        return "false"
    elseif k == "t" then
        return "true"
    elseif k == '"' then
        return "string"
    elseif k == "0" then
        return "number"
    elseif k == "{" or k == "}" or k == "[" or k == "]" then
        return k
    end
    return "<invalid jsontext.Kind: '\\x00'>"
end

function Message:UnmarshalJSON(data)
    local raw, err = jsonrpc.decodeRawMessage(data)
    if err ~= nil then
        return err
    end
    self.id = raw.id
    self.method = raw.method
    self.params = raw.params
    self.result = raw.result
    self.error = raw.error
    return nil
end

-- RequestMessage is a convenience type for creating request/notification messages.
local RequestMessage = {}
RequestMessage.__index = RequestMessage
jsonrpc.RequestMessage = RequestMessage

function RequestMessage:MarshalJSON()
    local parts = { '{"jsonrpc":"2.0"' }
    if self.id ~= nil then
        local s, err = self.id:MarshalJSON()
        if err ~= nil then
            return nil, err
        end
        parts[#parts + 1] = ',"id":' .. s
    end
    parts[#parts + 1] = ',"method":' .. json.QuoteString(self.method or "")
    if self.params ~= nil then
        local s, err = json.Marshal(self.params)
        if err ~= nil then
            return nil, err
        end
        parts[#parts + 1] = ',"params":' .. s
    end
    parts[#parts + 1] = "}"
    return table.concat(parts), nil
end

-- ResponseMessage is a convenience type for creating response messages.
local ResponseMessage = {}
ResponseMessage.__index = ResponseMessage
jsonrpc.ResponseMessage = ResponseMessage

function ResponseMessage:MarshalJSON()
    local parts = { '{"jsonrpc":"2.0"' }
    if self.id ~= nil then
        local s, err = self.id:MarshalJSON()
        if err ~= nil then
            return nil, err
        end
        parts[#parts + 1] = ',"id":' .. s
    end
    if self.result ~= nil then
        local s, err = json.Marshal(self.result)
        if err ~= nil then
            return nil, err
        end
        parts[#parts + 1] = ',"result":' .. s
    end
    if self.error ~= nil then
        local s, err = self.error:MarshalJSON()
        if err ~= nil then
            return nil, err
        end
        parts[#parts + 1] = ',"error":' .. s
    end
    parts[#parts + 1] = "}"
    return table.concat(parts), nil
end
