local vfsmock = require("tslua.vfs.vfsmock")

-- Wrap wraps a vfs.FS and returns a FSMock which calls it.
function vfsmock.Wrap(fs)
    return vfsmock.NewFSMock({
        directoryExistsFunc = function(path) return fs:DirectoryExists(path) end,
        fileExistsFunc = function(path) return fs:FileExists(path) end,
        getAccessibleEntriesFunc = function(path) return fs:GetAccessibleEntries(path) end,
        readFileFunc = function(path) return fs:ReadFile(path) end,
        realpathFunc = function(path) return fs:Realpath(path) end,
        removeFunc = function(path) return fs:Remove(path) end,
        chtimesFunc = function(path, aTime, mTime) return fs:Chtimes(path, aTime, mTime) end,
        statFunc = function(path) return fs:Stat(path) end,
        useCaseSensitiveFileNamesFunc = function() return fs:UseCaseSensitiveFileNames() end,
        walkDirFunc = function(root, walkFn) return fs:WalkDir(root, walkFn) end,
        writeFileFunc = function(path, data) return fs:WriteFile(path, data) end,
        appendFileFunc = function(path, data) return fs:AppendFile(path, data) end,
    })
end

return vfsmock
