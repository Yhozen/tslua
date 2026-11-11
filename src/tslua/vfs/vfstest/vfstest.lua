local vfstest = require("tslua.vfs.vfstest")
local iovfs = require("tslua.vfs.iovfs")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs
local fstest = iofs.fstest

-- MapFS: m is a testing/fstest MapFS (vfs.iofs.fstest) whose keys are canonical paths.
local MapFS = {}
MapFS.__index = MapFS
vfstest.MapFS = MapFS

-- Clock interface: Now() -> time (number), SinceStart() -> duration (number).
local clockImpl = {}
clockImpl.__index = clockImpl

function clockImpl:Now()
    return os.time()
end

function clockImpl:SinceStart()
    return os.time() - self.start
end

local function newClockImpl()
    return setmetatable({ start = os.time() }, clockImpl)
end

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function cutPrefix(s, prefix)
    if hasPrefix(s, prefix) then
        return string.sub(s, #prefix + 1), true
    end
    return s, false
end

local function strcmp(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- Distinguishes a MapFile ({data=, mode=, ...}) from string file contents.
local function isMapFile(f)
    return type(f) == "table" and f.data ~= nil
end

-- FromMap creates a new vfs.FS from a map of paths to file contents.
-- Those file contents may be strings or fstest MapFiles ({ data = ..., mode = ... }).
--
-- The paths must be normalized absolute paths according to the tspath package,
-- without trailing directory separators.
-- The paths must be all POSIX-style or all Windows-style, but not both.
function vfstest.FromMap(m, useCaseSensitiveFileNames)
    return vfstest.FromMapWithClock(m, useCaseSensitiveFileNames, newClockImpl())
end

-- FromMapWithClock creates a new vfs.FS from a map of paths to file contents.
-- Those file contents may be strings or fstest MapFiles.
--
-- The paths must be normalized absolute paths according to the tspath package,
-- without trailing directory separators.
-- The paths must be all POSIX-style or all Windows-style, but not both.
function vfstest.FromMapWithClock(m, useCaseSensitiveFileNames, clock)
    local posix = false
    local windows = false

    local function checkPath(p)
        if not tspath.IsRootedDiskPath(p) then
            error(string.format("non-rooted path %q", p), 0)
        end

        local normal = tspath.RemoveTrailingDirectorySeparator(tspath.NormalizePath(p))
        if normal ~= p then
            error(string.format("non-normalized path %q", p), 0)
        end

        if hasPrefix(p, "/") then
            posix = true
        else
            windows = true
        end
    end

    local mfs = {}
    -- Sorted creation to ensure times are always guaranteed to be in order.
    local keys = {}
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return vfstest.comparePathsByParts(a, b) < 0
    end)
    for _, p in ipairs(keys) do
        local f = m[p]
        checkPath(p)

        local file
        if type(f) == "string" then
            file = fstest.NewMapFile({ data = f, modTime = clock:Now() })
        elseif isMapFile(f) then
            file = fstest.CopyMapFile(f)
            file.modTime = clock:Now()
        else
            error(string.format("invalid file type %s", type(f)), 0)
        end

        if file.mode & iofs.ModeSymlink ~= 0 then
            local target = file.data
            checkPath(target)

            target = cutPrefix(target, "/")
            local fileCopy = fstest.CopyMapFile(file)
            fileCopy.data = target
            file = fileCopy
        end

        p = cutPrefix(p, "/")
        mfs[p] = file
    end

    if posix and windows then
        error("mixed posix and windows paths", 0)
    end

    return iovfs.From(vfstest.convertMapFS(mfs, useCaseSensitiveFileNames, clock), useCaseSensitiveFileNames)
end

function vfstest.convertMapFS(input, useCaseSensitiveFileNames, clock)
    if clock == nil then
        clock = newClockImpl()
    end
    local m = setmetatable({
        m = fstest.NewMapFS({}),
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
        symlinks = nil,
        clock = clock,
    }, MapFS)

    -- Verify that the input is well-formed.
    local canonicalPaths = {}
    for path in pairs(input) do
        local canonical = m:getCanonicalPath(path)
        local other = canonicalPaths[canonical]
        if other ~= nil then
            -- Ensure consistent panic messages
            local a, b = path, other
            if b < a then
                a, b = b, a
            end
            error(string.format("duplicate path: %q and %q have the same canonical path", a, b), 0)
        end
        canonicalPaths[canonical] = path
    end

    -- Sort the input by depth and path so we ensure parent dirs are created
    -- before their children, if explicitly specified by the input.
    local inputKeys = {}
    for k in pairs(input) do
        inputKeys[#inputKeys + 1] = k
    end
    table.sort(inputKeys, function(a, b)
        return vfstest.comparePathsByParts(a, b) < 0
    end)

    for _, p in ipairs(inputKeys) do
        local file = input[p]

        -- Create all missing intermediate directories so we can attach the realpath to each of them.
        -- fstest.MapFS doesn't require this as it synthesizes directories on the fly, but it's a lot
        -- harder to reapply a realpath onto those when we're deep in some FileInfo method.
        local dir = vfstest.dirName(p)
        if dir ~= "" then
            local err = m:mkdirAll(dir, 511)
            if err ~= nil then
                error(string.format("failed to create intermediate directories for %q: %s", p, err:Error()), 0)
            end
        end
        m:setEntry(p, m:getCanonicalPath(p), fstest.CopyMapFile(file))
    end

    return m
end

function vfstest.comparePathsByParts(a, b)
    while true do
        local ai = string.find(a, "/", 1, true)
        local bi = string.find(b, "/", 1, true)

        if ai == nil or bi == nil then
            return strcmp(a, b)
        end

        local r = strcmp(string.sub(a, 1, ai - 1), string.sub(b, 1, bi - 1))
        if r ~= 0 then
            return r
        end

        a, b = string.sub(a, ai + 1), string.sub(b, bi + 1)
    end
end

function MapFS:getCanonicalPath(p)
    return tspath.GetCanonicalFileName(p, self.useCaseSensitiveFileNames)
end

function MapFS:open(p)
    return self.m:Open(p)
end

function MapFS:remove(path)
    local canonical = self:getCanonicalPath(path)
    local canonicalString = canonical
    local files = self.m.files
    local fileInfo = files[canonicalString]
    if fileInfo == nil then
        -- file does not exist
        return nil
    end
    files[canonicalString] = nil
    if self.symlinks ~= nil then
        self.symlinks[canonical] = nil
    end

    if iofs.FileMode_IsDir(fileInfo.mode) then
        canonicalString = canonicalString .. "/"
        local toDelete = {}
        for p in pairs(files) do
            if hasPrefix(p, canonicalString) then
                toDelete[#toDelete + 1] = p
            end
        end
        for _, p in ipairs(toDelete) do
            files[p] = nil
            if self.symlinks ~= nil then
                self.symlinks[p] = nil
            end
        end
    end
    return nil
end

function vfstest.Symlink(target)
    return fstest.NewMapFile({ data = target, mode = iofs.ModeSymlink })
end

function MapFS:getFollowingSymlinks(p)
    return self:getFollowingSymlinksWorker(p, "", "")
end

local brokenSymlinkError = {}
brokenSymlinkError.__index = brokenSymlinkError
brokenSymlinkError.__tostring = function(e)
    return e:Error()
end

function brokenSymlinkError:Error()
    return string.format("broken symlink %q -> %q", self.from, self.to)
end

function vfstest.isBrokenSymlinkError(err)
    return getmetatable(err) == brokenSymlinkError
end

function MapFS:getFollowingSymlinksWorker(p, symlinkFrom, symlinkTo)
    local file = self.m.files[p]
    if file ~= nil and file.mode & iofs.ModeSymlink == 0 then
        return file, p, nil
    end

    if self.symlinks ~= nil then
        local target = self.symlinks[p]
        if target ~= nil then
            return self:getFollowingSymlinksWorker(target, p, target)
        end

        -- This could be a path underneath a symlinked directory.
        -- (Go iterates the map in random order; there is at most one matching prefix in practice.)
        local others = {}
        for other in pairs(self.symlinks) do
            others[#others + 1] = other
        end
        table.sort(others)
        for _, other in ipairs(others) do
            if #other < #p and string.sub(p, 1, #other) == other and string.byte(p, #other + 1) == 47 then
                local target2 = self.symlinks[other]
                return self:getFollowingSymlinksWorker(target2 .. string.sub(p, #other + 1), other, target2)
            end
        end
    end

    local err = iofs.ErrNotExist
    if symlinkFrom ~= "" then
        err = setmetatable({ from = symlinkFrom, to = symlinkTo }, brokenSymlinkError)
    end
    return nil, p, err
end

function MapFS:set(p, file)
    self.m.files[p] = file
end

function MapFS:setEntry(realpath, canonical, file)
    if realpath == "" or canonical == "" then
        error("empty path", 0)
    end

    file.sys = {
        original = file.sys,
        realpath = realpath,
        isVfstestSys = true,
    }
    self:set(canonical, file)

    if file.mode & iofs.ModeSymlink ~= 0 then
        if self.symlinks == nil then
            self.symlinks = {}
        end
        self.symlinks[canonical] = self:getCanonicalPath(file.data)
    end
end

function vfstest.splitPath(s, offset)
    local idx = string.find(s, "/", offset + 1, true)
    if idx == nil then
        return s, ""
    end
    return string.sub(s, 1, idx - 1), string.sub(s, idx + 1)
end

function vfstest.dirName(p)
    local dir = string.match(p, "^(.*/)") or ""
    if string.sub(dir, -1) == "/" then
        dir = string.sub(dir, 1, -2)
    end
    return dir
end

function vfstest.baseName(p)
    return string.match(p, "[^/]*$")
end

function MapFS:mkdirAll(p, perm)
    if p == "" then
        error("empty path", 0)
    end

    -- Fast path; already exists.
    do
        local other, _, err = self:getFollowingSymlinks(self:getCanonicalPath(p))
        if err == nil then
            if not iofs.FileMode_IsDir(other.mode) then
                return iofs.NewError(string.format("mkdir %q: path exists but is not a directory", p))
            end
            return nil
        end
    end

    local toCreate = {}
    local offset = 0
    while true do
        local dir, rest = vfstest.splitPath(p, offset)
        local canonical = self:getCanonicalPath(dir)
        local other, otherPath, err = self:getFollowingSymlinks(canonical)
        if err ~= nil then
            if not iofs.Is(err, iofs.ErrNotExist) then
                return err
            end
            toCreate[#toCreate + 1] = dir
        else
            if not iofs.FileMode_IsDir(other.mode) then
                return iofs.NewError(string.format("mkdir %q: path exists but is not a directory", otherPath))
            end
            if canonical ~= otherPath then
                -- We have a symlinked parent, reset and start again.
                p = other.sys.realpath .. "/" .. rest
                toCreate = {}
                offset = 0
                goto continue
            end
        end
        if rest == "" then
            break
        end
        offset = #dir + 1
        ::continue::
    end

    for _, dir in ipairs(toCreate) do
        self:setEntry(dir, self:getCanonicalPath(dir), fstest.NewMapFile({
            mode = iofs.ModeDir | (perm & ~vfstest.umask),
            modTime = self.clock:Now(),
        }))
    end

    return nil
end

-- fileInfo wraps an fs.FileInfo, replacing Name() and Sys().
local fileInfo = {}
fileInfo.__index = fileInfo

function fileInfo:Name() return vfstest.baseName(self.realpath) end
function fileInfo:Sys() return self.sys end
function fileInfo:Size() return self.fileInfo:Size() end
function fileInfo:Mode() return self.fileInfo:Mode() end
function fileInfo:ModTime() return self.fileInfo:ModTime() end
function fileInfo:IsDir() return self.fileInfo:IsDir() end
-- fs.FileInfoToDirEntry methods, so a fileInfo can be returned from ReadDir directly.
function fileInfo:Type() return iofs.FileMode_Type(self.fileInfo:Mode()) end
function fileInfo:Info() return self, nil end

local file = {}
file.__index = file

function file:Stat() return self.fileInfo, nil end
function file:ReadAll() return self.file:ReadAll() end
function file:Close() return self.file:Close() end

local readDirFile = {}
readDirFile.__index = readDirFile

function readDirFile:Stat() return self.fileInfo, nil end
function readDirFile:ReadAll() return self.file:ReadAll() end
function readDirFile:Close() return self.file:Close() end

function readDirFile:ReadDir(n)
    local list, err = self.file:ReadDir(n)
    if err ~= nil then
        return nil, err
    end

    local entries = {}
    for i, entry in ipairs(list) do
        local info = vfstest.must(entry:Info())
        local newInfo, ok = vfstest.convertInfo(info)
        if not ok then
            error(string.format("unexpected synthesized dir: %q", info:Name()), 0)
        end
        entries[i] = newInfo
    end

    return entries, nil
end

function MapFS:Open(name)
    local _, cp = self:getFollowingSymlinks(self:getCanonicalPath(name))
    local f, err = self:open(cp)
    if err ~= nil then
        return nil, err
    end

    local info = vfstest.must(f:Stat())

    local newInfo, ok = vfstest.convertInfo(info)
    if not ok then
        -- This is a synthesized dir.
        if name ~= "." then
            error(string.format("unexpected synthesized dir: %q", name), 0)
        end

        return setmetatable({
            file = f,
            fileInfo = setmetatable({
                fileInfo = info,
                sys = info:Sys(),
                realpath = ".",
            }, fileInfo),
        }, readDirFile), nil
    end

    if f.ReadDir ~= nil then
        return setmetatable({
            file = f,
            fileInfo = newInfo,
        }, readDirFile), nil
    end

    return setmetatable({
        file = f,
        fileInfo = newInfo,
    }, file), nil
end

function MapFS:Realpath(name)
    local f, _, err = self:getFollowingSymlinks(self:getCanonicalPath(name))
    if err ~= nil then
        return "", err
    end
    return f.sys.realpath, nil
end

function vfstest.convertInfo(info)
    local sys = info:Sys()
    if type(sys) ~= "table" or not sys.isVfstestSys then
        return nil, false
    end
    return setmetatable({
        fileInfo = info,
        sys = sys.original,
        realpath = sys.realpath,
    }, fileInfo), true
end

vfstest.umask = 18 -- 0o022

function MapFS:MkdirAll(path, perm)
    return self:mkdirAll(path, perm)
end

function MapFS:AddSymlink(path, target)
    local canonical = self:getCanonicalPath(path)
    self:setEntry(path, canonical, fstest.NewMapFile({
        data = target,
        mode = iofs.ModeSymlink,
    }))
end

function MapFS:WriteFile(path, data, perm)
    local parent = vfstest.dirName(path)
    if parent ~= "" then
        local canonical = self:getCanonicalPath(parent)
        local parentFile, _, err = self:getFollowingSymlinks(canonical)
        if err ~= nil then
            return iofs.NewError(string.format("write %q: %s", path, tostring(err:Error())), err)
        end
        if not iofs.FileMode_IsDir(parentFile.mode) then
            return iofs.NewError(string.format("write %q: parent path exists but is not a directory", path))
        end
    end

    local f, cp, err = self:getFollowingSymlinks(self:getCanonicalPath(path))
    if err ~= nil then
        if not iofs.Is(err, iofs.ErrNotExist) and not vfstest.isBrokenSymlinkError(err) then
            -- No other errors are possible.
            error(err, 0)
        end
    else
        if not iofs.FileMode_IsRegular(f.mode) then
            return iofs.NewError(string.format("write %q: path exists but is not a regular file", path))
        end
    end

    self:setEntry(path, cp, fstest.NewMapFile({
        data = data,
        modTime = self.clock:Now(),
        mode = perm & ~vfstest.umask,
    }))

    return nil
end

function MapFS:AppendFile(path, data, perm)
    local parent = vfstest.dirName(path)
    if parent ~= "" then
        local canonical = self:getCanonicalPath(parent)
        local parentFile, _, err = self:getFollowingSymlinks(canonical)
        if err ~= nil then
            return iofs.NewError(string.format("append %q: %s", path, tostring(err:Error())), err)
        end
        if not iofs.FileMode_IsDir(parentFile.mode) then
            return iofs.NewError(string.format("append %q: parent path exists but is not a directory", path))
        end
    end

    local existing = ""
    local existingMode = 0
    local f, cp, err = self:getFollowingSymlinks(self:getCanonicalPath(path))
    if err ~= nil then
        if not iofs.Is(err, iofs.ErrNotExist) and not vfstest.isBrokenSymlinkError(err) then
            -- No other errors are possible.
            error(err, 0)
        end
    else
        if not iofs.FileMode_IsRegular(f.mode) then
            return iofs.NewError(string.format("append %q: path exists but is not a regular file", path))
        end
        existing = f.data
        existingMode = f.mode
    end

    local combined = existing .. data

    local mode = existingMode
    if mode == 0 then
        mode = perm & ~vfstest.umask
    end

    self:setEntry(path, cp, fstest.NewMapFile({
        data = combined,
        modTime = self.clock:Now(),
        mode = mode,
    }))

    return nil
end

function MapFS:Remove(path)
    return self:remove(path)
end

function MapFS:Chtimes(path, aTime, mTime)
    local canonical = self:getCanonicalPath(path)
    local fi = self.m.files[canonical]
    if fi == nil then
        -- file does not exist
        return iofs.ErrNotExist
    end
    fi.modTime = mTime
    return nil
end

function MapFS:GetTargetOfSymlink(path)
    path = cutPrefix(path, "/")
    local canonical = self:getCanonicalPath(path)
    local fi = self.m.files[canonical]
    if fi ~= nil then
        if fi.mode & iofs.ModeSymlink ~= 0 then
            return "/" .. fi.data, true
        end
    end
    return "", false
end

function MapFS:GetModTime(path)
    path = cutPrefix(path, "/")
    local canonical = self:getCanonicalPath(path)
    local fi = self.m.files[canonical]
    if fi ~= nil then
        return fi.modTime
    end
    return 0
end

-- Entries returns a Lua iterator over (path, MapFile), sorted by path parts.
function MapFS:Entries()
    local inputKeys = {}
    for k in pairs(self.m.files) do
        inputKeys[#inputKeys + 1] = k
    end
    table.sort(inputKeys, function(a, b)
        return vfstest.comparePathsByParts(a, b) < 0
    end)

    local i = 0
    return function()
        i = i + 1
        local p = inputKeys[i]
        if p == nil then
            return nil
        end
        local f = self.m.files[p]
        local path = f.sys.realpath
        if not tspath.PathIsAbsolute(path) then
            path = "/" .. path
        end
        return path, f
    end
end

function MapFS:GetFileInfo(path)
    path = cutPrefix(path, "/")
    local canonical = self:getCanonicalPath(path)
    return self.m.files[canonical]
end

function vfstest.must(v, err)
    if err ~= nil then
        error(err, 0)
    end
    return v
end

return vfstest
