local watchmanager = require("tslua.execute.watchmanager")
local fswatch = require("tslua.fswatch")
local tspath = require("tslua.tspath")

-- WatchBackend abstracts fswatch.Watcher for testing (a Go interface):
--   WatchDirectory(dir, fn, recursive, ignore) -> io.Closer, err
--   WatchDirectories(requests []WatchDirectoryRequest) -> []io.Closer, err
-- An io.Closer is an object with Close() -> err.

-- WatchDirectoryRequest: { dir = string, callback = fswatch.WatchCallback, recursive = bool,
--   ignore = func(string) bool }
function watchmanager.NewWatchDirectoryRequest(dir, callback, recursive, ignore)
    return { dir = dir, callback = callback, recursive = recursive or false, ignore = ignore }
end

-- CommandLineTestingWithWatchBackend is an optional extension of
-- [CommandLineTesting] that supplies a [WatchBackend] for test mode: a testing object that has a
-- WatchBackend() method.
function watchmanager.AsCommandLineTestingWithWatchBackend(testing)
    if testing ~= nil and testing.WatchBackend ~= nil then
        return testing, true
    end
    return nil, false
end

local FSWatchBackend = {}
FSWatchBackend.__index = FSWatchBackend
watchmanager.FSWatchBackend = FSWatchBackend

function watchmanager.NewFSWatchBackend(inner)
    return setmetatable({ inner = inner }, FSWatchBackend)
end

function FSWatchBackend:WatchDirectory(dir, fn, recursive, ignore)
    local closers, err = self:WatchDirectories({ watchmanager.NewWatchDirectoryRequest(dir, fn, recursive, ignore) })
    if err ~= nil then
        return nil, err
    end
    return closers[1], nil
end

function FSWatchBackend:WatchDirectories(requests)
    local fswatchRequests = {}
    for i, request in ipairs(requests) do
        local opts = {}
        if request.recursive then
            opts[#opts + 1] = fswatch.WithRecursive()
        end
        if request.ignore ~= nil then
            opts[#opts + 1] = fswatch.WithIgnore(request.ignore)
        end
        fswatchRequests[i] = fswatch.NewWatchDirectoryRequest(request.dir, request.callback, opts)
    end
    local watches, err = self.inner:WatchDirectories(fswatchRequests)
    if err ~= nil then
        return nil, err
    end
    local closers = {}
    for i, watch in ipairs(watches or {}) do
        closers[i] = watch
    end
    return closers, nil
end

local function hasSuffix(s, suffix)
    return suffix == "" or string.sub(s, -#suffix) == suffix
end

local function contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

function watchmanager.ShouldIgnoreWatchPath(path)
    local p = tspath.NormalizeSlashes(path)
    return hasSuffix(p, "/.git") or
        contains(p, "/.git/") or
        contains(p, "/node_modules/.") or
        contains(p, "/.#")
end

function watchmanager.CanWatchDirectory(dir)
    local components = tspath.GetPathComponents(dir, "")
    local length = #components
    if length <= 2 then
        return false
    end
    local rootLength = watchmanager.PerceivedOsRootLengthForWatching(components)
    return length > rootLength + 1
end

function watchmanager.PerceivedOsRootLengthForWatching(components)
    local length = #components
    if length <= 1 then
        return 1
    end
    local root = components[1]
    local indexAfterOsRoot = 1
    local isDosStyle = #root >= 2 and tspath.IsVolumeCharacter(string.byte(root, 1)) and string.byte(root, 2) == 58 -- ':'

    if root ~= "/" and not isDosStyle and #components > 1 then
        local c1 = components[2]
        if #c1 >= 2 and tspath.IsVolumeCharacter(string.byte(c1, 1)) and hasSuffix(c1, "$") then
            if length == 2 then
                return 2
            end
            indexAfterOsRoot = 2
            isDosStyle = true
        end
    end

    if isDosStyle and (indexAfterOsRoot >= length or string.lower(components[indexAfterOsRoot + 1]) ~= "users") then
        return indexAfterOsRoot
    end

    if indexAfterOsRoot < length and string.lower(components[indexAfterOsRoot + 1]) == "workspaces" then
        return indexAfterOsRoot + 1
    end

    return indexAfterOsRoot + 2
end
