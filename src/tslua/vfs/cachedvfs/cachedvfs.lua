local cachedvfs = require("tslua.vfs.cachedvfs")

-- collections.SyncMap caches -> plain tables. A stored nil (Stat of a missing path) is
-- represented by the nilValue sentinel so that it is still a cache hit.
local nilValue = {}

local FS = {}
FS.__index = FS
cachedvfs.FS = FS

local function load(cache, key)
    local v = cache[key]
    if v == nil then
        return nil, false
    end
    if v == nilValue then
        return nil, true
    end
    return v, true
end

local function store(cache, key, value)
    if value == nil then
        cache[key] = nilValue
    else
        cache[key] = value
    end
end

function cachedvfs.From(fs)
    local fsys = setmetatable({
        fs = fs,
        enabled = true,
        directoryExistsCache = {},
        fileExistsCache = {},
        getAccessibleEntriesCache = {},
        realpathCache = {},
        statCache = {},
    }, FS)
    return fsys
end

function FS:DisableAndClearCache()
    if self.enabled then
        self.enabled = false
        self:ClearCache()
    end
end

function FS:Enable()
    self.enabled = true
end

function FS:ClearCache()
    self.directoryExistsCache = {}
    self.fileExistsCache = {}
    self.getAccessibleEntriesCache = {}
    self.realpathCache = {}
    self.statCache = {}
end

function FS:DirectoryExists(path)
    if self.enabled then
        local ret, ok = load(self.directoryExistsCache, path)
        if ok then
            return ret
        end
    end

    local ret = self.fs:DirectoryExists(path)

    if self.enabled then
        store(self.directoryExistsCache, path, ret)
    end

    return ret
end

function FS:FileExists(path)
    if self.enabled then
        local ret, ok = load(self.fileExistsCache, path)
        if ok then
            return ret
        end
    end

    local ret = self.fs:FileExists(path)

    if self.enabled then
        store(self.fileExistsCache, path, ret)
    end

    return ret
end

function FS:GetAccessibleEntries(path)
    if self.enabled then
        local ret, ok = load(self.getAccessibleEntriesCache, path)
        if ok then
            return ret
        end
    end

    local ret = self.fs:GetAccessibleEntries(path)

    if self.enabled then
        store(self.getAccessibleEntriesCache, path, ret)
    end

    return ret
end

function FS:ReadFile(path)
    return self.fs:ReadFile(path)
end

function FS:Realpath(path)
    if self.enabled then
        local ret, ok = load(self.realpathCache, path)
        if ok then
            return ret
        end
    end

    local ret = self.fs:Realpath(path)

    if self.enabled then
        store(self.realpathCache, path, ret)
    end

    return ret
end

function FS:Remove(path)
    return self.fs:Remove(path)
end

function FS:Chtimes(path, aTime, mTime)
    return self.fs:Chtimes(path, aTime, mTime)
end

function FS:Stat(path)
    if self.enabled then
        local ret, ok = load(self.statCache, path)
        if ok then
            return ret
        end
    end

    local ret = self.fs:Stat(path)

    if self.enabled then
        store(self.statCache, path, ret)
    end

    return ret
end

function FS:UseCaseSensitiveFileNames()
    return self.fs:UseCaseSensitiveFileNames()
end

function FS:WalkDir(root, walkFn)
    return self.fs:WalkDir(root, walkFn)
end

function FS:WriteFile(path, data)
    return self.fs:WriteFile(path, data)
end

function FS:AppendFile(path, data)
    return self.fs:AppendFile(path, data)
end

return cachedvfs
