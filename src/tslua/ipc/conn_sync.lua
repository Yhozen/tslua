local ipc = require("tslua.ipc")
local core = require("tslua.core")
local jsonrpc = require("tslua.jsonrpc")

-- SyncConn manages bidirectional communication with synchronous request handling.
-- Requests are handled one at a time inline, and outgoing calls are serialized.
-- timing, when non-nil, accumulates the time spent handling each request; clients retrieve the
-- collected data via a getServerTiming request. Go's mutex is dropped (everything is sequential).
local SyncConn = {}
SyncConn.__index = SyncConn
ipc.SyncConn = SyncConn

-- NewSyncConn creates a new sync connection with the given transport and handler.
function ipc.NewSyncConn(rwc, protocol, handler)
    return setmetatable({
        rwc = rwc,
        protocol = protocol,
        handler = handler,
        timing = nil,
    }, SyncConn)
end

-- SetCollectTiming enables or disables per-request server processing-time
-- measurement. When enabled, the connection accumulates timing that clients can
-- retrieve via a getServerTiming request.
function SyncConn:SetCollectTiming(enabled)
    if enabled then
        self.timing = ipc.newTimingCollector()
    else
        self.timing = nil
    end
end

-- Run starts processing messages on the connection.
-- It blocks until the context is cancelled or an error occurs. Returns err.
function SyncConn:Run(ctx)
    while true do
        local ctxErr = core.ContextErr(ctx)
        if ctxErr ~= nil then
            return ctxErr
        end

        local msg, err = self.protocol:ReadMessage()

        if err ~= nil then
            if jsonrpc.ErrorsIs(err, jsonrpc.EOF) then
                return nil
            end
            return err
        end

        if msg:IsRequest() then
            self:handleRequest(ctx, msg)
        elseif msg:IsNotification() then
            self:handleNotification(ctx, msg)
        else
            -- Responses are not expected in the main loop - they are read inline by Call().
            return jsonrpc.NewError("ipc: unexpected response message in sync connection")
        end
    end
end

-- handleRequest processes an incoming request.
function SyncConn:handleRequest(ctx, msg)
    -- Intercept the meta-requests for collected server timing before dispatching
    -- to the handler, so they are answered directly and not themselves recorded.
    if msg.method == ipc.MethodGetServerTiming then
        local writeErr = self.protocol:WriteResponse(msg.id, ipc.serverTimingSnapshot(self.timing))
        if writeErr ~= nil then
            error("ipc: failed to write server timing response: " .. jsonrpc.ErrorString(writeErr), 0)
        end
        return
    elseif msg.method == ipc.MethodResetServerTiming then
        if self.timing ~= nil then
            self.timing:reset()
        end
        local writeErr = self.protocol:WriteResponse(msg.id, nil)
        if writeErr ~= nil then
            error("ipc: failed to write reset server timing response: " .. jsonrpc.ErrorString(writeErr), 0)
        end
        return
    end

    local start = 0
    if self.timing ~= nil then
        start = ipc.now()
    end

    -- Recover from panics and convert to error response with stack trace
    local ok, result, err = xpcall(function()
        return self.handler:HandleRequest(ctx, msg.method, msg.params)
    end, function(r)
        return "panic: " .. jsonrpc.ErrorString(r) .. "\n" .. debug.traceback()
    end)
    if not ok then
        local writeErr = self.protocol:WriteError(msg.id, jsonrpc.NewResponseError(jsonrpc.CodeInternalError, result))
        if writeErr ~= nil then
            error("ipc: failed to write panic error response: " .. jsonrpc.ErrorString(writeErr) .. " (original panic: " .. tostring(result) .. ")", 0)
        end
        return
    end

    if self.timing ~= nil then
        self.timing:record(msg.method, ipc.now() - start)
    end

    local writeErr
    if err ~= nil then
        writeErr = self.protocol:WriteError(msg.id, jsonrpc.NewResponseError(jsonrpc.CodeInternalError, jsonrpc.ErrorString(err)))
    else
        writeErr = self.protocol:WriteResponse(msg.id, result)
    end

    if writeErr ~= nil then
        error("ipc: failed to write response: " .. jsonrpc.ErrorString(writeErr), 0)
    end
end

-- handleNotification processes an incoming notification.
function SyncConn:handleNotification(ctx, msg)
    self.handler:HandleNotification(ctx, msg.method, msg.params)
end

-- Call sends a request to the client and waits for a response. Returns (jsonrpc.Value, err).
function SyncConn:Call(ctx, method, params)
    local id = jsonrpc.NewIDString(method)

    local err = self.protocol:WriteRequest(id, method, params)
    if err ~= nil then
        return nil, err
    end

    local ctxErr = core.ContextErr(ctx)
    if ctxErr ~= nil then
        return nil, ctxErr
    end

    -- Read the response inline.
    local msg
    msg, err = self.protocol:ReadMessage()
    if err ~= nil then
        return nil, err
    end

    if msg:IsResponse() and msg.id ~= nil and msg.id:String() == method then
        if msg.error ~= nil then
            return nil, jsonrpc.NewError("ipc: remote error [" .. tostring(msg.error.code) .. "]: " .. msg.error.message)
        end
        return msg.result, nil
    end

    -- Unexpected message while waiting for response
    return nil, jsonrpc.NewError("ipc: unexpected message while waiting for " .. jsonrpc.goQuote(method) .. " response")
end

-- Notify sends a notification to the client (no response expected).
function SyncConn:Notify(ctx, method, params)
    return self.protocol:WriteNotification(method, params)
end
