local api = require("tslua.api")
local bundled = require("tslua.bundled")
local ipc = require("tslua.ipc")
local jsonrpc = require("tslua.jsonrpc")
local lsproto = require("tslua.lsp.lsproto")
local osvfs = require("tslua.vfs.osvfs")
local project = require("tslua.project")

-- StdioServerOptions configures the STDIO-based API server:
--   in_, out, err: stdin / stdout / stderr streams
--   cwd, defaultLibraryPath
--   pipePath: if set, listens on a named pipe (Windows) or Unix domain socket instead of using
--     in_/out for communication.
--   callbacks: which filesystem operations should be delegated to the client (e.g., "readFile",
--     "fileExists"). Empty means no callbacks.
--   async: enables JSON-RPC protocol with async connection handling. When false (default), uses
--     MessagePack protocol with sync connection.
--   collectTiming: enables per-request server processing-time measurement. When enabled, the
--     server accumulates each request's processing time into running totals and a
--     recent-request ring buffer. Response messages are left unchanged; the client folds this
--     data into its own timing snapshot on demand via getServerTiming / resetServerTiming requests.
--   runExternalCode: allows configured content mappers to execute.
--   contentMapperSpawner

-- StdioServer runs an API session over STDIO using MessagePack protocol.
-- This is the entry point for the synchronous STDIO-based API used by
-- native TypeScript tooling integration.
local StdioServer = {}
StdioServer.__index = StdioServer
api.StdioServer = StdioServer

-- NewStdioServer creates a new STDIO-based API server.
function api.NewStdioServer(options)
    if options.cwd == nil or options.cwd == "" then
        error("StdioServerOptions.Cwd is required", 0)
    end

    return setmetatable({
        options = options,
    }, StdioServer)
end

-- Run starts the server and blocks until the connection closes. Returns err.
function StdioServer:Run(ctx)
    local transport
    if (self.options.pipePath or "") ~= "" then
        local t, err = ipc.NewPipeTransport(self.options.pipePath)
        if err ~= nil then
            return jsonrpc.NewError("failed to create pipe transport: " .. jsonrpc.ErrorString(err), err)
        end
        transport = t
    else
        transport = ipc.NewStdioTransport(self.options.in_, self.options.out)
    end

    local result = table.pack(pcall(self.runWithTransport, self, ctx, transport))
    transport:Close()
    if not result[1] then
        error(result[2], 0)
    end
    return result[2]
end

function StdioServer:runWithTransport(ctx, transport)
    local fs = bundled.WrapFS(osvfs.FS())

    -- Wrap the base FS with callbackFS if callbacks are requested
    local callbackFS
    if #(self.options.callbacks or {}) > 0 then
        callbackFS = api.newCallbackFS(fs, self.options.callbacks)
        fs = callbackFS
    end

    local projectSession = project.NewSession({
        backgroundCtx = ctx,
        logger = nil, -- TODO: Add logging support
        fs = fs,
        options = project.NewSessionOptions({
            currentDirectory = self.options.cwd,
            defaultLibraryPath = self.options.defaultLibraryPath,
            positionEncoding = lsproto.PositionEncodingKind.UTF8,
            loggingEnabled = false,
            runExternalCode = self.options.runExternalCode == true,
        }),
        spawner = self.options.contentMapperSpawner,
    })

    local session = api.NewSession(projectSession, {
        useBinaryResponses = not self.options.async, -- Only msgpack uses binary responses
    })

    local ok, res = pcall(function()
        -- Accept connection from transport
        local rwc, err = transport:Accept()
        if err ~= nil then
            return jsonrpc.NewError("failed to accept connection: " .. jsonrpc.ErrorString(err), err)
        end

        -- Create protocol and connection based on async mode
        local conn
        if self.options.async then
            local protocol = ipc.NewJSONRPCProtocol(rwc)
            local asyncConn = ipc.NewAsyncConnWithProtocol(rwc, protocol, session)
            asyncConn:SetCollectTiming(self.options.collectTiming == true)
            conn = asyncConn
        else
            local protocol = api.NewMessagePackProtocol(rwc)
            local syncConn = ipc.NewSyncConn(rwc, protocol, session)
            syncConn:SetCollectTiming(self.options.collectTiming == true)
            conn = syncConn
        end

        -- If callbacks are enabled, set the connection on the FS
        if callbackFS ~= nil then
            callbackFS:SetConnection(ctx, conn)
        end

        return conn:Run(ctx)
    end)
    session:Close()
    if not ok then
        error(res, 0)
    end
    return res
end
