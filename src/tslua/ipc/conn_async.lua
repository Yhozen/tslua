local ipc = require("tslua.ipc")
local core = require("tslua.core")
local jsonrpc = require("tslua.jsonrpc")

-- AsyncConn manages bidirectional JSON-RPC communication with async request handling.
-- This is the standard implementation for LSP-style JSON-RPC protocols.
--
-- Lua has no goroutines, so the read loop runs sequentially: Run(ctx) processes messages until the
-- peer closes, handling each incoming request and notification inline (Go handles them on their own
-- goroutines). A connection whose Run loop would execute in the background in Go (the client side,
-- `go conn.Run(ctx)`) is started with RunInBackground instead; its loop then advances on demand
-- while Call waits for a response, which is the only time a client observes it. Context cancellation
-- is observed between messages (a blocking read cannot be interrupted).
local AsyncConn = {}
AsyncConn.__index = AsyncConn
ipc.AsyncConn = AsyncConn

-- NewAsyncConn creates a new async connection with the given transport and handler.
-- It uses JSONRPCProtocol (LSP-style Content-Length framing) by default.
function ipc.NewAsyncConn(rwc, handler)
    return ipc.NewAsyncConnWithProtocol(rwc, ipc.NewJSONRPCProtocol(rwc), handler)
end

-- NewAsyncConnWithProtocol creates a new async connection with a custom protocol.
function ipc.NewAsyncConnWithProtocol(rwc, protocol, handler)
    return setmetatable({
        rwc = rwc,
        protocol = protocol,
        handler = handler,
        timing = nil,
        seq = 0,
        pending = {},
        responses = {},
        terminal = nil,
        background = nil,
    }, AsyncConn)
end

-- SetCollectTiming enables or disables per-request server processing-time
-- measurement. When enabled, the connection accumulates timing that clients can
-- retrieve via a getServerTiming request.
function AsyncConn:SetCollectTiming(enabled)
    if enabled then
        self.timing = ipc.newTimingCollector()
    else
        self.timing = nil
    end
end

-- step reads and dispatches one message: the body of Run's loop. Returns (done, err) where done
-- reports that the loop ended (with err as Run's result).
function AsyncConn:step(ctx)
    local ctxErr = core.ContextErr(ctx)
    if ctxErr ~= nil then
        return true, ctxErr
    end

    local msg, err = self.protocol:ReadMessage()
    if err ~= nil then
        if jsonrpc.ErrorsIs(err, jsonrpc.EOF) then
            return true, nil
        end
        return true, err
    end

    if msg:IsResponse() then
        self:handleResponse(msg)
    elseif msg:IsRequest() then
        self:handleRequest(ctx, msg)
    elseif msg:IsNotification() then
        self:handleNotification(ctx, msg)
    end
    return false, nil
end

-- Run starts processing messages on the connection.
-- It blocks until the context is cancelled or an error occurs.
function AsyncConn:Run(ctx)
    while true do
        local done, err = self:step(ctx)
        if done then
            self:closePendingCalls(err)
            return err
        end
    end
end

-- RunInBackground stands in for `go func() { err := conn.Run(ctx); onExit(err) }()`: the read loop
-- is advanced by Call until it ends, at which point onExit (optional) runs.
function AsyncConn:RunInBackground(ctx, onExit)
    self.background = { ctx = ctx, onExit = onExit, done = false }
end

-- pumpBackground advances the background read loop by one message. Returns false once it has ended.
function AsyncConn:pumpBackground()
    local bg = self.background
    if bg == nil or bg.done then
        return false
    end
    local done, err = self:step(bg.ctx)
    if done then
        bg.done = true
        self:closePendingCalls(err)
        if bg.onExit ~= nil then
            bg.onExit(err)
        end
        return false
    end
    return true
end

-- closePendingCalls records that the read loop has exited and unblocks requests waiting for a response.
function AsyncConn:closePendingCalls(runErr)
    if self.terminal == nil then
        self.terminal = ipc.ErrConnClosed
        if runErr ~= nil then
            -- errors.Join(ErrConnClosed, runErr)
            self.terminal = jsonrpc.NewError(jsonrpc.ErrorString(self.terminal) .. "\n" .. jsonrpc.ErrorString(runErr), self.terminal, runErr)
        end
    end
    self.pending = {}
end

-- handleResponse matches a response to a pending request.
function AsyncConn:handleResponse(msg)
    local key = msg.id:Key()
    if self.pending[key] then
        self.pending[key] = nil
        self.responses[key] = msg
    end
end

-- handleRequest processes an incoming request.
function AsyncConn:handleRequest(ctx, msg)
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
        return "panic: " .. tostring(r) .. "\n" .. debug.traceback()
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
function AsyncConn:handleNotification(ctx, msg)
    self.handler:HandleNotification(ctx, msg.method, msg.params)
end

-- Call sends a request to the client and waits for a response. Returns (jsonrpc.Value, err).
function AsyncConn:Call(ctx, method, params)
    -- Create unique request ID
    self.seq = self.seq + 1
    local id = jsonrpc.NewIDString("api" .. string.format("%d", self.seq))
    local key = id:Key()

    -- Register response channel BEFORE sending request to avoid race
    if self.terminal ~= nil then
        return nil, self.terminal
    end
    self.pending[key] = true

    local function cleanup()
        self.pending[key] = nil
        self.responses[key] = nil
    end

    -- Send the request
    local err = self.protocol:WriteRequest(id, method, params)
    if err ~= nil then
        cleanup()
        return nil, err
    end

    while self.responses[key] == nil do
        local ctxErr = core.ContextErr(ctx)
        if ctxErr ~= nil then
            cleanup()
            return nil, ctxErr
        end
        if self.terminal ~= nil or not self:pumpBackground() then
            if self.responses[key] ~= nil then
                break
            end
            cleanup()
            if self.terminal ~= nil then
                return nil, self.terminal
            end
            return nil, ipc.ErrConnClosed
        end
    end
    local resp = self.responses[key]
    cleanup()
    if resp.error ~= nil then
        return nil, jsonrpc.NewError(string.format("ipc: remote error [%d]: %s", resp.error.code, resp.error.message))
    end
    return resp.result, nil
end

-- Notify sends a notification to the client (no response expected).
function AsyncConn:Notify(ctx, method, params)
    if self.terminal ~= nil then
        return self.terminal
    end
    return self.protocol:WriteNotification(method, params)
end
