local api = require("tslua.api")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")

local MessageType = api.MessageType

-- MessageType.IsValid
function api.MessageType_IsValid(m)
    return m >= MessageType.Request and m <= MessageType.Call
end

-- MessagePack format constants
api.msgpackFixedArray3 = 0x93
api.msgpackBin8 = 0xC4
api.msgpackBin16 = 0xC5
api.msgpackBin32 = 0xC6
api.msgpackU8 = 0xCC

-- RawBinary is a marker type for binary data that should be written
-- directly by MessagePackProtocol instead of being JSON-encoded.
local RawBinary = {}
RawBinary.__index = RawBinary
api.RawBinary = RawBinary

function api.NewRawBinary(data)
    return setmetatable({ data = data }, RawBinary)
end

-- MessagePackProtocol implements the Protocol interface using a custom
-- msgpack-based tuple format: [MessageType, method, payload].
-- rw follows the tslua.jsonrpc stream contract: read(n) with Lua file semantics (nil at end of
-- input), and either Write(s) -> (n, err) or Lua file write/flush. Writes are buffered (bufio)
-- and flushed once per tuple.
local MessagePackProtocol = {}
MessagePackProtocol.__index = MessagePackProtocol
api.MessagePackProtocol = MessagePackProtocol

-- NewMessagePackProtocol creates a new msgpack protocol handler.
function api.NewMessagePackProtocol(rw)
    return setmetatable({ rw = rw, wbuf = {} }, MessagePackProtocol)
end

-- readFull reads exactly n bytes. Returns (string, err); io.EOF when nothing could be read,
-- io.ErrUnexpectedEOF on a partial read.
function MessagePackProtocol:readFull(n)
    if n == 0 then
        return "", nil
    end
    local parts = {}
    local remaining = n
    while remaining > 0 do
        local ok, chunk = pcall(self.rw.read, self.rw, remaining)
        if not ok then
            return nil, chunk
        end
        if chunk == nil or #chunk == 0 then
            if remaining < n then
                return nil, jsonrpc.ErrUnexpectedEOF
            end
            return nil, jsonrpc.EOF
        end
        parts[#parts + 1] = chunk
        remaining = remaining - #chunk
    end
    return table.concat(parts), nil
end

function MessagePackProtocol:readByte()
    local b, err = self:readFull(1)
    if err ~= nil then
        return 0, err
    end
    return string.byte(b), nil
end

-- ReadMessage implements Protocol. Returns (message, err).
function MessagePackProtocol:ReadMessage()
    local msgType, method, payload, err = self:readTuple()
    if err ~= nil then
        return nil, err
    end

    -- Convert msgpack message type to JSON-RPC message
    local msg = jsonrpc.NewMessage()

    if msgType == MessageType.Request then
        -- Client request - needs an ID for response
        -- We use the method as a pseudo-ID since this protocol doesn't have explicit IDs
        local id = jsonrpc.NewIDString(method)
        msg.id = id
        msg.method = method
        msg.params = jsonrpc.NewValue(payload)
    elseif msgType == MessageType.CallResponse then
        -- Response to our Call - use method as ID
        -- Note: Method must be empty for IsResponse() to return true
        local id = jsonrpc.NewIDString(method)
        msg.id = id
        msg.result = jsonrpc.NewValue(payload)
    elseif msgType == MessageType.CallError then
        -- Error response to our Call
        -- Note: Method must be empty for IsResponse() to return true
        local id = jsonrpc.NewIDString(method)
        msg.id = id
        msg.error = jsonrpc.NewResponseError(jsonrpc.CodeInternalError, payload)
    else
        return nil, jsonrpc.NewError("unexpected message type: " .. tostring(msgType))
    end

    return msg, nil
end

-- Returns (msgType, method, payload, err).
function MessagePackProtocol:readTuple()
    -- Read fixed array marker (0x93 = 3-element array)
    local t, err = self:readByte()
    if err ~= nil then
        return 0, "", nil, err
    end
    if t ~= api.msgpackFixedArray3 then
        return 0, "", nil, jsonrpc.NewError(string.format("%s: expected fixed 3-element array (0x93), received: 0x%02x", api.ErrInvalidRequest:Error(), t), api.ErrInvalidRequest)
    end

    -- Read message type - can be positive fixint (0x00-0x7F) or uint8 (0xCC + value)
    t, err = self:readByte()
    if err ~= nil then
        return 0, "", nil, err
    end
    local rawType
    if t <= 0x7F then
        -- Positive fixint - the byte IS the value
        rawType = t
    elseif t == api.msgpackU8 then
        -- uint8 marker - next byte is the value
        rawType, err = self:readByte()
        if err ~= nil then
            return 0, "", nil, err
        end
    else
        return 0, "", nil, jsonrpc.NewError(string.format("%s: expected positive fixint or uint8 marker, received: 0x%02x", api.ErrInvalidRequest:Error(), t), api.ErrInvalidRequest)
    end
    local msgType = rawType
    if not api.MessageType_IsValid(msgType) then
        return 0, "", nil, jsonrpc.NewError(api.ErrInvalidRequest:Error() .. ": unknown message type: " .. tostring(msgType), api.ErrInvalidRequest)
    end

    -- Read method (binary)
    local methodBytes
    methodBytes, err = self:readBin()
    if err ~= nil then
        return 0, "", nil, err
    end
    local method = methodBytes

    -- Read payload (binary)
    local payload
    payload, err = self:readBin()
    if err ~= nil then
        return 0, "", nil, err
    end

    return msgType, method, payload, nil
end

-- Returns (string, err).
function MessagePackProtocol:readBin()
    local t, err = self:readByte()
    if err ~= nil then
        return nil, err
    end

    local size
    if t == api.msgpackBin8 then
        local b
        b, err = self:readFull(1)
        if err ~= nil then
            return nil, err
        end
        size = string.unpack(">I1", b)
    elseif t == api.msgpackBin16 then
        local b
        b, err = self:readFull(2)
        if err ~= nil then
            return nil, err
        end
        size = string.unpack(">I2", b)
    elseif t == api.msgpackBin32 then
        local b
        b, err = self:readFull(4)
        if err ~= nil then
            return nil, err
        end
        size = string.unpack(">I4", b)
    else
        return nil, jsonrpc.NewError(string.format("%s: expected binary data (0xc4-0xc6), received: 0x%02x", api.ErrInvalidRequest:Error(), t), api.ErrInvalidRequest)
    end

    local payload
    payload, err = self:readFull(size)
    if err ~= nil then
        if err == jsonrpc.EOF then
            err = jsonrpc.ErrUnexpectedEOF
        end
        return nil, err
    end
    return payload, nil
end

-- WriteRequest implements Protocol.
function MessagePackProtocol:WriteRequest(id, method, params)
    -- For msgpack protocol, requests from server are "Call" type
    local payload, err = json.Marshal(params)
    if err ~= nil then
        return err
    end
    return self:writeTuple(MessageType.Call, method, payload)
end

-- WriteNotification implements Protocol.
function MessagePackProtocol:WriteNotification(method, params)
    -- Msgpack protocol doesn't distinguish notifications from calls
    return self:WriteRequest(nil, method, params)
end

-- WriteResponse implements Protocol.
function MessagePackProtocol:WriteResponse(id, result)
    local method = ""
    if id ~= nil then
        method = id:String()
    end

    local payload
    local err

    -- Check if result is raw binary (for efficient binary transport)
    if type(result) == "table" and getmetatable(result) == RawBinary then
        payload = result.data
    else
        payload, err = json.Marshal(result)
        if err ~= nil then
            return err
        end
    end

    return self:writeTuple(MessageType.Response, method, payload)
end

-- WriteError implements Protocol.
function MessagePackProtocol:WriteError(id, respErr)
    local method = ""
    if id ~= nil then
        method = id:String()
    end
    return self:writeTuple(MessageType.Error, method, respErr.message)
end

function MessagePackProtocol:writeTuple(msgType, method, payload)
    -- Write fixed array marker
    self.wbuf[#self.wbuf + 1] = string.char(api.msgpackFixedArray3)
    -- Write message type as positive fixint (values 0-127 are written directly)
    self.wbuf[#self.wbuf + 1] = string.char(msgType)
    -- Write method
    self:writeBin(method)
    -- Write payload
    self:writeBin(payload)
    return self:flush()
end

function MessagePackProtocol:writeBin(data)
    local length = #data
    if length < 256 then
        self.wbuf[#self.wbuf + 1] = string.char(api.msgpackBin8, length)
    elseif length < 1 << 16 then
        self.wbuf[#self.wbuf + 1] = string.char(api.msgpackBin16) .. string.pack(">I2", length)
    else
        self.wbuf[#self.wbuf + 1] = string.char(api.msgpackBin32) .. string.pack(">I4", length)
    end
    self.wbuf[#self.wbuf + 1] = data
    return nil
end

-- flush writes the buffered bytes to rw (bufio.Writer.Flush). Returns err.
function MessagePackProtocol:flush()
    local s = table.concat(self.wbuf)
    self.wbuf = {}
    local w = self.rw
    if type(w.Write) == "function" then
        local _, err = w:Write(s)
        if err ~= nil then
            return err
        end
        if type(w.Flush) == "function" then
            return w:Flush()
        end
        return nil
    end
    local ok, res, msg = pcall(w.write, w, s)
    if not ok then
        return res
    end
    if res == nil then
        return msg
    end
    if w.flush ~= nil then
        ok, res, msg = pcall(w.flush, w)
        if not ok then
            return res
        end
        if res == nil then
            return msg
        end
    end
    return nil
end
