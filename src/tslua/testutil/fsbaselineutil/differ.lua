local fsbaselineutil = require("tslua.testutil.fsbaselineutil")
local collections = require("tslua.collections")
local regexp = require("tslua.regexp")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

-- DiffEntry: { content = "", mTime = 0, isWritten = false, symlinkTarget = "" }
-- Snapshot: { snap = map path -> DiffEntry, defaultLibs = SyncSet }

-- FSDiffer: { fs = iovfs.FsWithSys, defaultLibs = func() -> SyncSet or nil, writtenFiles = SyncSet }
local FSDiffer = {}
FSDiffer.__index = FSDiffer
fsbaselineutil.FSDiffer = FSDiffer

function fsbaselineutil.NewFSDiffer(fields)
    return setmetatable({
        fs = fields.fs,
        defaultLibs = fields.defaultLibs,
        writtenFiles = fields.writtenFiles,
        serializedDiff = nil,
    }, FSDiffer)
end

function FSDiffer:MapFs()
    return self.fs:FSys()
end

function FSDiffer:SerializedDiff()
    return self.serializedDiff
end

function FSDiffer:BaselineFSwithDiff(baseline)
    -- todo: baselines the entire fs, possibly doesn't correctly diff all cases of emitted files, since emit isn't fully implemented and doesn't always emit the same way as strada
    local snap = {}

    local diffs = {}

    for path, file in self:MapFs():Entries() do
        if file.mode & iofs.ModeSymlink ~= 0 then
            local target, ok = self:MapFs():GetTargetOfSymlink(path)
            if not ok then
                error("Failed to resolve symlink target: " .. path, 0)
            end
            local newEntry = { content = "", mTime = 0, isWritten = false, symlinkTarget = target }
            snap[path] = newEntry
            self:addFsEntryDiff(diffs, newEntry, path)
        elseif iofs.FileMode_IsRegular(file.mode) then
            local content = fsbaselineutil.SanitizeInternalSymbolName(file.data)
            local newEntry = { content = content, mTime = file.modTime, isWritten = self.writtenFiles:Has(path), symlinkTarget = "" }
            snap[path] = newEntry
            self:addFsEntryDiff(diffs, newEntry, path)
        end
    end
    if self.serializedDiff ~= nil then
        for path in pairs(self.serializedDiff.snap) do
            local fileInfo = self:MapFs():GetFileInfo(path)
            if fileInfo == nil then
                -- report deleted
                self:addFsEntryDiff(diffs, nil, path)
            end
        end
    end
    local defaultLibs = collections.NewSyncSet()
    if self.defaultLibs ~= nil and self.defaultLibs() ~= nil then
        self.defaultLibs():Range(function(libPath)
            defaultLibs:Add(libPath)
            return true
        end)
    end
    self.serializedDiff = {
        snap = snap,
        defaultLibs = defaultLibs,
    }
    local diffKeys = {}
    for k in pairs(diffs) do
        diffKeys[#diffKeys + 1] = k
    end
    table.sort(diffKeys)
    for _, path in ipairs(diffKeys) do
        baseline:WriteString("//// [" .. path .. "] " .. diffs[path] .. "\n")
    end
    baseline:WriteString("\n")
    -- *d.WrittenFiles = collections.SyncSet[string]{}: reset the shared set in place
    self.writtenFiles.m = collections.NewSyncMap() -- Reset written files after baseline
end

fsbaselineutil.internalSymbolRegex = regexp.MustCompile("\\x{FFFD}@[^@]+@[0-9]+")

-- Replaces internal symbol names of shape \uFFFD@symbolName@123 with \uFFFD@symbolName@<symbolId>
-- // to avoid baselining differences in symbol ids, which can change between runs.
function fsbaselineutil.SanitizeInternalSymbolName(s)
    if not string.find(s, "\u{FFFD}@", 1, true) then
        return s
    end
    return fsbaselineutil.internalSymbolRegex:ReplaceAllStringFunc(s, function(match)
        local idStart = #match - #string.match(match, "@[^@]*$")
        return string.sub(match, 1, idStart) .. "@<symbolId>"
    end)
end

function FSDiffer:addFsEntryDiff(diffs, newDirContent, path)
    local oldDirContent
    local defaultLibs
    if self.serializedDiff ~= nil then
        oldDirContent = self.serializedDiff.snap[path]
        defaultLibs = self.serializedDiff.defaultLibs
    end
    -- todo handle more cases of fs changes
    if oldDirContent == nil then
        if self.defaultLibs == nil or self.defaultLibs() == nil or not self.defaultLibs():Has(path) then
            if newDirContent.symlinkTarget ~= "" then
                diffs[path] = "-> " .. newDirContent.symlinkTarget .. " *new*"
            else
                diffs[path] = "*new* \n" .. newDirContent.content
            end
        end
    elseif newDirContent == nil then
        diffs[path] = "*deleted*"
    elseif newDirContent.content ~= oldDirContent.content then
        diffs[path] = "*modified* \n" .. newDirContent.content
    elseif newDirContent.isWritten then
        diffs[path] = "*rewrite with same content*"
    elseif newDirContent.mTime ~= oldDirContent.mTime then
        diffs[path] = "*mTime changed*"
    elseif defaultLibs ~= nil and defaultLibs:Has(path) and self.defaultLibs ~= nil and self.defaultLibs() ~= nil and not self.defaultLibs():Has(path) then
        -- Lib file that was read
        diffs[path] = "*Lib*\n" .. newDirContent.content
    end
end

-- FileChange represents a filesystem change detected between snapshots.
-- { path = "", deleted = false }

function FSDiffer:ChangedPaths()
    if self.serializedDiff == nil then
        return nil
    end

    local changes = nil
    local oldSnap = self.serializedDiff

    -- Check current files against previous snapshot.
    for path, file in self:MapFs():Entries() do
        if file.mode & iofs.ModeSymlink ~= 0 or not iofs.FileMode_IsRegular(file.mode) then
            goto continue
        end
        do
            local old = oldSnap.snap[path]
            if old == nil then
                -- New file.
                changes = changes or {}
                changes[#changes + 1] = { path = path, deleted = false }
            elseif file.data ~= old.content or file.modTime ~= old.mTime then
                -- Modified or touched file.
                changes = changes or {}
                changes[#changes + 1] = { path = path, deleted = false }
            end
        end
        ::continue::
    end

    -- Check for deleted files.
    local oldPaths = {}
    for path in pairs(oldSnap.snap) do
        oldPaths[#oldPaths + 1] = path
    end
    table.sort(oldPaths)
    for _, path in ipairs(oldPaths) do
        local fileInfo = self:MapFs():GetFileInfo(path)
        if fileInfo == nil then
            changes = changes or {}
            changes[#changes + 1] = { path = path, deleted = true }
        end
    end

    return changes
end
