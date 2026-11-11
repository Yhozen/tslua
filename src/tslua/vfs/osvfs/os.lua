local osvfs = require("tslua.vfs.osvfs")
local internal = require("tslua.vfs.internal")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

-- Pure-Lua stand-ins for the Go os package (POSIX only). Files are read with io.open; a path is a
-- directory when reading from it fails with EISDIR; directories are listed with `find` through
-- io.popen. File modification times are not available (ModTime() is 0). The Go semaphores that
-- limit concurrent syscalls have no equivalent (the port is single-threaded).

local EISDIR = 21

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end
osvfs.shellQuote = shellQuote

local osFileInfo = {}
osFileInfo.__index = osFileInfo

function osFileInfo:Name() return self.name end
function osFileInfo:Size() return self.size end
function osFileInfo:Mode() return self.mode end
function osFileInfo:Type() return iofs.FileMode_Type(self.mode) end
function osFileInfo:ModTime() return 0 end
function osFileInfo:IsDir() return iofs.FileMode_IsDir(self.mode) end
function osFileInfo:Sys() return nil end
function osFileInfo:Info() return self, nil end

-- os.Stat (follows symlinks).
local function osStat(path)
    local f, msg = io.open(path, "rb")
    if f == nil then
        if msg ~= nil and string.find(msg, "Permission denied", 1, true) then
            return nil, iofs.NewPathError("stat", path, iofs.ErrPermission)
        end
        return nil, iofs.NewPathError("stat", path, iofs.ErrNotExist)
    end
    local _, _, code = f:read(0)
    local name = iofs.pathBase(path)
    if code == EISDIR then
        f:close()
        return setmetatable({ name = name, size = 0, mode = iofs.ModeDir | 493 }, osFileInfo), nil
    end
    local size = f:seek("end") or 0
    f:close()
    return setmetatable({ name = name, size = size, mode = 420 }, osFileInfo), nil
end
osvfs.osStat = osStat

-- os.ReadDir: entries sorted by name, symlinks are reported with ModeSymlink.
local function osReadDir(path)
    local p = io.popen("find " .. shellQuote(path) .. " -mindepth 1 -maxdepth 1 -printf '%y\\t%f\\n' 2>/dev/null")
    if p == nil then
        return nil, iofs.NewPathError("readdir", path, iofs.ErrNotExist)
    end
    local entries = {}
    for line in p:lines() do
        local t, name = string.match(line, "^(%a)\t(.*)$")
        if t ~= nil then
            local mode
            if t == "d" then
                mode = iofs.ModeDir | 493
            elseif t == "f" then
                mode = 420
            elseif t == "l" then
                mode = iofs.ModeSymlink | 511
            elseif t == "p" then
                mode = iofs.ModeNamedPipe
            elseif t == "s" then
                mode = iofs.ModeSocket
            elseif t == "c" then
                mode = iofs.ModeDevice | iofs.ModeCharDevice
            elseif t == "b" then
                mode = iofs.ModeDevice
            else
                mode = iofs.ModeIrregular
            end
            entries[#entries + 1] = setmetatable({ name = name, size = 0, mode = mode }, osFileInfo)
        end
    end
    p:close()
    if #entries == 0 then
        local info = osStat(path)
        if info == nil or not info:IsDir() then
            return nil, iofs.NewPathError("readdir", path, iofs.ErrNotExist)
        end
    end
    table.sort(entries, function(a, b)
        return a.name < b.name
    end)
    return entries, nil
end
osvfs.osReadDir = osReadDir

local function osReadFile(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil, iofs.NewPathError("open", path, iofs.ErrNotExist)
    end
    local data, _, code = f:read("a")
    f:close()
    if data == nil then
        if code == EISDIR then
            return nil, iofs.NewPathError("read", path, iofs.ErrInvalid)
        end
        return nil, iofs.NewPathError("read", path, iofs.ErrInvalid)
    end
    return data, nil
end
osvfs.osReadFile = osReadFile

-- os.DirFS
local dirFS = {}
dirFS.__index = dirFS

local function osDirFS(dir)
    return setmetatable({ dir = dir }, dirFS)
end

function dirFS:join(name)
    if not iofs.ValidPath(name) then
        return nil
    end
    if name == "." then
        return self.dir
    end
    if string.sub(self.dir, -1) == "/" then
        return self.dir .. name
    end
    return self.dir .. "/" .. name
end

local osFile = {}
osFile.__index = osFile

function osFile:Stat() return self.info, nil end
function osFile:Close() return nil end
function osFile:ReadAll() return osReadFile(self.path) end
function osFile:ReadDir(n)
    local entries, err = osReadDir(self.path)
    if err ~= nil then
        return nil, err
    end
    return entries, nil
end

function dirFS:Open(name)
    local full = self:join(name)
    if full == nil then
        return nil, iofs.NewPathError("open", name, iofs.ErrInvalid)
    end
    local info, err = osStat(full)
    if err ~= nil then
        return nil, err
    end
    return setmetatable({ path = full, info = info }, osFile), nil
end

function dirFS:iofsStat(name)
    local full = self:join(name)
    if full == nil then
        return nil, iofs.NewPathError("stat", name, iofs.ErrInvalid)
    end
    return osStat(full)
end

function dirFS:iofsReadFile(name)
    local full = self:join(name)
    if full == nil then
        return nil, iofs.NewPathError("readfile", name, iofs.ErrInvalid)
    end
    return osReadFile(full)
end

function dirFS:iofsReadDir(name)
    local full = self:join(name)
    if full == nil then
        return nil, iofs.NewPathError("readdir", name, iofs.ErrInvalid)
    end
    return osReadDir(full)
end

local osFS = {}
osFS.__index = osFS
osvfs.osFS = osFS

-- FS creates a new FS from the OS file system.
function osvfs.FS()
    return osvfs.osVFS
end

local function sourceFile()
    local src = debug.getinfo(1, "S").source
    if string.sub(src, 1, 1) == "@" then
        src = string.sub(src, 2)
    end
    return src
end

-- Convert all lowercase chars to uppercase, and vice-versa
function osvfs.swapCase(str)
    return (string.gsub(str, "%a", function(c)
        local upper = string.upper(c)
        if upper == c then
            return string.lower(c)
        end
        return upper
    end))
end

-- Computed once, on first use. As a proxy for case-insensitivity, we check if this source file
-- exists under a different case (Go uses the current executable).
local isFileSystemCaseSensitive = nil

function osvfs.isFileSystemCaseSensitive()
    if isFileSystemCaseSensitive == nil then
        local file = osvfs.absPath(sourceFile())
        local swapped = osvfs.swapCase(file)
        local f = io.open(swapped, "rb")
        if f == nil then
            isFileSystemCaseSensitive = true
        else
            f:close()
            isFileSystemCaseSensitive = false
        end
    end
    return isFileSystemCaseSensitive
end

local cwd = nil

-- os.Getwd
function osvfs.Getwd()
    if cwd == nil then
        cwd = os.getenv("PWD")
        if cwd == nil or cwd == "" then
            local p = io.popen("pwd")
            if p ~= nil then
                cwd = p:read("l")
                p:close()
            end
        end
        cwd = cwd or "/"
    end
    return cwd
end

-- filepath.Abs
function osvfs.absPath(path)
    if string.sub(path, 1, 1) == "/" then
        return tspath.NormalizePath(path)
    end
    return tspath.NormalizePath(osvfs.Getwd() .. "/" .. path)
end

osvfs.osVFS = setmetatable({
    common = internal.NewCommon(osDirFS, function(path)
        return osvfs.isReparsePoint(path)
    end),
}, osFS)

function osFS:UseCaseSensitiveFileNames()
    return osvfs.isFileSystemCaseSensitive()
end

function osFS:ReadFile(path)
    return self.common:ReadFile(path)
end

function osFS:DirectoryExists(path)
    return self.common:DirectoryExists(path)
end

function osFS:FileExists(path)
    return self.common:FileExists(path)
end

function osFS:GetAccessibleEntries(path)
    return self.common:GetAccessibleEntries(path)
end

function osFS:Stat(path)
    return self.common:Stat(path)
end

function osFS:WalkDir(root, walkFn)
    return self.common:WalkDir(root, walkFn)
end

function osFS:Realpath(path)
    return osvfs.osFSRealpath(path)
end

function osvfs.osFSRealpath(path)
    local _ = internal.RootLength(path) -- Assert path is rooted

    local orig = path
    local p = io.popen("realpath -e -- " .. shellQuote(path) .. " 2>/dev/null")
    if p == nil then
        return orig
    end
    local resolved = p:read("l")
    p:close()
    if resolved == nil or resolved == "" then
        return orig
    end
    return tspath.NormalizeSlashes(osvfs.absPath(resolved))
end

function osvfs.isReparsePoint(path)
    return os.execute("test -L " .. shellQuote(path)) == true
end

function osFS:writeFileWithFlag(path, content, mode)
    local file, msg = io.open(path, mode)
    if file == nil then
        return iofs.NewError(msg or ("open " .. path))
    end

    local ok, werr = file:write(content)
    file:close()
    if ok == nil then
        return iofs.NewError(werr or ("write " .. path))
    end

    return nil
end

function osFS:ensureDirectoryExists(directoryPath)
    local ok = os.execute("mkdir -p -- " .. shellQuote(directoryPath))
    if ok ~= true then
        return iofs.NewError("mkdir " .. directoryPath .. ": failed")
    end
    return nil
end

function osFS:writeFileEnsuringDir(path, content, mode)
    local _ = internal.RootLength(path) -- Assert path is rooted
    if self:writeFileWithFlag(path, content, mode) == nil then
        return nil
    end
    local err = self:ensureDirectoryExists(tspath.GetDirectoryPath(tspath.NormalizePath(path)))
    if err ~= nil then
        return err
    end
    return self:writeFileWithFlag(path, content, mode)
end

function osFS:WriteFile(path, content)
    return self:writeFileEnsuringDir(path, content, "wb")
end

function osFS:AppendFile(path, content)
    return self:writeFileEnsuringDir(path, content, "ab")
end

function osFS:Remove(path)
    -- todo: #701 add retry mechanism?
    local ok = os.execute("rm -rf -- " .. shellQuote(path))
    if ok ~= true then
        return iofs.NewError("remove " .. path .. ": failed")
    end
    return nil
end

function osFS:Chtimes(path, aTime, mTime)
    local ok = os.execute("touch -a -d @" .. tostring(math.floor(aTime)) .. " -- " .. shellQuote(path)
        .. " && touch -m -d @" .. tostring(math.floor(mTime)) .. " -- " .. shellQuote(path))
    if ok ~= true then
        return iofs.NewError("chtimes " .. path .. ": failed")
    end
    return nil
end

function osvfs.GetGlobalTypingsCacheLocation()
    local cacheDir = os.getenv("XDG_CACHE_HOME")
    if cacheDir == nil or cacheDir == "" then
        local home = os.getenv("HOME")
        if home ~= nil and home ~= "" then
            cacheDir = home .. "/.cache"
        else
            cacheDir = os.getenv("TMPDIR") or "/tmp"
        end
    end

    local core = require("tslua.core") -- loaded lazily: osvfs is used by tooling that does not load the compiler
    local subdir = "typescript"
    return tspath.CombinePaths(cacheDir, subdir, core.VersionMajorMinor())
end

return osvfs
