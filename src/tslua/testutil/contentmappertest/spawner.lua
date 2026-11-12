local contentmappertest = require("tslua.testutil.contentmappertest")
local ipc = require("tslua.ipc")

-- Serve drives the transforming mapper over the connection until it closes.
function contentmappertest.Serve(ctx, rwc)
    return ipc.NewAsyncConn(rwc, contentmappertest.newStaticProjectHandler(contentmappertest.NewHandler())):Run(ctx)
end

local spawner = {}
spawner.__index = spawner
contentmappertest.spawner = spawner

-- NewSpawner returns an in-process spawner for the test mapper implementations.
function contentmappertest.NewSpawner()
    return setmetatable({ lifecycle = nil }, spawner)
end

-- NewSpawnerWithProjectLifecycle returns an in-process spawner that records project protocol calls.
function contentmappertest.NewSpawnerWithProjectLifecycle(lifecycle)
    return setmetatable({ lifecycle = lifecycle }, spawner)
end

-- Spawn serves the selected handler on a coroutine over an in-memory pipe (Go: net.Pipe plus a
-- goroutine running the server connection). Returns (rwc, err).
function spawner:Spawn(command, dir, stderr)
    local handler, err = contentmappertest.handlerForMapper(command, self.lifecycle)
    if err ~= nil then
        return nil, err
    end
    if command[1] ~= contentmappertest.DynamicVerbatimMapper then
        handler = contentmappertest.newStaticProjectHandler(handler)
    end
    local client, server = ipc.Pipe()
    ipc.GoPeer(client, server, function()
        ipc.NewAsyncConn(server, handler):Run(nil)
    end)
    return client, nil
end
