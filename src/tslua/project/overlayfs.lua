local project = require("tslua.project")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local sourcemap = require("tslua.sourcemap")
local spanmap = require("tslua.spanmap")
local tspath = require("tslua.tspath")

local FileChangeKind = project.FileChangeKind

-- FileContent: { Content() string, Hash() hash }
-- FileHandle: FileContent + FileName(), Version(), MatchesDiskText(), IsOverlay(), LSPLineMap(),
--   ECMALineInfo(), Kind()

-- fileBase: { fileName, content, hash, lineMap (memoized), lineInfo (memoized) }
local fileBase = {}
fileBase.__index = fileBase
project.fileBase = fileBase

function fileBase:FileName()
    return self.fileName
end

function fileBase:Hash()
    return self.hash
end

function fileBase:Content()
    return self.content
end

function fileBase:LSPLineMap()
    if self.lineMap == nil then
        self.lineMap = lsconv.ComputeLSPLineStarts(self.content)
    end
    return self.lineMap
end

function fileBase:ECMALineInfo()
    if self.lineInfo == nil then
        local lineStarts = core.ComputeECMALineStarts(self.content)
        self.lineInfo = sourcemap.CreateECMALineInfo(self.content, lineStarts)
    end
    return self.lineInfo
end

local diskFile = setmetatable({}, { __index = fileBase })
diskFile.__index = diskFile
project.diskFile = diskFile

-- newDiskFileStruct builds a diskFile literal; needsReload and realpathPath default to their zero values.
function project.newDiskFileStruct(fileName, content, hash, needsReload, realpathPath)
    return setmetatable({
        fileName = fileName,
        content = content or "",
        hash = hash or "",
        lineMap = nil,
        lineInfo = nil,
        needsReload = needsReload or false,
        realpathPath = realpathPath or "",
    }, diskFile)
end

function project.newDiskFile(fileName, content)
    return project.newDiskFileStruct(fileName, content, project.hashString(content))
end

function diskFile:Version()
    return 0
end

function diskFile:MatchesDiskText()
    return not self.needsReload
end

function diskFile:IsOverlay()
    return false
end

function diskFile:Kind()
    return core.GetScriptKindFromFileName(self.fileName)
end

function diskFile:Clone()
    return project.newDiskFileStruct(self.fileName, self.content, self.hash, false, self.realpathPath)
end

local Overlay = setmetatable({}, { __index = fileBase })
Overlay.__index = Overlay
project.Overlay = Overlay

function project.newOverlay(fileName, content, version, kind)
    return setmetatable({
        fileName = fileName,
        content = content,
        hash = project.hashString(content),
        lineMap = nil,
        lineInfo = nil,
        version = version,
        kind = kind,
        matchesDiskText = false,
    }, Overlay)
end

function Overlay:Version()
    return self.version
end

function Overlay:Text()
    return self.content
end

function Overlay:OriginalFileName()
    return self:FileName()
end

-- SpanMap and OriginalText satisfy lsconv.Script. An overlay holds the editor's raw text (for a
-- content-mapped file, that is the original foreign text, not the transformed output), so it never
-- carries a span map and its original text is its own text.
function Overlay:SpanMap()
    return nil
end

function Overlay:OriginalText()
    return self.content
end

-- MatchesDiskText may return false negatives, but never false positives.
function Overlay:MatchesDiskText()
    return self.matchesDiskText
end

-- !!! optimization: incorporate mtime
-- Returns (matchesDiskText, exists).
function Overlay:computeMatchesDiskText(fs)
    if tspath.IsDynamicFileName(self.fileName) then
        return false, false
    end
    local diskContent, ok = fs:ReadFile(self.fileName)
    if not ok then
        return false, false
    end
    return project.hashString(diskContent) == self.hash, true
end

function Overlay:IsOverlay()
    return true
end

function Overlay:Kind()
    return self.kind
end

local overlayFS = {}
overlayFS.__index = overlayFS
project.overlayFS = overlayFS

function project.newOverlayFS(fs, overlays, positionEncoding, toPath)
    return setmetatable({
        fs = fs,
        positionEncoding = positionEncoding,
        overlays = overlays,
        toPath = toPath,
    }, overlayFS)
end

function overlayFS:Overlays()
    return self.overlays
end

function overlayFS:getFile(fileName)
    local overlays = self.overlays

    local path = self.toPath(fileName)
    local overlay = overlays[path]
    if overlay ~= nil then
        return overlay
    end

    local content, ok = self.fs:ReadFile(fileName)
    if not ok then
        return nil
    end
    return project.newDiskFile(fileName, content)
end

-- processChanges returns (FileChangeSummary, overlays).
function overlayFS:processChanges(changes)
    local result = project.newFileChangeSummary()
    local newOverlays = project.cloneMap(self.overlays) or {}

    -- Reduced collection of changes that occurred on a single file
    -- fileEvents: { openChange, closeChange, watchChanged, changes, saved, created, deleted }

    -- Go iterates the map in random order; the port processes files in order of first event.
    local fileEventMap = {}
    local fileEventOrder = {}

    for _, change in ipairs(changes) do
        local uri = change.uri
        local events = fileEventMap[uri]
        if events ~= nil then
            if events.openChange ~= nil then
                error("should see no changes after open", 0)
            end
        else
            events = {
                openChange = nil,
                closeChange = nil,
                watchChanged = false,
                changes = nil,
                saved = false,
                created = false,
                deleted = false,
            }
            fileEventMap[uri] = events
            fileEventOrder[#fileEventOrder + 1] = uri
        end

        if not result.includesWatchChangeOutsideNodeModules and project.FileChangeKind_IsWatchKind(change.kind) and not project.contains(uri, "/node_modules/") then
            result.includesWatchChangeOutsideNodeModules = true
        end

        local kind = change.kind
        if kind == FileChangeKind.Open then
            if events.closeChange ~= nil then
                events.closeChange = nil
            end
            events.openChange = change
            events.watchChanged = false
            events.changes = nil
            events.saved = false
            events.created = false
            events.deleted = false
        elseif kind == FileChangeKind.Close then
            events.closeChange = change
            events.changes = nil
            events.saved = false
            events.watchChanged = false
        elseif kind == FileChangeKind.Change then
            if events.closeChange ~= nil then
                error("should see no changes after close", 0)
            end
            events.changes = events.changes or {}
            events.changes[#events.changes + 1] = change
            events.saved = false
            events.watchChanged = false
        elseif kind == FileChangeKind.Save then
            events.saved = true
        elseif kind == FileChangeKind.WatchCreate then
            if events.deleted then
                -- Delete followed by create becomes a change
                events.deleted = false
                events.watchChanged = true
            else
                events.created = true
            end
        elseif kind == FileChangeKind.WatchChange then
            if not events.created then
                events.watchChanged = true
                events.saved = false
            end
        elseif kind == FileChangeKind.WatchDelete then
            events.watchChanged = false
            events.saved = false
            -- Delete after create cancels out
            if events.created then
                events.created = false
            else
                events.deleted = true
            end
        end
    end

    -- Process deduplicated events per file
    for _, uri in ipairs(fileEventOrder) do
        local events = fileEventMap[uri]
        local path = lsproto.DocumentUri_Path(uri, self.fs:UseCaseSensitiveFileNames())
        local o = newOverlays[path]

        if events.openChange ~= nil then
            if result.opened ~= "" or result.reopened ~= "" then
                error("can only process one file open event at a time", 0)
            end
            if o ~= nil and o:Content() ~= events.openChange.content then
                result.changed:Add(uri)
            elseif o == nil then
                result.opened = uri
            else
                result.reopened = uri
            end
            local scriptKind = lsconv.LanguageKindToScriptKind(events.openChange.languageKind)
            if scriptKind == core.ScriptKind.Unknown then
                scriptKind = core.GetScriptKindFromFileName(lsproto.DocumentUri_FileName(uri))
            end
            newOverlays[path] = project.newOverlay(
                lsproto.DocumentUri_FileName(uri),
                events.openChange.content,
                events.openChange.version,
                scriptKind
            )
            goto continue
        end

        if events.closeChange ~= nil then
            if o == nil then
                error("overlay not found for closed file: " .. uri, 0)
            end
            result.closed:Add(uri)
            newOverlays[path] = nil
            o = nil
        end

        if events.watchChanged then
            if o == nil then
                result.changed:Add(uri)
            elseif o ~= nil and not events.saved then
                local matchesDiskText = o:computeMatchesDiskText(self.fs)
                if matchesDiskText ~= o:MatchesDiskText() then
                    o = project.newOverlay(o:FileName(), o:Content(), o:Version(), o.kind)
                    o.matchesDiskText = matchesDiskText
                    newOverlays[path] = o
                end
            end
        end

        if events.changes ~= nil and #events.changes > 0 then
            result.changed:Add(uri)
            if o == nil then
                error("overlay not found for changed file: " .. uri, 0)
            end
            for _, change in ipairs(events.changes) do
                local converters = lsconv.NewConverters(self.positionEncoding, function(fileName)
                    return o:LSPLineMap()
                end)
                for _, textChange in ipairs(change.changes or {}) do
                    local partialChange = textChange.partial
                    if partialChange ~= nil then
                        local ranges = lsconv.FromLSPRange(converters, o, partialChange.range, spanmap.Feature.All)
                        debug.Assert(#ranges == 1, "expected exactly one range for partial change")
                        local tc = core.NewTextChange(ranges[1].span, partialChange.text)
                        local newContent = tc:ApplyTo(o.content)
                        o = project.newOverlay(o.fileName, newContent, change.version, o.kind)
                    else
                        local wholeChange = textChange.wholeDocument
                        if wholeChange ~= nil then
                            o = project.newOverlay(o.fileName, wholeChange.text, change.version, o.kind)
                        end
                    end
                end
                if change.changes ~= nil and #change.changes > 0 then
                    o.version = change.version
                    o.hash = project.hashString(o.content)
                    o.matchesDiskText = false
                    newOverlays[path] = o
                end
            end
        end

        if events.saved then
            if o ~= nil then
                o = project.newOverlay(o:FileName(), o:Content(), o:Version(), o.kind)
                o.matchesDiskText = true
                newOverlays[path] = o
            elseif not events.watchChanged then
                -- File was saved but never opened via didOpen; treat as a disk change.
                result.changed:Add(uri)
            end
        end

        if events.created and o == nil then
            result.created:Add(uri)
        end

        if events.deleted and o == nil then
            result.deleted:Add(uri)
        end
        ::continue::
    end

    self.overlays = newOverlays
    return result, newOverlays
end
