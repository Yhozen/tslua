local project = require("tslua.project")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local dirty = require("tslua.project.dirty")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")
local cachedvfs = require("tslua.vfs.cachedvfs")

-- FileSource interface (implemented by snapshotFSBuilder, SnapshotFS and autoImportBuilderFS):
--   FS() vfs.FS, GetFile(fileName) FileHandle, GetFileByPath(fileName, path) FileHandle,
--   FileExists(fileName, path) bool, GetAccessibleEntries(path) vfs.Entries

-- realpathAliasSet is a set of symlink paths that alias a single realpath.
-- It implements dirty.Cloneable so it can be used as a value in dirty.SyncMap.
local realpathAliasSet = {}
realpathAliasSet.__index = realpathAliasSet
project.realpathAliasSet = realpathAliasSet

function project.newRealpathAliasSet()
    return setmetatable({ paths = collections.NewSet() }, realpathAliasSet)
end

function realpathAliasSet:Add(path)
    self.paths:Add(path)
end

function realpathAliasSet:Clone()
    local clone = project.newRealpathAliasSet()
    if self.paths:Len() > 0 then
        clone.paths = self.paths:Clone()
    end
    return clone
end

-- SnapshotFS: { toPath, fs, overlays, overlayDirectories, diskFiles, diskDirectories, readFiles,
--   nodeModulesRealpathAliases }
-- nodeModulesRealpathAliases maps realpath-based keys to sets of symlink-based keys,
-- for files inside node_modules that are accessed through directory symlinks.
-- This allows watch events (which use realpaths) to invalidate files cached under symlink paths.
local SnapshotFS = {}
SnapshotFS.__index = SnapshotFS
project.SnapshotFS = SnapshotFS

function project.NewSnapshotFS(fields)
    return setmetatable({
        toPath = fields.toPath,
        fs = fields.fs,
        overlays = fields.overlays,
        overlayDirectories = fields.overlayDirectories,
        diskFiles = fields.diskFiles,
        diskDirectories = fields.diskDirectories,
        readFiles = collections.NewSyncMap(),
        nodeModulesRealpathAliases = fields.nodeModulesRealpathAliases,
    }, SnapshotFS)
end

function SnapshotFS:FS()
    return self.fs
end

function SnapshotFS:GetFile(fileName)
    return self:GetFileByPath(fileName, self.toPath(fileName))
end

function SnapshotFS:FileExists(fileName, path)
    if self.overlays ~= nil and self.overlays[path] ~= nil then
        return true
    end
    if self.diskFiles ~= nil and self.diskFiles[path] ~= nil then
        return true
    end
    return self.fs:FileExists(fileName)
end

function SnapshotFS:GetFileByPath(fileName, path)
    local file = self.overlays ~= nil and self.overlays[path] or nil
    if file ~= nil then
        return file
    end
    file = self.diskFiles ~= nil and self.diskFiles[path] or nil
    if file ~= nil then
        return file
    end
    -- memoizedDiskFile: sync.OnceValue reading the file from disk.
    local newEntry = { done = false, value = nil }
    local entry = self.readFiles:LoadOrStore(path, newEntry)
    if not entry.done then
        entry.done = true
        local contents, ok = self.fs:ReadFile(fileName)
        if ok then
            entry.value = project.newDiskFile(fileName, contents)
        end
    end
    return entry.value
end

function SnapshotFS:GetAccessibleEntries(directoryName)
    local entries = vfs.NewEntries(nil, nil, nil)
    local path = self.toPath(directoryName)
    local diskDirectories = self.diskDirectories ~= nil and self.diskDirectories[path] or nil
    if diskDirectories ~= nil then
        project.readDirectoryIntoEntries(diskDirectories, function(p) return self:isFile(p) end, entries)
    end
    local overlayDirectories = self.overlayDirectories ~= nil and self.overlayDirectories[path] or nil
    if overlayDirectories ~= nil then
        project.readDirectoryIntoEntries(overlayDirectories, function(p) return self:isFile(p) end, entries)
    end
    return entries
end

function SnapshotFS:isOpenFile(fileName)
    local path = self.toPath(fileName)
    return self.overlays ~= nil and self.overlays[path] ~= nil
end

function SnapshotFS:isFile(path)
    if self.diskFiles ~= nil and self.diskFiles[path] ~= nil then
        return true
    end
    if self.overlays ~= nil and self.overlays[path] ~= nil then
        return true
    end
    return false
end

local snapshotFSBuilder = {}
snapshotFSBuilder.__index = snapshotFSBuilder
project.snapshotFSBuilder = snapshotFSBuilder

function project.newSnapshotFSBuilder(
    fs,
    prevOverlays,
    overlays,
    diskFiles,
    diskDirectories,
    nodeModulesRealpathAliases,
    positionEncoding,
    toPath
)
    local cachedFS = cachedvfs.From(fs)
    cachedFS:Enable()

    local overlayDirectories = {}
    for _, path in ipairs(project.sortedKeys(overlays)) do
        local childPath = path
        local child = overlays[path]:FileName()
        while true do
            local parentPath = tspath.Path_GetDirectoryPath(childPath)
            local parent = tspath.GetDirectoryPath(child)
            if childPath == parentPath then
                break -- reached root
            end
            local baseName = tspath.GetBaseFileName(child)
            local dir = overlayDirectories[parentPath]
            if dir ~= nil then
                dir[childPath] = baseName
            else
                dir = {}
                overlayDirectories[parentPath] = dir
                dir[childPath] = baseName
            end
            childPath = parentPath
            child = parent
        end
    end

    return setmetatable({
        fs = cachedFS,
        prevOverlays = prevOverlays,
        overlays = overlays,
        overlayDirectories = overlayDirectories,
        diskFiles = dirty.NewSyncMap(diskFiles),
        diskDirectories = dirty.NewMap(diskDirectories),
        nodeModulesRealpathAliases = dirty.NewSyncMap(nodeModulesRealpathAliases),
        toPath = toPath,
        accessibleEntries = collections.NewSyncMap(),
    }, snapshotFSBuilder)
end

function snapshotFSBuilder:FS()
    return self.fs
end

-- Finalize returns (*SnapshotFS, changed).
function snapshotFSBuilder:Finalize()
    -- Synchronize directory structure based on added and deleted files (including overlays)
    local onDeletedFileOrDirectory
    local deleted = nil

    local function onAddedFile(path, fileName)
        local childPath = path
        local child = fileName
        while true do
            local parentPath = tspath.Path_GetDirectoryPath(childPath)
            local parent = tspath.GetDirectoryPath(child)
            if childPath == parentPath then
                break -- reached root
            end
            local baseName = tspath.GetBaseFileName(child)
            local dirEntry, ok = self.diskDirectories:Get(parentPath)
            if ok then
                local cp = childPath
                dirEntry:Change(function(dir)
                    dir[cp] = baseName
                end)
                break
            else
                local dir = dirty.NewCloneableMap()
                dir[childPath] = baseName
                self.diskDirectories:Add(parentPath, dir)
            end
            childPath = parentPath
            child = parent
        end
    end

    onDeletedFileOrDirectory = function(path)
        local dirEntry, ok = self.diskDirectories:Get(tspath.Path_GetDirectoryPath(path))
        if not ok then
            return
        end
        dirEntry:Change(function(dir)
            dir[path] = nil
            if next(dir) == nil then
                dirEntry:Delete()
                onDeletedFileOrDirectory(dirEntry:Key())
            end
        end)
    end

    local diskFiles, changed = self.diskFiles:FinalizeWith({
        onDelete = function(key, value)
            if deleted == nil then
                deleted = {}
            end
            deleted[key] = value
        end,
        onAdd = function(key, value)
            onAddedFile(key, value:FileName())
        end,
    })

    for _, path in ipairs(project.sortedKeys(deleted)) do
        onDeletedFileOrDirectory(path)
    end

    -- Prune deleted symlink paths from realpath alias sets before finalizing,
    -- so that empty sets are dropped during finalization.
    for _, deletedPath in ipairs(project.sortedKeys(deleted)) do
        local deletedFile = deleted[deletedPath]
        if deletedFile == nil or deletedFile.realpathPath == "" then
            goto continue
        end
        do
            local entry, ok = self.nodeModulesRealpathAliases:Load(deletedFile.realpathPath)
            if ok then
                entry:Locked(function(e)
                    e:Change(function(aliasSet)
                        aliasSet.paths:Delete(deletedPath)
                    end)
                    if e:Value().paths:Len() == 0 then
                        e:Delete()
                    end
                end)
            end
        end
        ::continue::
    end

    local nodeModulesRealpathAliases, aliasesChanged = self.nodeModulesRealpathAliases:Finalize()

    return project.NewSnapshotFS({
        fs = self.fs,
        overlays = self.overlays,
        overlayDirectories = self.overlayDirectories,
        diskFiles = diskFiles,
        diskDirectories = core.FirstResult(self.diskDirectories:Finalize()),
        nodeModulesRealpathAliases = nodeModulesRealpathAliases,
        toPath = self.toPath,
    }), changed or aliasesChanged
end

function snapshotFSBuilder:isOpenFile(path)
    return self.overlays ~= nil and self.overlays[path] ~= nil
end

function snapshotFSBuilder:GetFile(fileName)
    local path = self.toPath(fileName)
    return self:GetFileByPath(fileName, path)
end

function snapshotFSBuilder:FileExists(fileName, path)
    if self.overlays ~= nil and self.overlays[path] ~= nil then
        return true
    end
    local entry, ok = self.diskFiles:Load(path)
    if ok then
        local val = entry:Value()
        if val == nil then
            return false
        end
        -- Entry may be dirty - reload to check current state on disk.
        return self:reloadEntryIfNeeded(entry) ~= nil
    end
    -- Path never loaded into diskFiles - use cached stat (no file read).
    return self.fs:FileExists(fileName)
end

function snapshotFSBuilder:GetFileByPath(fileName, path)
    local file = self.overlays ~= nil and self.overlays[path] or nil
    if file ~= nil then
        return file
    end
    return self:getDiskFile(fileName, path, false)
end

function snapshotFSBuilder:GetAccessibleEntries(path)
    local entries = self.fs:GetAccessibleEntries(path)
    local p = self.toPath(path)
    local overlayDirectories = self.overlayDirectories[p]
    if overlayDirectories == nil then
        return entries
    end

    local merged, ok = self.accessibleEntries:Load(p)
    if ok then
        return merged
    end
    merged = vfs.NewEntries(core.Slice(entries.files or {}), core.Slice(entries.directories or {}), entries.symlinks)
    project.readDirectoryIntoEntries(overlayDirectories, function(cp) return self:isOpenFile(cp) end, merged)
    merged = self.accessibleEntries:LoadOrStore(p, merged)
    return merged
end

function snapshotFSBuilder:getDiskFile(fileName, path, forceReload)
    local entry, loaded = self.diskFiles:LoadOrStore(path, project.newDiskFileStruct(fileName, "", "", true, ""))
    if entry ~= nil then
        if not loaded and project.contains(path, "/node_modules/") then
            self:recordRealpathAlias(entry, fileName, path)
        end
        if forceReload then
            return self:reloadEntry(entry)
        end
        return self:reloadEntryIfNeeded(entry)
    end
    return nil
end

-- recordRealpathAlias checks if fileName is accessed through a symlink and, if so,
-- records a mapping from the realpath-based key to the symlink-based key.
-- This is only called for files inside node_modules where symlinks are common.
function snapshotFSBuilder:recordRealpathAlias(diskFileEntry, symlinkFileName, symlinkPath)
    local realpath = self.fs:Realpath(symlinkFileName)
    local realpathPath = self.toPath(realpath)
    if realpathPath ~= symlinkPath then
        diskFileEntry:Change(function(file)
            file.realpathPath = realpathPath
        end)
        local entry = self.nodeModulesRealpathAliases:LoadOrStore(realpathPath, project.newRealpathAliasSet())
        entry:Change(function(aliasSet)
            aliasSet:Add(symlinkPath)
        end)
    end
end

function snapshotFSBuilder:reloadEntry(entry)
    local fileName = ""
    entry:Locked(function(e)
        if e:Value() ~= nil then
            fileName = e:Value().fileName
        end
    end)
    if fileName == "" then
        return nil
    end
    local content, ok = self.fs:ReadFile(fileName)
    entry:Locked(function(e)
        if e:Value() == nil then
            return
        end
        if ok then
            e:Change(function(file)
                file.content = content
                file.hash = project.hashString(content)
                file.needsReload = false
                file.lineMap = nil
                file.lineInfo = nil
            end)
        else
            e:Delete()
        end
    end)
    if entry:Value() == nil then
        return nil
    end
    return entry:Value()
end

function snapshotFSBuilder:reloadEntryIfNeeded(entry)
    local fileName = ""
    entry:Locked(function(e)
        if e:Value() ~= nil and not e:Value():MatchesDiskText() then
            fileName = e:Value().fileName
        end
    end)
    if fileName ~= "" then
        local content, ok = self.fs:ReadFile(fileName)
        entry:Locked(function(e)
            if e:Value() == nil or e:Value():MatchesDiskText() then
                return -- another goroutine already reloaded it
            end
            if ok then
                e:Change(function(file)
                    file.content = content
                    file.hash = project.hashString(content)
                    file.needsReload = false
                    file.lineMap = nil
                    file.lineInfo = nil
                end)
            else
                e:Delete()
            end
        end)
    end
    if entry:Value() == nil then
        return nil
    end
    return entry:Value()
end

function snapshotFSBuilder:watchChangesOverlapCache(change)
    for uri in pairs(project.setKeys(change.changed)) do
        local path = self.toPath(lsproto.DocumentUri_FileName(uri))
        local _, ok = self.diskFiles:Load(path)
        if ok then
            return true
        end
        _, ok = self.nodeModulesRealpathAliases:Load(path)
        if ok then
            return true
        end
    end
    for uri in pairs(project.setKeys(change.deleted)) do
        local path = self.toPath(lsproto.DocumentUri_FileName(uri))
        local _, ok = self.diskFiles:Load(path)
        if ok then
            return true
        end
        _, ok = self.nodeModulesRealpathAliases:Load(path)
        if ok then
            return true
        end
    end
    return false
end

function snapshotFSBuilder:invalidateCache()
    self.diskFiles:Range(function(entry)
        entry:Change(function(file)
            file.needsReload = true
        end)
        return true
    end)
end

function snapshotFSBuilder:invalidateNodeModulesCache()
    self.diskFiles:Range(function(entry)
        if project.contains(entry:Key(), "/node_modules/") then
            entry:Change(function(file)
                file.needsReload = true
            end)
        end
        return true
    end)
end

function snapshotFSBuilder:markDirtyFiles(change)
    change = project.copyFileChangeSummary(change)
    if change.changed:Len() > 0 then
        local filteredChanged = collections.NewSyncSet()
        local wg = core.NewWorkGroup(false)
        for _, uri in ipairs(project.sortedKeys(project.setKeys(change.changed))) do
            local path = self.toPath(lsproto.DocumentUri_FileName(uri))
            if self.overlays[path] ~= nil then
                filteredChanged:Add(uri)
                goto continue
            end
            do
                local entry, ok = self.diskFiles:Load(path)
                if not ok then
                    filteredChanged:Add(uri)
                    goto continue
                end
                wg:Queue(function()
                    if self:reloadEntryIfContentChanged(entry) then
                        filteredChanged:Add(uri)
                    end
                end)
            end
            ::continue::
        end
        wg:RunAndWait()
        local newChanged = collections.NewSetWithSizeHint(filteredChanged:Size())
        for _, uri in ipairs(filteredChanged:ToSlice()) do
            newChanged:Add(uri)
        end
        change.changed = newChanged
    end
    for uri in pairs(project.setKeys(change.deleted)) do
        local path = self.toPath(lsproto.DocumentUri_FileName(uri))
        local entry, ok = self.diskFiles:Load(path)
        if ok then
            entry:Delete()
        end
    end
    return change
end

function snapshotFSBuilder:reloadEntryIfContentChanged(entry)
    local file = entry:Value()
    if file == nil then
        return true
    end
    local content, ok = self.fs:ReadFile(file.fileName)
    local changed = true
    entry:Locked(function(e)
        local cur = e:Value()
        if cur == nil then
            return
        end
        if not ok then
            e:Delete()
            return
        end
        if content == cur.content then
            changed = false
            if not cur:MatchesDiskText() then
                e:Change(function(f)
                    f.needsReload = false
                end)
            end
            return
        end
        e:Change(function(f)
            f.content = content
            f.hash = project.hashString(content)
            f.needsReload = false
            f.lineMap = nil
            f.lineInfo = nil
        end)
    end)
    return changed
end

-- expandRealpathAliases adds synthetic URIs to the Changed and Deleted sets for
-- files that were accessed through node_modules symlinks. When a watch event arrives
-- using a realpath, this expands it to include the symlink-based path so that
-- downstream consumers (markDirtyFiles, markFilesChanged) can find cached entries.
function SnapshotFS:expandRealpathAliases(change)
    if next(self.nodeModulesRealpathAliases or {}) == nil then
        return change
    end
    change = project.copyFileChangeSummary(change)

    local additionalChanged = collections.NewSet()
    for uri in pairs(project.setKeys(change.changed)) do
        local path = self.toPath(lsproto.DocumentUri_FileName(uri))
        local aliases = self.nodeModulesRealpathAliases[path]
        if aliases ~= nil then
            for aliasPath in pairs(project.setKeys(aliases.paths)) do
                additionalChanged:Add(lsconv.FileNameToDocumentURI(aliasPath))
            end
        end
    end
    for uri in pairs(project.setKeys(additionalChanged)) do
        change.changed:Add(uri)
    end

    local additionalDeleted = collections.NewSet()
    for uri in pairs(project.setKeys(change.deleted)) do
        local path = self.toPath(lsproto.DocumentUri_FileName(uri))
        local aliases = self.nodeModulesRealpathAliases[path]
        if aliases ~= nil then
            for aliasPath in pairs(project.setKeys(aliases.paths)) do
                additionalDeleted:Add(lsconv.FileNameToDocumentURI(aliasPath))
            end
        end
    end
    for uri in pairs(project.setKeys(additionalDeleted)) do
        change.deleted:Add(uri)
    end

    return change
end

-- isRelevantFileName returns true if the given URI refers to a file that
-- could affect the project: it has a TypeScript-relevant or configured content-mapper extension,
-- is a dynamic (e.g. untitled) file, or is currently open as an overlay.
function snapshotFSBuilder:isRelevantFileName(uri, contentMapperExtensions, contentMapperWatchedFiles)
    local fileName = lsproto.DocumentUri_FileName(uri)
    if contentMapperWatchedFiles ~= nil and contentMapperWatchedFiles:Has(self.toPath(fileName)) then
        return true
    end
    if tspath.FileExtensionIsOneOf(fileName, contentMapperExtensions or {}) then
        return true
    end
    if tspath.IsDynamicFileName(fileName) then
        return true
    end
    local path = self.toPath(fileName)
    if self.overlays[path] ~= nil then
        return true
    end
    local i = project.lastIndexByte(path, ".")
    if i < 0 then
        return false
    end
    return project.isRelevantExtension(string.sub(path, i + 1))
end

local relevantExtensions = {
    [".js"] = true, [".jsx"] = true, [".mjs"] = true, [".cjs"] = true, [".ts"] = true,
    [".tsx"] = true, [".mts"] = true, [".cts"] = true, [".json"] = true,
}

-- isRelevantExtension returns true if the given extension is a known TypeScript
-- or JavaScript extension that can affect the project.
function project.isRelevantExtension(ext)
    return relevantExtensions[ext] == true
end

-- expandAndFilterWatchEvents expands directory deletion URIs into individual
-- file deletion URIs using the cached directory structure, and filters out
-- watch events for paths that are neither known directories nor have relevant
-- file extensions.
function snapshotFSBuilder:expandAndFilterWatchEvents(change, contentMapperExtensions, contentMapperWatchedFiles)
    change = project.copyFileChangeSummary(change)
    if change.deleted:Len() > 0 then
        local filteredDeleted = collections.NewSet()
        for uri in pairs(project.setKeys(change.deleted)) do
            local path = self.toPath(lsproto.DocumentUri_FileName(uri))
            local _, ok = self.diskDirectories:Get(path)
            if ok then
                self:collectFilesRecursive(path, filteredDeleted)
            elseif self:isRelevantFileName(uri, contentMapperExtensions, contentMapperWatchedFiles) or project.isNodeModulesPath(path) then
                -- node_modules deletions must always be preserved for auto-import registry change handlers.
                -- They won't be in diskDirectories since the registry doesn't use the snapshotFSBuilder for
                -- its file system, since we don't want to retain files read there.
                filteredDeleted:Add(uri)
            end
        end
        change.deleted = filteredDeleted
    end

    if change.changed:Len() > 0 then
        local filteredChanged = collections.NewSet()
        for uri in pairs(project.setKeys(change.changed)) do
            if self:isRelevantFileName(uri, contentMapperExtensions, contentMapperWatchedFiles) then
                filteredChanged:Add(uri)
            end
        end
        change.changed = filteredChanged
    end

    -- We can't filter created events because any created path could be a directory symlink
    -- that includes relevant files. configFileRegistryBuilder will do check if these paths
    -- are directories if they fall within a config's wildcard directories.

    return change
end

-- isNodeModulesPath reports whether path is a node_modules directory itself or
-- lives inside one. Used to preserve node_modules watch deletions, whose package
-- files are read transiently and therefore never tracked in diskDirectories.
function project.isNodeModulesPath(path)
    return project.hasSuffix(path, "/node_modules") or project.contains(path, "/node_modules/")
end

-- collectFilesRecursive recursively collects all cached file URIs under the
-- given directory path using the diskDirectories and diskFiles maps.
function snapshotFSBuilder:collectFilesRecursive(dirPath, files)
    local dirEntry, ok = self.diskDirectories:Get(dirPath)
    if not ok then
        return
    end
    for _, childPath in ipairs(project.sortedKeys(dirEntry:Value())) do
        local entry, ok2 = self.diskFiles:Load(childPath)
        if ok2 then
            local file = entry:Value()
            if file ~= nil then
                files:Add(lsconv.FileNameToDocumentURI(file:FileName()))
            end
        end
        self:collectFilesRecursive(childPath, files)
    end
end

function snapshotFSBuilder:convertOpenAndCloseToChanges(change)
    change = project.copyFileChangeSummary(change)
    if change.opened ~= "" and not tspath.IsDynamicFileName(lsproto.DocumentUri_FileName(change.opened)) then
        local path = self.toPath(lsproto.DocumentUri_FileName(change.opened))
        local entry, ok = self.diskFiles:Load(path)
        if not ok or entry:Original() == nil then
            change.created:Add(change.opened)
        else
            local overlay = self.overlays[path]
            if overlay ~= nil then
                -- The file already exists in the program, but the overlay content from
                -- didOpen may differ from what was originally read from disk (e.g. the
                -- editor normalizes line endings, or the file changed on disk since the
                -- project was loaded). Mark it as Changed so the project rebuilds.
                local df = entry:Original()
                if df ~= nil and overlay:Hash() ~= df:Hash() then
                    change.changed:Add(change.opened)
                end
            end
        end
    end
    for _, uri in ipairs(project.sortedKeys(project.setKeys(change.closed))) do
        local fileName = lsproto.DocumentUri_FileName(uri)
        if tspath.IsDynamicFileName(fileName) then
            goto continue
        end
        do
            local path = self.toPath(fileName)
            -- We may have ignored watcher events while the file was open, so force a reload.
            local fh = self:getDiskFile(fileName, path, true)
            if fh ~= nil then
                local prev = self.prevOverlays ~= nil and self.prevOverlays[path] or nil
                if prev == nil or fh:Hash() ~= prev:Hash() then
                    change.changed:Add(uri)
                end
                goto continue
            end
            change.deleted:Add(uri)
        end
        ::continue::
    end
    return change
end

-- sourceFS is a vfs.FS that sources files from a FileSource and tracks seen files.
local sourceFS = {}
sourceFS.__index = sourceFS
project.sourceFS = sourceFS

function project.newSourceFS(tracking, source, toPath)
    local fs = setmetatable({
        tracking = tracking,
        toPath = toPath,
        missingDirectories = nil,
        seenFiles = nil,
        source = source,
    }, sourceFS)
    if tracking then
        fs.seenFiles = collections.NewSyncSet()
        fs.missingDirectories = collections.NewSyncSet()
    end
    return fs
end

function sourceFS:DisableTracking()
    self.tracking = false
end

function sourceFS:Track(fileName)
    if not self.tracking then
        return
    end
    self.seenFiles:Add(self.toPath(fileName))
end

function sourceFS:SeenFile(path)
    if self.seenFiles == nil then
        return false
    end
    return self.seenFiles:Has(path)
end

function sourceFS:SeenFileOrMissingParentDirectory(path)
    if self.seenFiles ~= nil and self.seenFiles:Has(path) then
        return true
    end
    if self.missingDirectories ~= nil and not self.missingDirectories:IsEmpty() then
        while true do
            if self.missingDirectories:Has(path) then
                return true
            end

            local parent = tspath.Path_GetDirectoryPath(path)
            if parent == path then
                break
            end
            path = parent
        end
    end
    return false
end

function sourceFS:GetFile(fileName)
    self:Track(fileName)
    return self.source:GetFile(fileName)
end

function sourceFS:GetFileByPath(fileName, path)
    self:Track(fileName)
    return self.source:GetFileByPath(fileName, path)
end

-- DirectoryExists implements vfs.FS.
function sourceFS:DirectoryExists(path)
    local exists = self.source:FS():DirectoryExists(path)
    if not exists and self.tracking then
        self.missingDirectories:Add(self.toPath(path))
    end
    return exists
end

-- FileExists implements vfs.FS.
function sourceFS:FileExists(path)
    self:Track(path)
    return self.source:FileExists(path, self.toPath(path))
end

-- GetAccessibleEntries implements vfs.FS.
function sourceFS:GetAccessibleEntries(path)
    return self.source:GetAccessibleEntries(path)
end

-- ReadFile implements vfs.FS. Returns (contents, ok).
function sourceFS:ReadFile(path)
    local fh = self:GetFile(path)
    if fh ~= nil then
        return fh:Content(), true
    end
    return "", false
end

-- Realpath implements vfs.FS.
function sourceFS:Realpath(path)
    return self.source:FS():Realpath(path)
end

-- Stat implements vfs.FS.
function sourceFS:Stat(path)
    return self.source:FS():Stat(path)
end

-- UseCaseSensitiveFileNames implements vfs.FS.
function sourceFS:UseCaseSensitiveFileNames()
    return self.source:FS():UseCaseSensitiveFileNames()
end

-- WalkDir implements vfs.FS.
function sourceFS:WalkDir(root, walkFn)
    return self.source:FS():WalkDir(root, walkFn)
end

-- WriteFile implements vfs.FS.
function sourceFS:WriteFile(path, data)
    error("unimplemented", 0)
end

-- AppendFile implements vfs.FS.
function sourceFS:AppendFile(path, data)
    error("unimplemented", 0)
end

-- Remove implements vfs.FS.
function sourceFS:Remove(path)
    error("unimplemented", 0)
end

-- Chtimes implements vfs.FS.
function sourceFS:Chtimes(path, atime, mtime)
    error("unimplemented", 0)
end

function project.readDirectoryIntoEntries(directories, isFile, entries)
    for _, childPath in ipairs(project.sortedKeys(directories)) do
        local childName = directories[childPath]
        if isFile(childPath) then
            entries.files = entries.files or {}
            entries.files[#entries.files + 1] = childName
        else
            entries.directories = entries.directories or {}
            entries.directories[#entries.directories + 1] = childName
        end
    end
end
