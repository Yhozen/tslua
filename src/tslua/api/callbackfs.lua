local api = require("tslua.api")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local vfs = require("tslua.vfs")

-- callbackFS wraps a base filesystem and delegates certain operations
-- to the client via RPC callbacks. This allows the API client to provide
-- a virtual filesystem (e.g., in-memory files for testing).
--
-- The callbacks to enable are specified at construction time via the
-- --callbacks CLI flag. The connection is set via SetConnection after
-- the transport connection is established.
local callbackFS = {}
callbackFS.__index = callbackFS
api.callbackFS = callbackFS

-- Callback names that can be enabled
api.callbackReadFile = "readFile"
api.callbackFileExists = "fileExists"
api.callbackDirectoryExists = "directoryExists"
api.callbackGetAccessibleEntries = "getAccessibleEntries"
api.callbackRealpath = "realpath"
api.callbackWriteFile = "writeFile"

function api.isCallbackName(name)
    return name == api.callbackReadFile or
        name == api.callbackFileExists or
        name == api.callbackDirectoryExists or
        name == api.callbackGetAccessibleEntries or
        name == api.callbackRealpath or
        name == api.callbackWriteFile
end

-- newCallbackFS creates a new callbackFS wrapping the given base filesystem.
-- The callbacks slice specifies which filesystem operations should be delegated
-- to the client (e.g., "readFile", "fileExists").
function api.newCallbackFS(base, callbacks)
    local enabled = {}
    for _, cb in ipairs(callbacks) do
        if not api.isCallbackName(cb) then
            error("unknown callback name: " .. cb, 0)
        end
        enabled[cb] = true
    end
    return setmetatable({
        base = base,
        enabledCallbacks = enabled,
        conn = nil,
        ctx = nil,
    }, callbackFS)
end

-- SetConnection sets the RPC connection for callbacks.
-- This must be called after the transport connection is established
-- but before any filesystem operations that need callbacks.
function callbackFS:SetConnection(ctx, conn)
    self.ctx = ctx
    self.conn = conn
end

-- isEnabled returns true if the named callback is enabled.
function callbackFS:isEnabled(name)
    return self.enabledCallbacks[name] == true
end

-- call invokes a callback on the client and returns the raw result bytes. Returns (string, err).
function callbackFS:call(name, arg)
    if self.conn == nil then
        return nil, jsonrpc.NewError("CallbackFS: " .. name .. " called before connection set")
    end

    local result, err = self.conn:Call(self.ctx, name, arg)
    if err ~= nil then
        return nil, err
    end
    if result == nil then
        return "", nil
    end
    return result.data, nil
end

-- UseCaseSensitiveFileNames implements vfs.FS.
function callbackFS:UseCaseSensitiveFileNames()
    return self.base:UseCaseSensitiveFileNames()
end

-- ReadFile implements vfs.FS.
--
-- The readFile callback uses a wrapped response format to distinguish three states:
--   - undefined (fall back to real FS): null or empty on wire
--   - null (not found, no fallback): {"content": null}
--   - string content: {"content": "..."}
function callbackFS:ReadFile(path)
    if self:isEnabled(api.callbackReadFile) then
        local result, err = self:call(api.callbackReadFile, path)
        if err ~= nil then
            error(err, 0)
        end
        if #result > 0 and result ~= "null" then
            local wrapper
            wrapper, err = json.Unmarshal(result)
            if err ~= nil then
                error(err, 0)
            end
            if type(wrapper) ~= "table" then
                error("json: cannot unmarshal JSON into Go struct { Content *string }", 0)
            end
            if wrapper.content == nil then
                return "", false
            end
            if type(wrapper.content) ~= "string" then
                error("json: cannot unmarshal JSON into Go string", 0)
            end
            return wrapper.content, true
        end
    end
    return self.base:ReadFile(path)
end

-- FileExists implements vfs.FS.
function callbackFS:FileExists(path)
    if self:isEnabled(api.callbackFileExists) then
        local result, err = self:call(api.callbackFileExists, path)
        if err ~= nil then
            error(err, 0)
        end
        if #result > 0 and result ~= "null" then
            return result == "true"
        end
    end
    return self.base:FileExists(path)
end

-- DirectoryExists implements vfs.FS.
function callbackFS:DirectoryExists(path)
    if self:isEnabled(api.callbackDirectoryExists) then
        local result, err = self:call(api.callbackDirectoryExists, path)
        if err ~= nil then
            error(err, 0)
        end
        if #result > 0 and result ~= "null" then
            return result == "true"
        end
    end
    return self.base:DirectoryExists(path)
end

local function stringList(v)
    if v == nil then
        return nil
    end
    if type(v) ~= "table" then
        error("json: cannot unmarshal JSON into Go []string", 0)
    end
    local out = {}
    for i, s in ipairs(v) do
        if type(s) ~= "string" then
            error("json: cannot unmarshal JSON into Go string", 0)
        end
        out[i] = s
    end
    return out
end

-- GetAccessibleEntries implements vfs.FS.
function callbackFS:GetAccessibleEntries(path)
    if self:isEnabled(api.callbackGetAccessibleEntries) then
        local result, err = self:call(api.callbackGetAccessibleEntries, path)
        if err ~= nil then
            error(err, 0)
        end
        if #result > 0 then
            local rawEntries
            rawEntries, err = json.Unmarshal(result)
            if err ~= nil then
                error(err, 0)
            end
            if rawEntries ~= nil then
                return vfs.NewEntries(stringList(rawEntries.files), stringList(rawEntries.directories), nil)
            end
        end
    end
    return self.base:GetAccessibleEntries(path)
end

-- Realpath implements vfs.FS.
function callbackFS:Realpath(path)
    if self:isEnabled(api.callbackRealpath) then
        local result, err = self:call(api.callbackRealpath, path)
        if err ~= nil then
            error(err, 0)
        end
        if #result > 0 and result ~= "null" then
            local realpath
            realpath, err = json.Unmarshal(result)
            if err ~= nil then
                error(err, 0)
            end
            if type(realpath) ~= "string" then
                error("json: cannot unmarshal JSON into Go string", 0)
            end
            return realpath
        end
    end
    return self.base:Realpath(path)
end

-- WriteFile implements vfs.FS.
function callbackFS:WriteFile(path, data)
    if self:isEnabled(api.callbackWriteFile) then
        local payload = { path = path, data = data }

        local _, err = self:call(api.callbackWriteFile, api.Typed("writeFilePayload", payload))
        if err ~= nil then
            return err
        end
        return nil
    end

    return self.base:WriteFile(path, data)
end

api.defineStruct("writeFilePayload", {
    { "path", "string", "path" },
    { "data", "string", "data" },
})

-- AppendFile implements vfs.FS - always delegates to base (no callback support).
function callbackFS:AppendFile(path, data)
    return self.base:AppendFile(path, data)
end

-- Remove implements vfs.FS - always delegates to base (no callback support).
function callbackFS:Remove(path)
    return self.base:Remove(path)
end

-- Chtimes implements vfs.FS - always delegates to base (no callback support).
function callbackFS:Chtimes(path, aTime, mTime)
    return self.base:Chtimes(path, aTime, mTime)
end

-- Stat implements vfs.FS - always delegates to base (no callback support).
function callbackFS:Stat(path)
    return self.base:Stat(path)
end

-- WalkDir implements vfs.FS - always delegates to base (no callback support).
function callbackFS:WalkDir(root, walkFn)
    return self.base:WalkDir(root, walkFn)
end
