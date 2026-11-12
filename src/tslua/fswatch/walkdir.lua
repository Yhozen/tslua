local fswatch = require("tslua.fswatch")
local osvfs = require("tslua.vfs.osvfs")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

-- syscall.ENOTDIR
fswatch.ENOTDIR = iofs.NewError("not a directory")

-- os.Lstat, reduced to what walkDirGeneric needs: returns (isDir, err). Uses find(1) like the
-- osvfs package (pure Lua has no lstat).
function fswatch.osLstatIsDir(path)
    local p = io.popen("find " .. osvfs.shellQuote(path) .. " -maxdepth 0 -printf '%y' 2>/dev/null")
    if p == nil then
        return false, iofs.NewPathError("lstat", path, iofs.ErrNotExist)
    end
    local t = p:read("a")
    p:close()
    if t == nil or t == "" then
        return false, iofs.NewPathError("lstat", path, iofs.ErrNotExist)
    end
    return t == "d", nil
end

-- walkDirGeneric is the portable walkDir implementation. It is used as the
-- primary implementation on platforms without a native version, and is
-- tested on all platforms.
function fswatch.walkDirGeneric(dir, recursive, fn)
    local isDir, err = fswatch.osLstatIsDir(dir)
    if err ~= nil then
        return err
    end
    if not isDir then
        return fswatch.ENOTDIR
    end
    return fswatch.walkDirGenericVisit(dir, recursive, fn)
end

function fswatch.walkDirGenericVisit(dir, recursive, fn)
    local entries, err = osvfs.osReadDir(dir)
    if err ~= nil then
        if iofs.Is(err, iofs.ErrPermission) or iofs.Is(err, iofs.ErrNotExist) then
            return nil
        end
        return err
    end
    if fn ~= nil then
        local ferr = fn(dir, true)
        if ferr ~= nil then
            return ferr
        end
    end
    for _, e in ipairs(entries) do
        local path = dir .. "/" .. e:Name()
        if e:IsDir() then
            if recursive then
                local verr = fswatch.walkDirGenericVisit(path, recursive, fn)
                if verr ~= nil then
                    return verr
                end
            elseif fn ~= nil then
                local ferr = fn(path, true)
                if ferr ~= nil then
                    return ferr
                end
            end
        elseif fn ~= nil then
            local ferr = fn(path, false)
            if ferr ~= nil then
                return ferr
            end
        end
    end
    return nil
end

-- walkdir_other.go: the native getdents/ReadDirectoryChangesW walkers need syscalls, so every
-- platform uses the generic walker.
function fswatch.walkDir(dir, recursive, fn)
    return fswatch.walkDirGeneric(dir, recursive, fn)
end
