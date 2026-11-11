local wrapvfs = require("tslua.vfs.wrapvfs")

-- Replacements is a table with optional function fields UseCaseSensitiveFileNames, FileExists,
-- ReadFile, WriteFile, AppendFile, Remove, Chtimes, DirectoryExists, GetAccessibleEntries, Stat,
-- WalkDir and Realpath (Go field names, called as plain functions without the receiver).

local wrappedFS = {}
wrappedFS.__index = wrappedFS
wrapvfs.wrappedFS = wrappedFS

function wrapvfs.Wrap(fs, replacements)
    return setmetatable({
        fs = fs,
        replacements = replacements or {},
    }, wrappedFS)
end

-- UseCaseSensitiveFileNames implements vfs.FS.
function wrappedFS:UseCaseSensitiveFileNames()
    if self.replacements.UseCaseSensitiveFileNames ~= nil then
        return self.replacements.UseCaseSensitiveFileNames()
    end
    return self.fs:UseCaseSensitiveFileNames()
end

-- FileExists implements vfs.FS.
function wrappedFS:FileExists(path)
    if self.replacements.FileExists ~= nil then
        return self.replacements.FileExists(path)
    end
    return self.fs:FileExists(path)
end

-- ReadFile implements vfs.FS.
function wrappedFS:ReadFile(path)
    if self.replacements.ReadFile ~= nil then
        return self.replacements.ReadFile(path)
    end
    return self.fs:ReadFile(path)
end

-- WriteFile implements vfs.FS.
function wrappedFS:WriteFile(path, data)
    if self.replacements.WriteFile ~= nil then
        return self.replacements.WriteFile(path, data)
    end
    return self.fs:WriteFile(path, data)
end

-- AppendFile implements vfs.FS.
function wrappedFS:AppendFile(path, data)
    if self.replacements.AppendFile ~= nil then
        return self.replacements.AppendFile(path, data)
    end
    return self.fs:AppendFile(path, data)
end

-- Remove implements vfs.FS.
function wrappedFS:Remove(path)
    if self.replacements.Remove ~= nil then
        return self.replacements.Remove(path)
    end
    return self.fs:Remove(path)
end

-- Chtimes implements vfs.FS.
function wrappedFS:Chtimes(path, aTime, mTime)
    if self.replacements.Chtimes ~= nil then
        return self.replacements.Chtimes(path, aTime, mTime)
    end
    return self.fs:Chtimes(path, aTime, mTime)
end

-- DirectoryExists implements vfs.FS.
function wrappedFS:DirectoryExists(path)
    if self.replacements.DirectoryExists ~= nil then
        return self.replacements.DirectoryExists(path)
    end
    return self.fs:DirectoryExists(path)
end

-- GetAccessibleEntries implements vfs.FS.
function wrappedFS:GetAccessibleEntries(path)
    if self.replacements.GetAccessibleEntries ~= nil then
        return self.replacements.GetAccessibleEntries(path)
    end
    return self.fs:GetAccessibleEntries(path)
end

-- Stat implements vfs.FS.
function wrappedFS:Stat(path)
    if self.replacements.Stat ~= nil then
        return self.replacements.Stat(path)
    end
    return self.fs:Stat(path)
end

-- WalkDir implements vfs.FS.
function wrappedFS:WalkDir(root, walkFn)
    if self.replacements.WalkDir ~= nil then
        return self.replacements.WalkDir(root, walkFn)
    end
    return self.fs:WalkDir(root, walkFn)
end

-- Realpath implements vfs.FS.
function wrappedFS:Realpath(path)
    if self.replacements.Realpath ~= nil then
        return self.replacements.Realpath(path)
    end
    return self.fs:Realpath(path)
end

return wrapvfs
