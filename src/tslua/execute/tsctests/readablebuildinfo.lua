-- The readable structs marshal by hand (MarshalJSON in Go struct field order, honoring `omitzero`),
-- like tslua.execute.incremental's BuildInfo.
local tsctests = require("tslua.execute.tsctests")
local collections = require("tslua.collections")
local core = require("tslua.core")
local json = require("tslua.json")

local function incremental()
    return require("tslua.execute.incremental")
end

local function marshal(v)
    local s, err = json.Marshal(v)
    if err ~= nil then
        error("readableBuildInfo: failed to marshal: " .. tostring(err), 0)
    end
    return s
end

-- A value whose JSON encoding is the raw string s.
local rawJSON = {}
rawJSON.__index = rawJSON

function rawJSON:MarshalJSON()
    return self.raw, nil
end

local function raw(s)
    return setmetatable({ raw = s }, rawJSON)
end

-- members: array of { name, value, omit }. Encodes an object in member order.
local function marshalObject(members)
    local parts = {}
    for _, m in ipairs(members) do
        if not m[3] then
            parts[#parts + 1] = json.QuoteString(m[1]) .. ":" .. marshal(m[2])
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- JSON array of a Lua array (Go slice; nil -> null).
local function marshalArray(arr)
    if arr == nil then
        return "null"
    end
    local parts = {}
    for i, v in ipairs(arr) do
        parts[i] = marshal(v)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function arrayValue(arr)
    return raw(marshalArray(arr))
end

local function newClass()
    local c = {}
    c.__index = c
    return c
end

local readableBuildInfo = newClass()
tsctests.readableBuildInfo = readableBuildInfo

function readableBuildInfo:MarshalJSON()
    return marshalObject({
        { "version", self.version, self.version == "" },
        -- Common between incremental and tsc -b buildinfo for non incremental programs
        { "errors", self.errors, not self.errors },
        { "checkPending", self.checkPending, not self.checkPending },
        { "root", arrayValue(self.root), self.root == nil },
        { "packageJsons", arrayValue(self.packageJsons), self.packageJsons == nil },
        { "missingPackageJsons", arrayValue(self.missingPackageJsons), self.missingPackageJsons == nil },
        -- IncrementalProgram info
        { "fileNames", arrayValue(self.fileNames), self.fileNames == nil },
        { "fileInfos", arrayValue(self.fileInfos), self.fileInfos == nil },
        { "fileIdsList", raw(self.fileIdsList ~= nil and marshalArray(core.Map(self.fileIdsList, arrayValue)) or "null"), self.fileIdsList == nil },
        { "options", self.options, self.options == nil },
        { "referencedMap", self.referencedMap, self.referencedMap == nil },
        { "semanticDiagnosticsPerFile", arrayValue(self.semanticDiagnosticsPerFile), self.semanticDiagnosticsPerFile == nil },
        { "emitDiagnosticsPerFile", arrayValue(self.emitDiagnosticsPerFile), self.emitDiagnosticsPerFile == nil },
        { "changeFileSet", arrayValue(self.changeFileSet), self.changeFileSet == nil }, -- List of changed files in the program, not the whole set of files
        { "affectedFilesPendingEmit", arrayValue(self.affectedFilesPendingEmit), self.affectedFilesPendingEmit == nil },
        { "latestChangedDtsFile", self.latestChangedDtsFile, self.latestChangedDtsFile == "" }, -- Because this is only output file in the program, we dont need fileId to deduplicate name
        { "emitSignatures", arrayValue(self.emitSignatures), self.emitSignatures == nil },
        { "resolvedRoot", arrayValue(self.resolvedRoot), self.resolvedRoot == nil },
        { "size", self.size, self.size == 0 }, -- Size of the build info file
        -- NonIncrementalProgram info
        { "semanticErrors", self.semanticErrors, not self.semanticErrors },
    }), nil
end

-- readableBuildInfoRoot: { files, original (*incremental.BuildInfoRoot) }
local readableBuildInfoRoot = newClass()
tsctests.readableBuildInfoRoot = readableBuildInfoRoot

function readableBuildInfoRoot:MarshalJSON()
    return marshalObject({
        { "files", arrayValue(self.files), self.files == nil },
        { "original", self.original, self.original == nil },
    }), nil
end

-- readableBuildInfoFileInfo: { fileName, version, signature, affectsGlobalScope, impliedNodeFormat,
--   original (*incremental.BuildInfoFileInfo: Original file path, if available) }
local readableBuildInfoFileInfo = newClass()
tsctests.readableBuildInfoFileInfo = readableBuildInfoFileInfo

function readableBuildInfoFileInfo:MarshalJSON()
    return marshalObject({
        { "fileName", self.fileName, self.fileName == "" },
        { "version", self.version, self.version == "" },
        { "signature", self.signature, self.signature == "" },
        { "affectsGlobalScope", self.affectsGlobalScope, not self.affectsGlobalScope },
        { "impliedNodeFormat", self.impliedNodeFormat, self.impliedNodeFormat == "" },
        { "original", self.original, self.original == nil },
    }), nil
end

-- readableBuildInfoDiagnostic: { file (incrementalBuildInfoFileId if it is for a File thats other than its
--   stored for), noFile, pos, end_, code, category, messageKey, messageArgs, messageChain,
--   relatedInformation, reportsUnnecessary, reportsDeprecated, skippedOnNoEmit, repopulateInfo }
local readableBuildInfoDiagnostic = newClass()
tsctests.readableBuildInfoDiagnostic = readableBuildInfoDiagnostic

function readableBuildInfoDiagnostic:MarshalJSON()
    return marshalObject({
        { "file", self.file, self.file == "" },
        { "noFile", self.noFile, not self.noFile },
        { "pos", self.pos, self.pos == 0 },
        { "end", self.end_, self.end_ == 0 },
        { "code", self.code, self.code == 0 },
        { "category", self.category, self.category == 0 },
        { "messageKey", self.messageKey, self.messageKey == "" },
        { "messageArgs", arrayValue(self.messageArgs), self.messageArgs == nil },
        { "messageChain", arrayValue(self.messageChain), self.messageChain == nil },
        { "relatedInformation", arrayValue(self.relatedInformation), self.relatedInformation == nil },
        { "reportsUnnecessary", self.reportsUnnecessary, not self.reportsUnnecessary },
        { "reportsDeprecated", self.reportsDeprecated, not self.reportsDeprecated },
        { "skippedOnNoEmit", self.skippedOnNoEmit, not self.skippedOnNoEmit },
        { "repopulateInfo", self.repopulateInfo, self.repopulateInfo == nil },
    }), nil
end

-- readableBuildInfoRepopulateInfo: { kind, moduleReference, mode, packageName }
local readableBuildInfoRepopulateInfo = newClass()
tsctests.readableBuildInfoRepopulateInfo = readableBuildInfoRepopulateInfo

function readableBuildInfoRepopulateInfo:MarshalJSON()
    return marshalObject({
        { "kind", self.kind, false },
        { "moduleReference", self.moduleReference, self.moduleReference == "" },
        { "mode", self.mode, self.mode == 0 },
        { "packageName", self.packageName, self.packageName == "" },
    }), nil
end

-- readableBuildInfoDiagnosticsOfFile: { file, diagnostics }
local readableBuildInfoDiagnosticsOfFile = newClass()
tsctests.readableBuildInfoDiagnosticsOfFile = readableBuildInfoDiagnosticsOfFile

function readableBuildInfoDiagnosticsOfFile:MarshalJSON()
    return "[" .. marshal(self.file) .. "," .. marshalArray(self.diagnostics) .. "]", nil
end

-- readableBuildInfoSemanticDiagnostic: { file (File is not in changedSet and still doesnt have cached
--   diagnostics), diagnostics (Diagnostics for file) }
local readableBuildInfoSemanticDiagnostic = newClass()
tsctests.readableBuildInfoSemanticDiagnostic = readableBuildInfoSemanticDiagnostic

function readableBuildInfoSemanticDiagnostic:MarshalJSON()
    if self.file ~= "" then
        return marshal(self.file), nil
    end
    return marshal(self.diagnostics), nil
end

-- readableBuildInfoFilePendingEmit: { file, emitKind, original }
local readableBuildInfoFilePendingEmit = newClass()
tsctests.readableBuildInfoFilePendingEmit = readableBuildInfoFilePendingEmit

function readableBuildInfoFilePendingEmit:MarshalJSON()
    return "[" .. marshal(self.file) .. "," .. marshal(self.emitKind) .. "," .. marshal(self.original) .. "]", nil
end

-- readableBuildInfoEmitSignature: { file, signature, differsOnlyInDtsMap, differsInOptions, original }
local readableBuildInfoEmitSignature = newClass()
tsctests.readableBuildInfoEmitSignature = readableBuildInfoEmitSignature

function readableBuildInfoEmitSignature:MarshalJSON()
    return marshalObject({
        { "file", self.file, self.file == "" },
        { "signature", self.signature, self.signature == "" },
        { "differsOnlyInDtsMap", self.differsOnlyInDtsMap, not self.differsOnlyInDtsMap },
        { "differsInOptions", self.differsInOptions, not self.differsInOptions },
        { "original", self.original, self.original == nil },
    }), nil
end

-- readableBuildInfoResolvedRoot: { resolved, root }
local readableBuildInfoResolvedRoot = newClass()
tsctests.readableBuildInfoResolvedRoot = readableBuildInfoResolvedRoot

function readableBuildInfoResolvedRoot:MarshalJSON()
    return marshal({ self.resolved, self.root }), nil
end

function tsctests.toReadableBuildInfo(buildInfo, buildInfoText)
    local readable = setmetatable({
        buildInfo = buildInfo,
        version = buildInfo.version,
        errors = buildInfo.errors,
        checkPending = buildInfo.checkPending,
        fileNames = buildInfo.fileNames,
        options = buildInfo.options,
        latestChangedDtsFile = buildInfo.latestChangedDtsFile,
        semanticErrors = buildInfo.semanticErrors,
        packageJsons = buildInfo.packageJsons,
        missingPackageJsons = buildInfo.missingPackageJsons,
        size = #buildInfoText,
    }, readableBuildInfo)
    readable:setFileInfos()
    readable:setRoot()
    readable:setFileIdsList()
    readable:setReferencedMap()
    readable:setChangeFileSet()
    readable:setSemanticDiagnostics()
    readable:setEmitDiagnostics()
    readable:setAffectedFilesPendingEmit()
    readable:setEmitSignatures()
    readable:setResolvedRoot()
    local contents, err = json.MarshalIndent(readable, "", "  ")
    if err ~= nil then
        error("readableBuildInfo: failed to marshal readable build info: " .. tostring(err), 0)
    end
    return contents
end

function readableBuildInfo:toFilePath(fileId)
    return self.buildInfo.fileNames[fileId]
end

function readableBuildInfo:toFilePathSet(fileIdListId)
    return self.fileIdsList[fileIdListId]
end

function readableBuildInfo:toReadableBuildInfoDiagnostic(diags)
    return core.Map(diags, function(d)
        local file = ""
        if d.file ~= 0 then
            file = self:toFilePath(d.file)
        end
        return setmetatable({
            file = file,
            noFile = d.noFile,
            pos = d.pos,
            end_ = d.end_,
            code = d.code,
            category = d.category,
            messageKey = d.messageKey,
            messageArgs = d.messageArgs,
            messageChain = self:toReadableBuildInfoDiagnostic(d.messageChain),
            relatedInformation = self:toReadableBuildInfoDiagnostic(d.relatedInformation),
            reportsUnnecessary = d.reportsUnnecessary,
            reportsDeprecated = d.reportsDeprecated,
            skippedOnNoEmit = d.skippedOnNoEmit,
            repopulateInfo = tsctests.toReadableBuildInfoRepopulateInfo(d.repopulateInfo),
        }, readableBuildInfoDiagnostic)
    end)
end

function tsctests.toReadableBuildInfoRepopulateInfo(info)
    if info == nil then
        return nil
    end
    return setmetatable({
        kind = info.kind,
        moduleReference = info.moduleReference,
        mode = info.mode,
        packageName = info.packageName,
    }, readableBuildInfoRepopulateInfo)
end

function readableBuildInfo:toReadableBuildInfoDiagnosticsOfFile(diags)
    return setmetatable({
        file = self:toFilePath(diags.fileId),
        diagnostics = self:toReadableBuildInfoDiagnostic(diags.diagnostics),
    }, readableBuildInfoDiagnosticsOfFile)
end

function readableBuildInfo:setFileInfos()
    self.fileInfos = core.MapIndex(self.buildInfo.fileInfos, function(original, index)
        local fileInfo = original:GetFileInfo()
        -- Dont set original for string encoding
        if original:HasSignature() then
            original = nil
        end
        return setmetatable({
            fileName = self:toFilePath(index + 1),
            version = fileInfo:Version(),
            signature = fileInfo:Signature(),
            affectsGlobalScope = fileInfo:AffectsGlobalScope(),
            impliedNodeFormat = core.ModuleKind_String(fileInfo:ImpliedNodeFormat()),
            original = original,
        }, readableBuildInfoFileInfo)
    end)
end

function readableBuildInfo:setRoot()
    self.root = core.Map(self.buildInfo.root, function(original)
        local files
        if original.nonIncremental ~= "" then
            files = { original.nonIncremental }
        elseif original.end_ == 0 then
            files = { self:toFilePath(original.start) }
        else
            files = {}
            for i = original.start, original.end_ do
                files[#files + 1] = self:toFilePath(i)
            end
        end
        return setmetatable({
            files = files,
            original = original,
        }, readableBuildInfoRoot)
    end)
end

function readableBuildInfo:setFileIdsList()
    self.fileIdsList = core.Map(self.buildInfo.fileIdsList, function(ids)
        return core.Map(ids, function(id)
            return self:toFilePath(id)
        end)
    end)
end

function readableBuildInfo:setReferencedMap()
    if self.buildInfo.referencedMap ~= nil then
        self.referencedMap = collections.NewOrderedMapWithSizeHint(0)
        for _, entry in ipairs(self.buildInfo.referencedMap) do
            self.referencedMap:Set(self:toFilePath(entry.fileId), arrayValue(self:toFilePathSet(entry.fileIdListId)))
        end
    end
end

function readableBuildInfo:setChangeFileSet()
    self.changeFileSet = core.Map(self.buildInfo.changeFileSet, function(id)
        return self:toFilePath(id)
    end)
end

function readableBuildInfo:setSemanticDiagnostics()
    self.semanticDiagnosticsPerFile = core.Map(self.buildInfo.semanticDiagnosticsPerFile, function(diags)
        if diags.fileId ~= 0 then
            return setmetatable({
                file = self:toFilePath(diags.fileId),
            }, readableBuildInfoSemanticDiagnostic)
        end
        return setmetatable({
            file = "",
            diagnostics = self:toReadableBuildInfoDiagnosticsOfFile(diags.diagnostics),
        }, readableBuildInfoSemanticDiagnostic)
    end)
end

function readableBuildInfo:setEmitDiagnostics()
    self.emitDiagnosticsPerFile = core.Map(self.buildInfo.emitDiagnosticsPerFile, function(d)
        return self:toReadableBuildInfoDiagnosticsOfFile(d)
    end)
end

function readableBuildInfo:setAffectedFilesPendingEmit()
    if self.buildInfo.affectedFilesPendingEmit == nil then
        return
    end
    local fullEmitKind = incremental().GetFileEmitKind(self.buildInfo:GetCompilerOptions(""))
    self.affectedFilesPendingEmit = core.Map(self.buildInfo.affectedFilesPendingEmit, function(pendingEmit)
        local emitKind = core.IfElse(pendingEmit.emitKind == 0, fullEmitKind, pendingEmit.emitKind)
        return setmetatable({
            file = self:toFilePath(pendingEmit.fileId),
            emitKind = tsctests.toReadableFileEmitKind(emitKind),
            original = pendingEmit,
        }, readableBuildInfoFilePendingEmit)
    end)
end

function tsctests.toReadableFileEmitKind(fileEmitKind)
    local FileEmitKind = incremental().FileEmitKind
    local builder = {}
    local function addFlags(flags)
        if #builder == 0 then
            builder[#builder + 1] = flags
        else
            builder[#builder + 1] = "|"
            builder[#builder + 1] = flags
        end
    end
    if fileEmitKind ~= 0 then
        if (fileEmitKind & FileEmitKind.Js) ~= 0 then
            addFlags("Js")
        end
        if (fileEmitKind & FileEmitKind.JsMap) ~= 0 then
            addFlags("JsMap")
        end
        if (fileEmitKind & FileEmitKind.JsInlineMap) ~= 0 then
            addFlags("JsInlineMap")
        end
        if (fileEmitKind & FileEmitKind.Dts) == FileEmitKind.Dts then
            addFlags("Dts")
        else
            if (fileEmitKind & FileEmitKind.DtsEmit) ~= 0 then
                addFlags("DtsEmit")
            end
            if (fileEmitKind & FileEmitKind.DtsErrors) ~= 0 then
                addFlags("DtsErrors")
            end
        end
        if (fileEmitKind & FileEmitKind.DtsMap) ~= 0 then
            addFlags("DtsMap")
        end
    end
    if #builder ~= 0 then
        return table.concat(builder)
    end
    return "None"
end

function readableBuildInfo:setEmitSignatures()
    self.emitSignatures = core.Map(self.buildInfo.emitSignatures, function(signature)
        return setmetatable({
            file = self:toFilePath(signature.fileId),
            signature = signature.signature,
            differsOnlyInDtsMap = signature.differsOnlyInDtsMap,
            differsInOptions = signature.differsInOptions,
            original = signature,
        }, readableBuildInfoEmitSignature)
    end)
end

function readableBuildInfo:setResolvedRoot()
    self.resolvedRoot = core.Map(self.buildInfo.resolvedRoot, function(original)
        return setmetatable({
            resolved = self:toFilePath(original.resolved),
            root = self:toFilePath(original.root),
        }, readableBuildInfoResolvedRoot)
    end)
end
