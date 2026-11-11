-- Lua-only support code (no Go counterpart file): the parts of the Go standard library the vfs
-- packages are built on — io/fs (FS, File, FileInfo, DirEntry, FileMode, Stat, ReadFile, ReadDir,
-- WalkDir, Sub, ValidPath, the sentinel errors), testing/fstest.MapFS and errors.Is.
--
-- Contracts (Go -> Lua):
--   * error values are nil or tables with an Error() method (vfs.iofs.NewError); errors.Is follows
--     the `unwrap` field like Go's Unwrap chain.
--   * fs.FS: an object with fsys:Open(name) -> file, err. Optional fast paths, like the Go
--     interfaces StatFS / ReadFileFS / ReadDirFS: fsys:Stat(name), fsys:ReadFile(name) -> data, err,
--     fsys:ReadDir(name) -> entries, err. They are detected by the presence of an `iofsStat`,
--     `iofsReadFile` and `iofsReadDir` method respectively, because the vfs.FS methods share the
--     Go names but have different signatures.
--   * fs.File: file:Stat() -> info, err; file:ReadAll() -> data, err (replaces io.Reader);
--     directories also have file:ReadDir(n) -> entries, err; file:Close().
--   * fs.FileInfo: Name(), Size(), Mode(), ModTime(), IsDir(), Sys().
--   * fs.DirEntry: Name(), IsDir(), Type(), Info() -> info, err.
--   * time.Time values are numbers (seconds); the zero time is 0.
local vfs = require("tslua.vfs")

local iofs = {}
vfs.iofs = iofs

-- errors

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
    return e:Error()
end
iofs.Error = Error

function iofs.NewError(message, unwrap)
    return setmetatable({ message = message, unwrap = unwrap }, Error)
end

function Error:Error()
    if self.unwrap ~= nil and self.message == nil then
        return self.unwrap:Error()
    end
    return self.message
end

-- fs.PathError
function iofs.NewPathError(op, path, err)
    return setmetatable({ message = op .. " " .. path .. ": " .. err:Error(), unwrap = err, op = op, path = path }, Error)
end

-- errors.Is
function iofs.Is(err, target)
    while err ~= nil do
        if err == target then
            return true
        end
        if type(err) ~= "table" then
            return false
        end
        err = err.unwrap
    end
    return false
end

iofs.ErrInvalid = iofs.NewError("invalid argument")
iofs.ErrPermission = iofs.NewError("permission denied")
iofs.ErrExist = iofs.NewError("file already exists")
iofs.ErrNotExist = iofs.NewError("file does not exist")
iofs.ErrClosed = iofs.NewError("file already closed")
iofs.SkipAll = iofs.NewError("skip everything and stop the walk")
iofs.SkipDir = iofs.NewError("skip this directory")

-- FileMode

iofs.ModeDir = 1 << 31
iofs.ModeAppend = 1 << 30
iofs.ModeExclusive = 1 << 29
iofs.ModeTemporary = 1 << 28
iofs.ModeSymlink = 1 << 27
iofs.ModeDevice = 1 << 26
iofs.ModeNamedPipe = 1 << 25
iofs.ModeSocket = 1 << 24
iofs.ModeSetuid = 1 << 23
iofs.ModeSetgid = 1 << 22
iofs.ModeCharDevice = 1 << 21
iofs.ModeSticky = 1 << 20
iofs.ModeIrregular = 1 << 19
iofs.ModeType = iofs.ModeDir | iofs.ModeSymlink | iofs.ModeNamedPipe | iofs.ModeSocket | iofs.ModeDevice | iofs.ModeCharDevice | iofs.ModeIrregular
iofs.ModePerm = 511 -- 0o777

function iofs.FileMode_IsDir(m)
    return m & iofs.ModeDir ~= 0
end

function iofs.FileMode_IsRegular(m)
    return m & iofs.ModeType == 0
end

function iofs.FileMode_Type(m)
    return m & iofs.ModeType
end

-- fs.ValidPath
function iofs.ValidPath(name)
    if name == "." then
        return true
    end
    while true do
        local i = string.find(name, "/", 1, true)
        local elem = name
        if i ~= nil then
            elem = string.sub(name, 1, i - 1)
        end
        if elem == "" or elem == "." or elem == ".." then
            return false
        end
        if i == nil then
            return true
        end
        name = string.sub(name, i + 1)
    end
end

-- path.Join for the two-element case used by the walkers (both elements already clean).
local function pathJoin(dir, name)
    if dir == "." or dir == "" then
        return name
    end
    if name == "" then
        return dir
    end
    if string.sub(dir, -1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end
iofs.pathJoin = pathJoin

-- path.Base
function iofs.pathBase(p)
    if p == "" then
        return "."
    end
    while #p > 1 and string.sub(p, -1) == "/" do
        p = string.sub(p, 1, -2)
    end
    local i = string.find(p, "/[^/]*$")
    if i ~= nil then
        p = string.sub(p, i + 1)
    end
    if p == "" then
        return "/"
    end
    return p
end

-- fs.FileInfoToDirEntry

local statDirEntry = {}
statDirEntry.__index = statDirEntry

function statDirEntry:Name() return self.info:Name() end
function statDirEntry:IsDir() return self.info:IsDir() end
function statDirEntry:Type() return iofs.FileMode_Type(self.info:Mode()) end
function statDirEntry:Info() return self.info, nil end

function iofs.FileInfoToDirEntry(info)
    if info == nil then
        return nil
    end
    return setmetatable({ info = info }, statDirEntry)
end

-- fs.Stat
function iofs.Stat(fsys, name)
    if fsys.iofsStat ~= nil then
        return fsys:iofsStat(name)
    end
    local file, err = fsys:Open(name)
    if err ~= nil then
        return nil, err
    end
    local info, err2 = file:Stat()
    file:Close()
    return info, err2
end

-- fs.ReadFile
function iofs.ReadFile(fsys, name)
    if fsys.iofsReadFile ~= nil then
        return fsys:iofsReadFile(name)
    end
    local file, err = fsys:Open(name)
    if err ~= nil then
        return nil, err
    end
    local data, err2 = file:ReadAll()
    file:Close()
    return data, err2
end

-- fs.ReadDir (sorted by file name)
function iofs.ReadDir(fsys, name)
    if fsys.iofsReadDir ~= nil then
        return fsys:iofsReadDir(name)
    end
    local file, err = fsys:Open(name)
    if err ~= nil then
        return nil, err
    end
    if file.ReadDir == nil then
        file:Close()
        return nil, iofs.NewPathError("readdir", name, iofs.NewError("not implemented"))
    end
    local list, err2 = file:ReadDir(-1)
    file:Close()
    if list ~= nil then
        table.sort(list, function(a, b)
            return a:Name() < b:Name()
        end)
    end
    return list, err2
end

local function walkDir(fsys, name, d, walkDirFn)
    local err = walkDirFn(name, d, nil)
    if err ~= nil or not d:IsDir() then
        if err == iofs.SkipDir and d:IsDir() then
            -- Successfully skipped directory.
            err = nil
        end
        return err
    end

    local dirs, rerr = iofs.ReadDir(fsys, name)
    if rerr ~= nil then
        -- Second call, to report ReadDir error.
        err = walkDirFn(name, d, rerr)
        if err ~= nil then
            if err == iofs.SkipDir and d:IsDir() then
                err = nil
            end
            return err
        end
    end

    for _, d1 in ipairs(dirs or {}) do
        local name1 = pathJoin(name, d1:Name())
        local err1 = walkDir(fsys, name1, d1, walkDirFn)
        if err1 ~= nil then
            if err1 == iofs.SkipDir then
                break
            end
            return err1
        end
    end
    return nil
end

-- fs.WalkDir
function iofs.WalkDir(fsys, root, fn)
    local info, err = iofs.Stat(fsys, root)
    if err ~= nil then
        err = fn(root, nil, err)
    else
        err = walkDir(fsys, root, iofs.FileInfoToDirEntry(info), fn)
    end
    if err == iofs.SkipDir or err == iofs.SkipAll then
        return nil
    end
    return err
end

-- fs.Sub

local subFS = {}
subFS.__index = subFS

function iofs.Sub(fsys, dir)
    if not iofs.ValidPath(dir) then
        return nil, iofs.NewPathError("sub", dir, iofs.ErrInvalid)
    end
    if dir == "." then
        return fsys, nil
    end
    return setmetatable({ fsys = fsys, dir = dir }, subFS), nil
end

function subFS:fullName(op, name)
    if not iofs.ValidPath(name) then
        return nil, iofs.NewPathError(op, name, iofs.ErrInvalid)
    end
    return pathJoin(self.dir, name == "." and "" or name), nil
end

function subFS:Open(name)
    local full, err = self:fullName("open", name)
    if err ~= nil then
        return nil, err
    end
    return self.fsys:Open(full)
end

function subFS:iofsReadDir(name)
    local full, err = self:fullName("read", name)
    if err ~= nil then
        return nil, err
    end
    return iofs.ReadDir(self.fsys, full)
end

function subFS:iofsReadFile(name)
    local full, err = self:fullName("read", name)
    if err ~= nil then
        return nil, err
    end
    return iofs.ReadFile(self.fsys, full)
end

function subFS:iofsStat(name)
    local full, err = self:fullName("stat", name)
    if err ~= nil then
        return nil, err
    end
    return iofs.Stat(self.fsys, full)
end

-- testing/fstest.MapFS
--
-- A MapFS is a Lua table path -> MapFile. A MapFile is { data = "", mode = 0, modTime = 0, sys = any }.

local fstest = {}
iofs.fstest = fstest

local MapFS = {}
MapFS.__index = MapFS
fstest.MapFS = MapFS

-- Wraps a plain table of path -> MapFile.
function fstest.NewMapFS(files)
    return setmetatable({ files = files or {} }, MapFS)
end

function fstest.NewMapFile(fields)
    fields = fields or {}
    return {
        data = fields.data or "",
        mode = fields.mode or 0,
        modTime = fields.modTime or 0,
        sys = fields.sys,
    }
end

function fstest.CopyMapFile(f)
    return { data = f.data, mode = f.mode, modTime = f.modTime, sys = f.sys }
end

local mapFileInfo = {}
mapFileInfo.__index = mapFileInfo

local function newMapFileInfo(name, f)
    return setmetatable({ name = name, f = f }, mapFileInfo)
end

function mapFileInfo:Name() return iofs.pathBase(self.name) end
function mapFileInfo:Size() return #self.f.data end
function mapFileInfo:Mode() return self.f.mode end
function mapFileInfo:Type() return iofs.FileMode_Type(self.f.mode) end
function mapFileInfo:ModTime() return self.f.modTime end
function mapFileInfo:IsDir() return iofs.FileMode_IsDir(self.f.mode) end
function mapFileInfo:Sys() return self.f.sys end
function mapFileInfo:Info() return self, nil end

local openMapFile = {}
openMapFile.__index = openMapFile

function openMapFile:Stat() return self.info, nil end
function openMapFile:Close() return nil end
function openMapFile:ReadAll() return self.info.f.data, nil end

local mapDir = {}
mapDir.__index = mapDir

function mapDir:Stat() return self.info, nil end
function mapDir:Close() return nil end
function mapDir:ReadAll()
    return nil, iofs.NewPathError("read", self.path, iofs.ErrInvalid)
end

function mapDir:ReadDir(count)
    local n = #self.entry - self.offset
    if n == 0 and count > 0 then
        return nil, iofs.NewError("EOF")
    end
    if count > 0 and n > count then
        n = count
    end
    local list = {}
    for i = 1, n do
        list[i] = self.entry[self.offset + i]
    end
    self.offset = self.offset + n
    return list, nil
end

function MapFS:resolveSymlinks(name)
    local fsys = self.files
    -- Fast path: if a symlink is in the map, resolve it.
    local file = fsys[name]
    if file ~= nil and iofs.FileMode_Type(file.mode) == iofs.ModeSymlink then
        local target = file.data
        if string.sub(target, 1, 1) == "/" then
            return "", false
        end
        local dir = string.match(name, "^(.*)/[^/]*$") or "."
        return self:resolveSymlinks(pathJoin(dir, target))
    end

    -- Check if each parent directory (starting at root) is a symlink.
    local i = 0
    while i < #name do
        local j = string.find(name, "/", i + 1, true)
        local dir
        if j == nil then
            dir = name
            i = #name
        else
            dir = string.sub(name, 1, j - 1)
            i = j - 1
        end
        local f = fsys[dir]
        if f ~= nil and iofs.FileMode_Type(f.mode) == iofs.ModeSymlink then
            local target = f.data
            if string.sub(target, 1, 1) == "/" then
                return "", false
            end
            local parent = string.match(dir, "^(.*)/[^/]*$") or "."
            return self:resolveSymlinks(pathJoin(parent, target) .. string.sub(name, i + 1))
        end
        i = i + 1
    end
    return name, iofs.ValidPath(name)
end

function MapFS:Open(name)
    if not iofs.ValidPath(name) then
        return nil, iofs.NewPathError("open", name, iofs.ErrNotExist)
    end
    local realName, ok = self:resolveSymlinks(name)
    if not ok then
        return nil, iofs.NewPathError("open", name, iofs.ErrNotExist)
    end
    local fsys = self.files

    local file = fsys[realName]
    if file ~= nil and file.mode & iofs.ModeDir == 0 then
        -- Ordinary file
        return setmetatable({ path = name, info = newMapFileInfo(iofs.pathBase(name), file) }, openMapFile), nil
    end

    -- Directory, possibly synthesized.
    local list = {}
    local need = {}
    if realName == "." then
        for fname, f in pairs(fsys) do
            local i = string.find(fname, "/", 1, true)
            if i == nil then
                if fname ~= "." then
                    list[#list + 1] = newMapFileInfo(fname, f)
                end
            else
                need[string.sub(fname, 1, i - 1)] = true
            end
        end
    else
        local prefix = realName .. "/"
        local plen = #prefix
        for fname, f in pairs(fsys) do
            if string.sub(fname, 1, plen) == prefix then
                local felem = string.sub(fname, plen + 1)
                local i = string.find(felem, "/", 1, true)
                if i == nil then
                    list[#list + 1] = newMapFileInfo(felem, f)
                else
                    need[string.sub(felem, 1, i - 1)] = true
                end
            end
        end
        -- If the directory name is not in the map,
        -- and there are no children of the name in the map,
        -- then the directory is treated as not existing.
        if file == nil and #list == 0 and next(need) == nil then
            return nil, iofs.NewPathError("open", name, iofs.ErrNotExist)
        end
    end
    for _, fi in ipairs(list) do
        need[fi.name] = nil
    end
    for n in pairs(need) do
        list[#list + 1] = newMapFileInfo(n, fstest.NewMapFile({ mode = iofs.ModeDir | 365 }))
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)

    if file == nil then
        file = fstest.NewMapFile({ mode = iofs.ModeDir | 365 })
    end
    local elem
    if name == "." then
        elem = "."
    else
        elem = string.match(name, "[^/]*$")
    end
    return setmetatable({ path = name, info = newMapFileInfo(elem, file), entry = list, offset = 0 }, mapDir), nil
end

return iofs
