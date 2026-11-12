local ipc = require("tslua.ipc")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")

-- JSONRPCProtocol implements the Protocol interface using JSON-RPC 2.0
-- with the LSP base protocol framing (Content-Length headers).
local JSONRPCProtocol = {}
JSONRPCProtocol.__index = JSONRPCProtocol
ipc.JSONRPCProtocol = JSONRPCProtocol

-- NewJSONRPCProtocol creates a new JSON-RPC protocol handler.
function ipc.NewJSONRPCProtocol(rw)
    return setmetatable({
        reader = jsonrpc.NewReader(rw),
        writer = jsonrpc.NewWriter(rw),
    }, JSONRPCProtocol)
end

-- ReadMessage implements Protocol.
function JSONRPCProtocol:ReadMessage()
    local data, err = self.reader:Read()
    if err ~= nil then
        return nil, err
    end

    local msg = jsonrpc.NewMessage()
    err = msg:UnmarshalJSON(data)
    if err ~= nil then
        return nil, err
    end

    return msg, nil
end

local function newRequestMessage(id, method, params)
    return setmetatable({ id = id, method = method, params = params }, jsonrpc.RequestMessage)
end

local function newResponseMessage(id, result, responseError)
    return setmetatable({ id = id, result = result, error = responseError }, jsonrpc.ResponseMessage)
end

-- WriteRequest implements Protocol.
function JSONRPCProtocol:WriteRequest(id, method, params)
    local msg = newRequestMessage(id, method, params)
    local data, err = json.Marshal(msg)
    if err ~= nil then
        return err
    end
    return self.writer:Write(data)
end

-- WriteNotification implements Protocol.
function JSONRPCProtocol:WriteNotification(method, params)
    local msg = newRequestMessage(nil, method, params)
    local data, err = json.Marshal(msg)
    if err ~= nil then
        return err
    end
    return self.writer:Write(data)
end

-- WriteResponse implements Protocol.
function JSONRPCProtocol:WriteResponse(id, result)
    if result == nil then
        result = jsonrpc.NewValue("null")
    end
    local msg = newResponseMessage(id, result, nil)
    local data, err = json.Marshal(msg)
    if err ~= nil then
        return err
    end
    return self.writer:Write(data)
end

-- WriteError implements Protocol.
function JSONRPCProtocol:WriteError(id, respErr)
    local msg = newResponseMessage(id, nil, respErr)
    local data, err = json.Marshal(msg)
    if err ~= nil then
        return err
    end
    return self.writer:Write(data)
end
