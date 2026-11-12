local trackingvfs = require("tslua.vfs.trackingvfs")
local collections = require("tslua.collections")

-- Package trackingvfs provides a VFS wrapper that records every file path
-- accessed during compilation. This allows watch mode to know exactly which
-- files and directories the compiler depended on, including non-existent
-- paths from failed module resolution.

-- FS wraps a vfs.FS and records every path accessed via read-like operations.
-- Write operations (WriteFile, Remove, Chtimes) are not tracked since they
-- represent outputs, not dependencies.
--   inner: vfs.FS
--   seenFiles: collections.SyncSet[string]
local FS = {}
FS.__index = FS
trackingvfs.FS = FS

function trackingvfs.NewFS(inner)
    return setmetatable({ inner = inner, seenFiles = collections.NewSyncSet() }, FS)
end

function FS:ReadFile(path)
    self.seenFiles:Add(path)
    return self.inner:ReadFile(path)
end

function FS:FileExists(path)
    self.seenFiles:Add(path)
    return self.inner:FileExists(path)
end

function FS:UseCaseSensitiveFileNames() return self.inner:UseCaseSensitiveFileNames() end

function FS:WriteFile(path, data)
    return self.inner:WriteFile(path, data)
end

function FS:AppendFile(path, data)
    return self.inner:AppendFile(path, data)
end

function FS:Remove(path) return self.inner:Remove(path) end

function FS:Chtimes(path, aTime, mTime)
    return self.inner:Chtimes(path, aTime, mTime)
end

function FS:DirectoryExists(path)
    self.seenFiles:Add(path)
    return self.inner:DirectoryExists(path)
end

function FS:GetAccessibleEntries(path)
    self.seenFiles:Add(path)
    return self.inner:GetAccessibleEntries(path)
end

function FS:Stat(path)
    self.seenFiles:Add(path)
    return self.inner:Stat(path)
end

function FS:WalkDir(root, walkFn)
    self.seenFiles:Add(root)
    return self.inner:WalkDir(root, function(path, d, err)
        self.seenFiles:Add(path)
        return walkFn(path, d, err)
    end)
end

function FS:Realpath(path)
    self.seenFiles:Add(path)
    return self.inner:Realpath(path)
end
