local iovfs = require("tslua.vfs.iovfs")
local internal = require("tslua.vfs.internal")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

-- RealpathFS is an fs.FS that also has Realpath(path) -> string, err.
-- WritableFS is an fs.FS that also has WriteFile(path, data, perm), AppendFile(path, data, perm),
-- MkdirAll(path, perm), Remove(path) and Chtimes(path, aTime, mTime), all returning err.
-- FsWithSys is a vfs.FS that also has FSys() -> fs.FS.

local function cutPrefixSlash(path)
    if string.sub(path, 1, 1) == "/" then
        return string.sub(path, 2), true
    end
    return path, false
end

-- From creates a new FS from an fs.FS.
--
-- For paths like `c:/foo/bar`, fsys will be used as though it's rooted at `/` and the path is `/c:/foo/bar`.
--
-- If the provided fs.FS implements RealpathFS, it will be used to implement the Realpath method.
-- If the provided fs.FS implements WritableFS, it will be used to implement the WriteFile method.
--
-- From does not actually handle case-insensitivity; ensure the passed in fs.FS
-- respects case-insensitive file names if needed. Consider using vfstest.FromMap for testing.
function iovfs.From(fsys, useCaseSensitiveFileNames)
    local realpath
    if fsys.Realpath ~= nil then
        realpath = function(path)
            local rest, hadSlash = cutPrefixSlash(path)
            local rp, err = fsys:Realpath(rest)
            if err ~= nil then
                return "", err
            end
            if hadSlash then
                return "/" .. rp, nil
            end
            return rp, nil
        end
    else
        realpath = function(path)
            return path, nil
        end
    end

    local writeFile, appendFile, mkdirAll, remove, chtimes
    if fsys.WriteFile ~= nil and fsys.AppendFile ~= nil and fsys.MkdirAll ~= nil and fsys.Remove ~= nil and fsys.Chtimes ~= nil then
        writeFile = function(path, content)
            local rest = cutPrefixSlash(path)
            return fsys:WriteFile(rest, content, 438) -- 0o666
        end
        appendFile = function(path, content)
            local rest = cutPrefixSlash(path)
            return fsys:AppendFile(rest, content, 438) -- 0o666
        end
        mkdirAll = function(path)
            local rest = cutPrefixSlash(path)
            return fsys:MkdirAll(rest, 511) -- 0o777
        end
        remove = function(path)
            local rest = cutPrefixSlash(path)
            return fsys:Remove(rest)
        end
        chtimes = function(path, aTime, mTime)
            local rest = cutPrefixSlash(path)
            return fsys:Chtimes(rest, aTime, mTime)
        end
    else
        writeFile = function()
            error("writeFile not supported", 0)
        end
        appendFile = function()
            error("appendFile not supported", 0)
        end
        mkdirAll = function()
            error("mkdirAll not supported", 0)
        end
        remove = function()
            error("remove not supported", 0)
        end
        chtimes = function()
            error("chtimes not supported", 0)
        end
    end

    return setmetatable({
        common = internal.NewCommon(function(root)
            if root == "/" then
                return fsys
            end

            local p = tspath.RemoveTrailingDirectorySeparator(root)
            local sub, err = iofs.Sub(fsys, p)
            if err ~= nil then
                if tspath.IsUrl(root) then
                    return nil
                end
                error(string.format("vfs: failed to create sub file system for %q: %s", p, err:Error()), 0)
            end
            return sub
        end, nil),
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
        realpath = realpath,
        writeFile = writeFile,
        appendFile = appendFile,
        mkdirAll = mkdirAll,
        remove = remove,
        chtimes = chtimes,
        fsys = fsys,
    }, iovfs.ioFS)
end

local ioFS = {}
ioFS.__index = ioFS
iovfs.ioFS = ioFS

function ioFS:UseCaseSensitiveFileNames()
    return self.useCaseSensitiveFileNames
end

function ioFS:DirectoryExists(path)
    return self.common:DirectoryExists(path)
end

function ioFS:FileExists(path)
    return self.common:FileExists(path)
end

function ioFS:GetAccessibleEntries(path)
    return self.common:GetAccessibleEntries(path)
end

function ioFS:Stat(path)
    local _ = internal.RootLength(path) -- Assert path is rooted
    return self.common:Stat(path)
end

function ioFS:ReadFile(path)
    return self.common:ReadFile(path)
end

function ioFS:WalkDir(root, walkFn)
    return self.common:WalkDir(root, walkFn)
end

function ioFS:Remove(path)
    local _ = internal.RootLength(path) -- Assert path is rooted
    return self.remove(path)
end

function ioFS:Chtimes(path, aTime, mTime)
    local _ = internal.RootLength(path) -- Assert path is rooted
    return self.chtimes(path, aTime, mTime)
end

function ioFS:Realpath(path)
    local root, rest = internal.SplitPath(path)
    -- splitPath normalizes the path into parts (e.g. "c:/foo/bar" -> "c:/", "foo/bar")
    -- Put them back together to call realpath.
    local realpath, err = self.realpath(root .. rest)
    if err ~= nil then
        return path
    end
    return realpath
end

function ioFS:writeFileEnsuringDir(path, content, write)
    local _ = internal.RootLength(path) -- Assert path is rooted
    if write(path, content) == nil then
        return nil
    end
    local err = self.mkdirAll(tspath.GetDirectoryPath(tspath.NormalizePath(path)))
    if err ~= nil then
        return err
    end
    return write(path, content)
end

function ioFS:WriteFile(path, content)
    return self:writeFileEnsuringDir(path, content, self.writeFile)
end

function ioFS:AppendFile(path, content)
    return self:writeFileEnsuringDir(path, content, self.appendFile)
end

function ioFS:FSys()
    return self.fsys
end

return iovfs
