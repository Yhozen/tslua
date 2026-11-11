local bundled = require("tslua.bundled")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

local scheme = "bundled:///"
bundled.scheme = scheme

function bundled.splitPath(path)
    if string.sub(path, 1, #scheme) == scheme then
        return string.sub(path, #scheme + 1), true
    end
    return path, false
end

function bundled.libPath()
    return scheme .. "libs"
end

function bundled.IsBundled(path)
    local _, ok = bundled.splitPath(path)
    return ok
end

-- wrappedFS is implemented directly rather than going through io/fs.FS.

local wrappedFS = {}
wrappedFS.__index = wrappedFS
bundled.wrappedFS = wrappedFS

function bundled.wrapFS(fs)
    return setmetatable({ fs = fs }, wrappedFS)
end

function wrappedFS:UseCaseSensitiveFileNames()
    return self.fs:UseCaseSensitiveFileNames()
end

function wrappedFS:FileExists(path)
    local rest, ok = bundled.splitPath(path)
    if ok then
        return bundled.embeddedContents[rest] ~= nil
    end
    return self.fs:FileExists(path)
end

function wrappedFS:ReadFile(path)
    local rest, ok = bundled.splitPath(path)
    if ok then
        local contents = bundled.embeddedContents[rest]
        if contents == nil then
            return "", false
        end
        return contents, true
    end
    return self.fs:ReadFile(path)
end

function wrappedFS:DirectoryExists(path)
    local rest, ok = bundled.splitPath(path)
    if ok then
        return rest == "libs"
    end
    return self.fs:DirectoryExists(path)
end

function wrappedFS:GetAccessibleEntries(path)
    local rest, ok = bundled.splitPath(path)
    if ok then
        local result = { files = {}, directories = {}, symlinks = nil }
        if rest == "" then
            result.directories = { "libs" }
        elseif rest == "libs" then
            result.files = bundled.LibNames
        end
        return result
    end
    return self.fs:GetAccessibleEntries(path)
end

local fileInfo = {}
fileInfo.__index = fileInfo
bundled.fileInfo = fileInfo

function bundled.newFileInfo(name, mode, size)
    return setmetatable({ name = name, mode = mode or 0, size = size or 0 }, fileInfo)
end

bundled.rootEntries = {
    bundled.newFileInfo("libs", iofs.ModeDir, 0),
}

function wrappedFS:Stat(path)
    local rest, ok = bundled.splitPath(path)
    if ok then
        if rest == "" or rest == "libs" then
            return bundled.newFileInfo(rest, iofs.ModeDir, 0)
        end
        local lib = bundled.embeddedContents[rest]
        if lib ~= nil then
            local libName = rest
            if string.sub(libName, 1, 5) == "libs/" then
                libName = string.sub(libName, 6)
            end
            return bundled.newFileInfo(libName, 0, #lib)
        end
        return nil
    end
    return self.fs:Stat(path)
end

function wrappedFS:WalkDir(root, walkFn)
    local rest, ok = bundled.splitPath(root)
    if ok then
        local err = self:walkDir(rest, walkFn)
        if err ~= nil then
            if err == iofs.SkipAll then
                return nil
            end
            return err
        end
        return nil
    end
    return self.fs:WalkDir(root, walkFn)
end

function wrappedFS:walkDir(rest, walkFn)
    local entries
    if rest == "" then
        entries = bundled.rootEntries
    elseif rest == "libs" then
        entries = bundled.libsEntries()
    else
        return nil
    end

    for _, entry in ipairs(entries) do
        local name = rest .. "/" .. entry:Name()

        local err = walkFn(scheme .. name, entry, nil)
        if err ~= nil then
            if err == iofs.SkipAll then
                return iofs.SkipAll
            end
            if err == iofs.SkipDir then
                goto continue
            end
            return err
        end
        if entry:IsDir() then
            local trimmed = name
            if string.sub(trimmed, 1, 1) == "/" then
                trimmed = string.sub(trimmed, 2)
            end
            local err2 = self:walkDir(trimmed, walkFn)
            if err2 ~= nil then
                return err2
            end
        end
        ::continue::
    end

    return nil
end

function wrappedFS:Realpath(path)
    local _, ok = bundled.splitPath(path)
    if ok then
        return path
    end
    return self.fs:Realpath(path)
end

function wrappedFS:WriteFile(path, data)
    local _, ok = bundled.splitPath(path)
    if ok then
        error("cannot write to embedded file system", 0)
    end
    return self.fs:WriteFile(path, data)
end

function wrappedFS:AppendFile(path, data)
    local _, ok = bundled.splitPath(path)
    if ok then
        error("cannot write to embedded file system", 0)
    end
    return self.fs:AppendFile(path, data)
end

function wrappedFS:Remove(path)
    local _, ok = bundled.splitPath(path)
    if ok then
        error("cannot remove from embedded file system", 0)
    end
    return self.fs:Remove(path)
end

function wrappedFS:Chtimes(path, aTime, mTime)
    local _, ok = bundled.splitPath(path)
    if ok then
        error("cannot change times on embedded file system", 0)
    end
    return self.fs:Chtimes(path, aTime, mTime)
end

function fileInfo:IsDir()
    return iofs.FileMode_IsDir(self.mode)
end

function fileInfo:ModTime()
    return 0
end

function fileInfo:Mode()
    return self.mode
end

function fileInfo:Name()
    return self.name
end

function fileInfo:Size()
    return self.size
end

function fileInfo:Sys()
    return nil
end

function fileInfo:Info()
    return self, nil
end

function fileInfo:Type()
    return iofs.FileMode_Type(self.mode)
end

return bundled
