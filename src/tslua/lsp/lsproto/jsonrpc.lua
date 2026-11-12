local lsproto = require("tslua.lsp.lsproto")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")

-- NewID creates an ID from an IntegerOrString value.
-- This wrapper exists because lsproto has its own IntegerOrString type.
function lsproto.NewID(rawValue)
    if rawValue.string ~= nil then
        return jsonrpc.NewIDString(rawValue.string)
    end
    return jsonrpc.NewIDInt(rawValue.integer)
end

local Message = {}
Message.__index = Message
lsproto.Message = Message

function lsproto.NewMessage()
    return setmetatable({ kind = jsonrpc.MessageKind.Notification, msg = nil }, Message)
end

function Message:AsRequest()
    return self.msg
end

function Message:AsResponse()
    return self.msg
end

-- Fills self from raw JSON. Returns err.
function Message:UnmarshalJSON(data)
    local raw, err = jsonrpc.decodeRawMessage(data)
    if err ~= nil then
        return lsproto.newCodeError(lsproto.ErrorCode.InvalidRequest, jsonrpc.ErrorString(err), err)
    end
    if raw.id ~= nil and raw.method == "" then
        self.kind = jsonrpc.MessageKind.Response
        self.msg = lsproto.NewResponseMessage(raw.id, raw.result, raw.error)
        return nil
    end

    local params
    if raw.params ~= nil and #raw.params.data > 0 then
        params = raw.params
    end

    if raw.id == nil then
        self.kind = jsonrpc.MessageKind.Notification
    else
        self.kind = jsonrpc.MessageKind.Request
    end

    self.msg = lsproto.NewRequestMessage(raw.id, raw.method, params)

    return nil
end

function Message:MarshalJSON()
    return json.Marshal(self.msg)
end

-- RequestMessage { id, method, params }. paramsType (Lua-only) is the Go type string of params
-- for marshaling (set by RequestInfo/NotificationInfo); without it params marshal generically.
local RequestMessage = {}
RequestMessage.__index = RequestMessage
lsproto.RequestMessage = RequestMessage

function lsproto.NewRequestMessage(id, method, params, paramsType)
    return setmetatable({ id = id, method = method or "", params = params, paramsType = paramsType }, RequestMessage)
end

function RequestMessage:Message()
    local kind = jsonrpc.MessageKind.Request
    if self.id == nil then
        kind = jsonrpc.MessageKind.Notification
    end
    return setmetatable({ kind = kind, msg = self }, Message)
end

-- Encodes an `any` value, using goType when it is known and the value is not raw JSON.
local function encodeAny(buf, goType, v)
    if goType ~= nil and not (type(v) == "table" and getmetatable(v) == jsonrpc.Value) then
        return lsproto.encode(buf, goType, v)
    end
    return lsproto.encode(buf, "any", v)
end

local function isZeroAny(goType, v)
    if v == nil then
        return true
    end
    if type(v) == "table" and getmetatable(v) == jsonrpc.Value then
        return v.data == ""
    end
    if goType ~= nil then
        return goType == "NoParams" or v == lsproto.NoParams
    end
    return v == lsproto.NoParams
end

function RequestMessage:MarshalJSON()
    local buf = { '{"jsonrpc":"2.0"' }
    if self.id ~= nil then
        buf[#buf + 1] = ',"id":'
        local s, err = self.id:MarshalJSON()
        if err ~= nil then
            return nil, err
        end
        buf[#buf + 1] = s
    end
    buf[#buf + 1] = ',"method":'
    buf[#buf + 1] = json.QuoteString(self.method)
    if not isZeroAny(self.paramsType, self.params) then
        buf[#buf + 1] = ',"params":'
        local err = encodeAny(buf, self.paramsType, self.params)
        if err ~= nil then
            return nil, err
        end
    end
    buf[#buf + 1] = "}"
    return table.concat(buf), nil
end

-- Fills self from raw JSON. Returns err.
function RequestMessage:UnmarshalJSON(data)
    local raw, err = jsonrpc.decodeRawMessage(data)
    if err ~= nil then
        return lsproto.newCodeError(lsproto.ErrorCode.InvalidRequest, jsonrpc.ErrorString(err), err)
    end

    self.id = raw.id
    self.method = raw.method
    if raw.params ~= nil and #raw.params.data > 0 then
        self.params = raw.params
    end

    return nil
end

-- ResponseMessage { id, result, error }. resultType (Lua-only) is the Go type string of result
-- for marshaling; when set, the result is always written (a Go typed value in an `any` is never
-- a nil interface).
local ResponseMessage = {}
ResponseMessage.__index = ResponseMessage
lsproto.ResponseMessage = ResponseMessage

function lsproto.NewResponseMessage(id, result, err, resultType)
    return setmetatable({ id = id, result = result, error = err, resultType = resultType }, ResponseMessage)
end

function ResponseMessage:Message()
    return setmetatable({ kind = jsonrpc.MessageKind.Response, msg = self }, Message)
end

function ResponseMessage:MarshalJSON()
    local buf = { '{"jsonrpc":"2.0","id":' }
    if self.id ~= nil then
        local s, err = self.id:MarshalJSON()
        if err ~= nil then
            return nil, err
        end
        buf[#buf + 1] = s
    else
        buf[#buf + 1] = "null"
    end
    if self.resultType ~= nil or not isZeroAny(nil, self.result) then
        buf[#buf + 1] = ',"result":'
        local err = encodeAny(buf, self.resultType, self.result)
        if err ~= nil then
            return nil, err
        end
    end
    if self.error ~= nil then
        buf[#buf + 1] = ',"error":'
        local s, err = self.error:MarshalJSON()
        if err ~= nil then
            return nil, err
        end
        buf[#buf + 1] = s
    end
    buf[#buf + 1] = "}"
    return table.concat(buf), nil
end
