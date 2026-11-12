local lsptestutil = require("tslua.testutil.lsptestutil")
local core = require("tslua.core")
local ipc = require("tslua.ipc")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local lsp = require("tslua.lsp")
local lsproto = require("tslua.lsp.lsproto")

-- clientTransport wires a test client to a server using real LSP
-- "Content-Length"-framed JSON streamed over an in-memory pipe, exactly like
-- communication with a real editor. This exercises the full marshal/unmarshal
-- round-trip of every protocol data structure.
--
-- Go connects the two sides with two io.Pipes and runs the server and the client's message
-- router on goroutines. Here the server runs on a coroutine that owns the server end of an
-- ipc.Pipe (ipc.GoPeer): whenever the client reads with nothing buffered, the server runs until
-- it blocks reading its own (empty) input. The message router runs on the client side while the
-- client waits for a response (SendRequest) or for the server to go idle (Drain).
function lsptestutil.newClientTransport()
    local clientEnd, serverEnd = ipc.Pipe()
    return {
        clientEnd = clientEnd,
        serverEnd = serverEnd,
        serverIn = lsp.ToReader(serverEnd), -- server reads client->server messages
        serverOut = lsp.ToWriter(serverEnd), -- server writes server->client messages
        clientIn = lsp.ToReader(clientEnd), -- client reads server->client messages
        clientOut = lsp.ToWriter(clientEnd), -- client writes client->server messages
        closeClientOut = function()
            clientEnd:Close()
        end,
        closeServerOut = function()
            serverEnd:Close()
        end,
    }
end

-- ServerRequestHandler: function(ctx, req *lsproto.RequestMessage) -> *lsproto.ResponseMessage or nil.
-- ServerNotificationHandler: function(ctx, req *lsproto.RequestMessage).

-- LSPClient provides infrastructure for communicating with an LSP server in tests.
local LSPClient = {}
LSPClient.__index = LSPClient
lsptestutil.LSPClient = LSPClient

function LSPClient:writeToServer(msg)
    return self.inputWriter:Write(msg)
end

-- NewLSPClient creates an LSPClient wrapping the given server and pipes. Returns (client, close).
function lsptestutil.NewLSPClient(t, serverOpts, onServerRequest)
    local transport = lsptestutil.newClientTransport()
    local opts = {}
    for k, v in pairs(serverOpts) do
        opts[k] = v
    end
    opts.in_ = transport.serverIn
    opts.out = transport.serverOut

    local server = lsp.NewServer(opts)

    local ctx, cancel = core.WithCancel(nil)
    local client = setmetatable({
        Server = server,
        inputWriter = transport.clientOut,
        outputReader = transport.clientIn,
        transport = transport,
        id = 0,
        ctx = ctx,
        onServerRequest = onServerRequest,
        OnServerNotification = nil,
        pendingRequests = {},
        runErr = nil,
        serverDone = false,
    }, LSPClient)

    -- Start the server "goroutine".
    ipc.GoPeer(transport.clientEnd, transport.serverEnd, function()
        local err = server:Run(ctx)
        client.runErr = err
        client.serverDone = true
        transport.closeServerOut()
    end)

    return client, function()
        cancel()
        transport.closeClientOut()
        local err = client.runErr
        if err ~= nil and not jsonrpc.ErrorsIs(err, core.Canceled) then
            return err
        end
        return nil
    end
end

-- NextID returns the next request ID.
function LSPClient:NextID()
    local id = self.id
    self.id = self.id + 1
    return id
end

-- routeOne reads one message from the server and routes it (one iteration of Go's
-- MessageRouter). Returns (ok, err); ok is false at end of input.
function LSPClient:routeOne()
    local msg, err = self.outputReader:Read()
    if err ~= nil then
        if jsonrpc.ErrorsIs(err, jsonrpc.EOF) then
            return false, nil
        end
        return false, jsonrpc.NewError("failed to read message: " .. jsonrpc.ErrorString(err), err)
    end

    -- Validate message can be marshaled
    local _, merr = json.Marshal(msg)
    if merr ~= nil then
        return false, jsonrpc.NewError("failed to encode message as JSON: " .. jsonrpc.ErrorString(merr), merr)
    end

    if msg.kind == jsonrpc.MessageKind.Response then
        self:handleResponse(msg:AsResponse())
    elseif msg.kind == jsonrpc.MessageKind.Request then
        err = self:handleServerRequest(self.ctx, msg:AsRequest())
        if err ~= nil then
            return false, err
        end
    elseif msg.kind == jsonrpc.MessageKind.Notification then
        if self.OnServerNotification ~= nil then
            self.OnServerNotification(self.ctx, msg:AsRequest())
        end
    end
    return true, nil
end

-- MessageRouter routes incoming messages from the server until it closes its output.
function LSPClient:MessageRouter(ctx)
    while true do
        local ok, err = self:routeOne()
        if not ok then
            return err
        end
    end
end

-- handleResponse routes a response message to the waiting request.
function LSPClient:handleResponse(resp)
    if resp.id == nil then
        return
    end
    local slot = self.pendingRequests[resp.id:Key()]
    if slot ~= nil then
        self.pendingRequests[resp.id:Key()] = nil
        slot.resp = resp
    end
end

-- handleServerRequest handles requests initiated by the server (e.g., workspace/configuration).
function LSPClient:handleServerRequest(ctx, req)
    local response

    if self.onServerRequest ~= nil then
        response = self.onServerRequest(ctx, req)
    end

    if response == nil then
        -- Default: unknown server request
        response = lsproto.NewResponseMessage(req.id, nil, jsonrpc.NewResponseError(lsproto.ErrorCode.MethodNotFound, "Unknown method: " .. req.method))
    end

    -- Send response back to server
    if core.ContextErr(ctx) ~= nil then
        return nil
    end

    local err = self:writeToServer(response:Message())
    if err ~= nil then
        if core.ContextErr(ctx) ~= nil then
            return nil
        end
        return jsonrpc.NewError("failed to write server request response: " .. jsonrpc.ErrorString(err), err)
    end
    return nil
end

-- WriteMsg validates and sends a message to the server.
-- This is an untyped low-level method; prefer SendRequest and SendNotification for typed interactions.
function LSPClient:WriteMsg(t, msg)
    local _, merr = json.Marshal(msg)
    if merr ~= nil then
        error("failed to encode message as JSON: " .. jsonrpc.ErrorString(merr), 0)
    end
    local err = self:writeToServer(msg)
    if err ~= nil then
        error("failed to write message: " .. jsonrpc.ErrorString(err), 0)
    end
end

-- SendRequest sends a typed request and waits for the response. Returns (msg, result, ok).
function lsptestutil.SendRequest(t, c, info, params)
    local id = c:NextID()
    local reqID = lsproto.NewID({ integer = id })
    local req = info:NewRequestMessage(reqID, params)

    local resp, ok = c:SendRequestWorker(t, req, reqID)
    if not ok then
        return nil, lsproto.Zero(info.resultType), false
    end
    -- The result arrives as a raw json.Value; decode it into Resp.
    local result, err = info:UnmarshalResult(resp.result)
    return resp:Message(), result, err == nil
end

-- SendRequestAsync sends a typed request and returns a waiter for its response.
function lsptestutil.SendRequestAsync(t, c, info, params)
    local id = c:NextID()
    local reqID = lsproto.NewID({ integer = id })
    local req = info:NewRequestMessage(reqID, params)

    local slot = c:startRequestWorker(t, req, reqID)
    return function()
        local resp, ok = c:waitForResponse(t, reqID, slot)
        if not ok then
            return nil, lsproto.Zero(info.resultType), false
        end
        local result, err = info:UnmarshalResult(resp.result)
        return resp:Message(), result, err == nil
    end
end

-- This is an untyped version of SendRequest. Prefer to use SendRequest when possible.
-- Returns (resp, ok).
function LSPClient:SendRequestWorker(t, req, reqID)
    local slot = self:startRequestWorker(t, req, reqID)
    return self:waitForResponse(t, reqID, slot)
end

function LSPClient:startRequestWorker(t, req, reqID)
    local slot = { resp = nil }
    self.pendingRequests[reqID:Key()] = slot
    self:WriteMsg(t, req:Message())
    return slot
end

-- Returns (resp, ok). Runs the server and routes its messages until the response arrives.
function LSPClient:waitForResponse(t, reqID, slot)
    while slot.resp == nil do
        local ok, err = self:routeOne()
        if err ~= nil then
            error(jsonrpc.ErrorString(err), 0)
        end
        if not ok then
            self.pendingRequests[reqID:Key()] = nil
            return nil, false
        end
    end
    return slot.resp, true
end

-- SendNotification sends a typed notification.
function lsptestutil.SendNotification(t, c, info, params)
    local notification = info:NewNotificationMessage(params)
    c:WriteMsg(t, notification:Message())
end

-- Drain (Lua-only) runs the server until it is idle — blocked reading input with nothing left to
-- route — routing its messages; it stands in for waiting on the goroutines (e.g. InitComplete).
function LSPClient:Drain()
    local clientEnd = self.transport.clientEnd
    while true do
        while clientEnd.buf ~= "" do
            local ok, err = self:routeOne()
            if err ~= nil then
                error(jsonrpc.ErrorString(err), 0)
            end
            if not ok then
                return
            end
        end
        if self.serverDone or not clientEnd:resumePeer() then
            return
        end
        if clientEnd.buf == "" then
            -- The server consumed its input without writing anything: it is idle.
            return
        end
    end
end

function LSPClient:SetCompilerOptionsForInferredProjects(options)
    self.Server:SetCompilerOptionsForInferredProjects(self.ctx, options)
end
