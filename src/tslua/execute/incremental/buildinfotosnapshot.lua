local incremental = require("tslua.execute.incremental")
local collections = require("tslua.collections")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate
local isTrue = core.Tristate_IsTrue

local toSnapshot = {}
toSnapshot.__index = toSnapshot
incremental.toSnapshot = toSnapshot

function incremental.buildInfoToSnapshot(buildInfo, config, host)
    local to = setmetatable({
        buildInfo = buildInfo,
        buildInfoDirectory = tspath.GetDirectoryPath(tspath.GetNormalizedAbsolutePath(config:GetBuildInfoFileName(), config:GetCurrentDirectory())),
        snapshot = incremental.newSnapshot(),
        filePaths = {},
        filePathSet = {},
    }, toSnapshot)
    to.filePaths = core.Map(buildInfo.fileNames, function(fileName)
        if incremental.IsBuildInfoFileNameDefaultLibrary(fileName) then
            return tspath.ToPath(tspath.CombinePaths(host:DefaultLibraryPath(), fileName), host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames())
        end
        return tspath.ToPath(fileName, to.buildInfoDirectory, config:UseCaseSensitiveFileNames())
    end)
    to.filePathSet = core.Map(buildInfo.fileIdsList, function(fileIdList)
        local fileSet = collections.NewSetWithSizeHint(#fileIdList)
        for _, fileId in ipairs(fileIdList) do
            fileSet:Add(to:toFilePath(fileId))
        end
        return fileSet
    end)
    to:setCompilerOptions()
    to:setFileInfoAndEmitSignatures()
    to:setReferencedMap()
    to:setChangeFileSet()
    to:setSemanticDiagnostics()
    to:setEmitDiagnostics()
    to:setAffectedFilesPendingEmit()
    if buildInfo.latestChangedDtsFile ~= "" then
        to.snapshot.latestChangedDtsFile = to:toAbsolutePath(buildInfo.latestChangedDtsFile)
    end
    to.snapshot.hasErrors = core.IfElse(buildInfo.errors, Tristate.TSTrue, Tristate.TSFalse)
    to.snapshot.hasSemanticErrors = buildInfo.semanticErrors
    to.snapshot.checkPending = buildInfo.checkPending
    to:setPackageJsons()
    return to.snapshot
end

function toSnapshot:toAbsolutePath(path)
    return tspath.GetNormalizedAbsolutePath(path, self.buildInfoDirectory)
end

function toSnapshot:toFilePath(fileId)
    return self.filePaths[fileId]
end

function toSnapshot:toFilePathSet(fileIdListId)
    return self.filePathSet[fileIdListId]
end

function toSnapshot:toBuildInfoDiagnosticsWithFileName(diags)
    return core.Map(diags, function(d)
        local file = ""
        if d.file ~= 0 then
            file = self:toFilePath(d.file)
        end
        return incremental.newBuildInfoDiagnosticWithFileName({
            file = file,
            noFile = d.noFile,
            pos = d.pos,
            end_ = d.end_,
            code = d.code,
            category = d.category,
            source = d.source,
            messageText = d.messageText,
            messageKey = d.messageKey,
            messageArgs = d.messageArgs,
            messageChain = self:toBuildInfoDiagnosticsWithFileName(d.messageChain),
            relatedInformation = self:toBuildInfoDiagnosticsWithFileName(d.relatedInformation),
            reportsUnnecessary = d.reportsUnnecessary,
            reportsDeprecated = d.reportsDeprecated,
            skippedOnNoEmit = d.skippedOnNoEmit,
            repopulateInfo = incremental.fromBuildInfoRepopulateInfo(d.repopulateInfo),
        })
    end)
end

function toSnapshot:toDiagnosticsOrBuildInfoDiagnosticsWithFileName(dig)
    return incremental.newDiagnosticsOrBuildInfoDiagnosticsWithFileName(nil, self:toBuildInfoDiagnosticsWithFileName(dig.diagnostics))
end

function incremental.fromBuildInfoRepopulateInfo(info)
    if info == nil then
        return nil
    end
    return {
        kind = info.kind,
        moduleReference = info.moduleReference,
        mode = info.mode,
        packageName = info.packageName,
    }
end

function toSnapshot:setCompilerOptions()
    self.snapshot.options = self.buildInfo:GetCompilerOptions(self.buildInfoDirectory)
end

function toSnapshot:setFileInfoAndEmitSignatures()
    local isComposite = isTrue(self.snapshot.options.composite)
    for index1, buildInfoFileInfo in ipairs(self.buildInfo.fileInfos or {}) do
        local path = self:toFilePath(index1)
        local info = buildInfoFileInfo:GetFileInfo()
        self.snapshot.fileInfos:Store(path, info)
        -- Add default emit signature as file's signature
        if info.signature ~= "" and isComposite then
            self.snapshot.emitSignatures:Store(path, incremental.newEmitSignature(info.signature, nil))
        end
    end
    -- Fix up emit signatures
    for _, value in ipairs(self.buildInfo.emitSignatures or {}) do
        if value:noEmitSignature() then
            self.snapshot.emitSignatures:Delete(self:toFilePath(value.fileId))
        else
            local path = self:toFilePath(value.fileId)
            self.snapshot.emitSignatures:Store(path, value:toEmitSignature(path, self.snapshot.emitSignatures))
        end
    end
end

function toSnapshot:setReferencedMap()
    for _, entry in ipairs(self.buildInfo.referencedMap or {}) do
        self.snapshot.referencedMap:storeReferences(self:toFilePath(entry.fileId), self:toFilePathSet(entry.fileIdListId))
    end
end

function toSnapshot:setChangeFileSet()
    for _, fileId in ipairs(self.buildInfo.changeFileSet or {}) do
        local filePath = self:toFilePath(fileId)
        self.snapshot.changedFilesSet:Add(filePath)
    end
end

function toSnapshot:setSemanticDiagnostics()
    incremental.rangeSorted(self.snapshot.fileInfos, function(path, info)
        -- Initialize to have no diagnostics if its not changed file
        if not self.snapshot.changedFilesSet:Has(path) then
            self.snapshot.semanticDiagnosticsPerFile:Store(path, incremental.newDiagnosticsOrBuildInfoDiagnosticsWithFileName(nil, nil))
        end
        return true
    end)
    for _, diagnostic in ipairs(self.buildInfo.semanticDiagnosticsPerFile or {}) do
        if diagnostic.fileId ~= 0 then
            local filePath = self:toFilePath(diagnostic.fileId)
            self.snapshot.semanticDiagnosticsPerFile:Delete(filePath) -- does not have cached diagnostics
        else
            local filePath = self:toFilePath(diagnostic.diagnostics.fileId)
            self.snapshot.semanticDiagnosticsPerFile:Store(filePath, self:toDiagnosticsOrBuildInfoDiagnosticsWithFileName(diagnostic.diagnostics))
        end
    end
end

function toSnapshot:setEmitDiagnostics()
    for _, diagnostic in ipairs(self.buildInfo.emitDiagnosticsPerFile or {}) do
        local filePath = self:toFilePath(diagnostic.fileId)
        self.snapshot.emitDiagnosticsPerFile:Store(filePath, self:toDiagnosticsOrBuildInfoDiagnosticsWithFileName(diagnostic))
    end
end

function toSnapshot:setAffectedFilesPendingEmit()
    if core.Len(self.buildInfo.affectedFilesPendingEmit) == 0 then
        return
    end
    local ownOptionsEmitKind = incremental.GetFileEmitKind(self.snapshot.options)
    for _, pendingEmit in ipairs(self.buildInfo.affectedFilesPendingEmit) do
        self.snapshot.affectedFilesPendingEmit:Store(self:toFilePath(pendingEmit.fileId), core.IfElse(pendingEmit.emitKind == 0, ownOptionsEmitKind, pendingEmit.emitKind))
    end
end

function toSnapshot:setPackageJsons()
    if self.buildInfo.packageJsons ~= nil then
        self.snapshot.packageJsons = core.Map(self.buildInfo.packageJsons, function(p) return self:toAbsolutePath(p) end)
    else
        self.snapshot.packageJsons = {}
    end
    if self.buildInfo.missingPackageJsons ~= nil then
        self.snapshot.missingPackageJsons = core.Map(self.buildInfo.missingPackageJsons, function(p) return self:toAbsolutePath(p) end)
    else
        self.snapshot.missingPackageJsons = {}
    end
end
