-- The JSON (un)marshaling of the Go structs is written out by hand: Marshal* produce the exact
-- bytes of go-json-experiment for the struct field order and `omitzero` tags; UnmarshalJSON-like
-- decoders (incremental.decode*) take values produced by json.Unmarshal(data, { ordered = true })
-- (objects are collections.OrderedMap, numbers are floats) and raise a decode error (caught in
-- incremental.UnmarshalBuildInfo) when Go's decoder would fail.
local incremental = require("tslua.execute.incremental")
local collections = require("tslua.collections")
local core = require("tslua.core")
local json = require("tslua.json")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local FileEmitKind = incremental.FileEmitKind
local ResolutionModeCommonJS = core.ModuleKind.ResolutionModeCommonJS
local isTrue = core.Tristate_IsTrue

---- JSON helpers

-- A value whose JSON encoding is the raw string s.
local rawJSON = {}
rawJSON.__index = rawJSON

local function raw(s)
    return setmetatable({ raw = s }, rawJSON)
end

function rawJSON:MarshalJSON()
    return self.raw, nil
end

local function marshal(v)
    local s, err = json.Marshal(v)
    if err ~= nil then
        error({ marshalError = err }, 0)
    end
    return s
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

-- JSON array of the given Lua array (elements may have MarshalJSON). nil encodes as null.
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

local function decodeError(msg)
    error({ decodeError = msg }, 0)
end

local function isNull(v)
    return v == nil or v == json.Null
end

local function isObject(v)
    return getmetatable(v) == collections.OrderedMap
end

local function isArray(v)
    return type(v) == "table" and getmetatable(v) == nil
end

local function decodeInt(v)
    if isNull(v) then
        return 0
    end
    if type(v) ~= "number" then
        decodeError("cannot unmarshal into Go int")
    end
    local i = math.tointeger(v)
    if i == nil then
        decodeError("cannot unmarshal JSON number into Go int")
    end
    return i
end

local function decodeString(v)
    if isNull(v) then
        return ""
    end
    if type(v) ~= "string" then
        decodeError("cannot unmarshal into Go string")
    end
    return v
end

local function decodeBool(v)
    if isNull(v) then
        return false
    end
    if type(v) ~= "boolean" then
        decodeError("cannot unmarshal into Go bool")
    end
    return v
end

-- Go []T: null -> nil.
local function decodeSlice(v, decodeElement)
    if isNull(v) then
        return nil
    end
    if not isArray(v) then
        decodeError("cannot unmarshal into Go slice")
    end
    local result = {}
    for i, e in ipairs(v) do
        result[i] = decodeElement(e)
    end
    return result
end

local function decodeStruct(v)
    if isNull(v) then
        return nil
    end
    if not isObject(v) then
        decodeError("cannot unmarshal into Go struct")
    end
    return v
end

local function field(obj, name)
    if obj == nil then
        return nil
    end
    return (obj:Get(name))
end

-- Runs decode(v), returning (result, ok).
local function try(decode, v)
    local ok, result = pcall(decode, v)
    if ok then
        return result, true
    end
    if type(result) == "table" and result.decodeError ~= nil then
        return nil, false
    end
    error(result, 0)
end

local function decodeIntPair(v)
    if not isArray(v) or #v ~= 2 then
        decodeError("expected [2]int")
    end
    return { decodeInt(v[1]), decodeInt(v[2]) }
end

---- Types

-- buildInfoRoot is
-- - for incremental program buildinfo
--   - start and end of FileId for consecutive fileIds to be included as root
--   - start - single fileId that is root
--
-- - for non incremental program buildinfo
--   - string that is the root file name
local BuildInfoRoot = {}
BuildInfoRoot.__index = BuildInfoRoot
incremental.BuildInfoRoot = BuildInfoRoot

function incremental.NewBuildInfoRoot(fields)
    return setmetatable({
        start = fields.start or 0,
        end_ = fields.end_ or 0,
        nonIncremental = fields.nonIncremental or "", -- Root of a non incremental program
    }, BuildInfoRoot)
end

function BuildInfoRoot:MarshalJSON()
    if self.start ~= 0 then
        if self.end_ ~= 0 then
            return marshal({ self.start, self.end_ }), nil
        else
            return marshal(self.start), nil
        end
    else
        return marshal(self.nonIncremental), nil
    end
end

function incremental.decodeBuildInfoRoot(v)
    local startAndEnd, ok = try(function(x)
        if isNull(x) then
            return nil
        end
        return decodeIntPair(x)
    end, v)
    if not ok then
        local start
        start, ok = try(decodeInt, v)
        if not ok then
            local name
            name, ok = try(decodeString, v)
            if not ok then
                decodeError("invalid BuildInfoRoot")
            end
            return incremental.NewBuildInfoRoot({ nonIncremental = name })
        end
        return incremental.NewBuildInfoRoot({ start = start })
    end
    if startAndEnd == nil then
        decodeError("invalid BuildInfoRoot")
    end
    return incremental.NewBuildInfoRoot({ start = startAndEnd[1], end_ = startAndEnd[2] })
end

-- buildInfoFileInfoNoSignature: { version, noSignature, affectsGlobalScope, impliedNodeFormat }
function incremental.marshalBuildInfoFileInfoNoSignature(f)
    return marshalObject({
        { "version", f.version, f.version == "" },
        { "noSignature", f.noSignature, not f.noSignature },
        { "affectsGlobalScope", f.affectsGlobalScope, not f.affectsGlobalScope },
        { "impliedNodeFormat", f.impliedNodeFormat, f.impliedNodeFormat == 0 },
    })
end

--	 Signature is
--		 - undefined if FileInfo.version === FileInfo.signature
--		 - string actual signature
-- buildInfoFileInfoWithSignature: { version, signature, affectsGlobalScope, impliedNodeFormat }
function incremental.marshalBuildInfoFileInfoWithSignature(f)
    return marshalObject({
        { "version", f.version, f.version == "" },
        { "signature", f.signature, f.signature == "" },
        { "affectsGlobalScope", f.affectsGlobalScope, not f.affectsGlobalScope },
        { "impliedNodeFormat", f.impliedNodeFormat, f.impliedNodeFormat == 0 },
    })
end

local BuildInfoFileInfo = {}
BuildInfoFileInfo.__index = BuildInfoFileInfo
incremental.BuildInfoFileInfo = BuildInfoFileInfo

local function newBuildInfoFileInfoStruct(signature, noSignature, fileInfo)
    return setmetatable({
        signature = signature or "",
        noSignature = noSignature,
        fileInfo = fileInfo,
    }, BuildInfoFileInfo)
end

function incremental.newBuildInfoFileInfo(fileInfo)
    if fileInfo.version == fileInfo.signature then
        if not fileInfo.affectsGlobalScope and fileInfo.impliedNodeFormat == ResolutionModeCommonJS then
            return newBuildInfoFileInfoStruct(fileInfo.signature, nil, nil)
        end
    elseif fileInfo.signature == "" then
        return newBuildInfoFileInfoStruct("", {
            version = fileInfo.version,
            noSignature = true,
            affectsGlobalScope = fileInfo.affectsGlobalScope,
            impliedNodeFormat = fileInfo.impliedNodeFormat,
        }, nil)
    end
    return newBuildInfoFileInfoStruct("", nil, {
        version = fileInfo.version,
        signature = core.IfElse(fileInfo.signature == fileInfo.version, "", fileInfo.signature),
        affectsGlobalScope = fileInfo.affectsGlobalScope,
        impliedNodeFormat = fileInfo.impliedNodeFormat,
    })
end

function BuildInfoFileInfo:GetFileInfo()
    if self == nil then
        return nil
    end
    if self.signature ~= "" then
        return incremental.newFileInfo({
            version = self.signature,
            signature = self.signature,
            impliedNodeFormat = ResolutionModeCommonJS,
        })
    end
    if self.noSignature ~= nil then
        return incremental.newFileInfo({
            version = self.noSignature.version,
            affectsGlobalScope = self.noSignature.affectsGlobalScope,
            impliedNodeFormat = self.noSignature.impliedNodeFormat,
        })
    end
    return incremental.newFileInfo({
        version = self.fileInfo.version,
        signature = core.IfElse(self.fileInfo.signature == "", self.fileInfo.version, self.fileInfo.signature),
        affectsGlobalScope = self.fileInfo.affectsGlobalScope,
        impliedNodeFormat = self.fileInfo.impliedNodeFormat,
    })
end

function BuildInfoFileInfo:HasSignature()
    return self.signature ~= ""
end

function BuildInfoFileInfo:MarshalJSON()
    if self.signature ~= "" then
        return marshal(self.signature), nil
    end
    if self.noSignature ~= nil then
        return incremental.marshalBuildInfoFileInfoNoSignature(self.noSignature), nil
    end
    return incremental.marshalBuildInfoFileInfoWithSignature(self.fileInfo), nil
end

local function decodeFileInfoFields(v, withSignature)
    local obj = decodeStruct(v)
    local result = {
        version = decodeString(field(obj, "version")),
        affectsGlobalScope = decodeBool(field(obj, "affectsGlobalScope")),
        impliedNodeFormat = decodeInt(field(obj, "impliedNodeFormat")),
    }
    if withSignature then
        result.signature = decodeString(field(obj, "signature"))
    else
        result.noSignature = decodeBool(field(obj, "noSignature"))
    end
    return result
end

function incremental.decodeBuildInfoFileInfo(v)
    if isNull(v) then
        return nil
    end
    local vSignature, ok = try(decodeString, v)
    if not ok then
        local noSignature
        noSignature, ok = try(function(x) return decodeFileInfoFields(x, false) end, v)
        if not ok or not noSignature.noSignature then
            local fileInfo
            fileInfo, ok = try(function(x) return decodeFileInfoFields(x, true) end, v)
            if not ok then
                decodeError("invalid BuildInfoFileInfo")
            end
            return newBuildInfoFileInfoStruct("", nil, fileInfo)
        end
        return newBuildInfoFileInfoStruct("", noSignature, nil)
    end
    return newBuildInfoFileInfoStruct(vSignature, nil, nil)
end

local BuildInfoReferenceMapEntry = {}
BuildInfoReferenceMapEntry.__index = BuildInfoReferenceMapEntry
incremental.BuildInfoReferenceMapEntry = BuildInfoReferenceMapEntry

function incremental.NewBuildInfoReferenceMapEntry(fileId, fileIdListId)
    return setmetatable({ fileId = fileId, fileIdListId = fileIdListId }, BuildInfoReferenceMapEntry)
end

function BuildInfoReferenceMapEntry:MarshalJSON()
    return marshal({ self.fileId, self.fileIdListId }), nil
end

function incremental.decodeBuildInfoReferenceMapEntry(v)
    if isNull(v) then
        return nil
    end
    local pair = decodeIntPair(v)
    return incremental.NewBuildInfoReferenceMapEntry(pair[1], pair[2])
end

-- BuildInfoDiagnostic: { file (BuildInfoFileId if it is for a File thats other than its stored for),
-- noFile, pos, end_, code, category, source, messageText, messageKey, messageArgs, messageChain,
-- relatedInformation, reportsUnnecessary, reportsDeprecated, skippedOnNoEmit, repopulateInfo }
local BuildInfoDiagnostic = {}
BuildInfoDiagnostic.__index = BuildInfoDiagnostic
incremental.BuildInfoDiagnostic = BuildInfoDiagnostic

function incremental.NewBuildInfoDiagnostic(fields)
    return setmetatable({
        file = fields.file or 0,
        noFile = fields.noFile or false,
        pos = fields.pos or 0,
        end_ = fields.end_ or 0,
        code = fields.code or 0,
        category = fields.category or 0,
        source = fields.source or "",
        messageText = fields.messageText or "",
        messageKey = fields.messageKey or "",
        messageArgs = fields.messageArgs,
        messageChain = fields.messageChain,
        relatedInformation = fields.relatedInformation,
        reportsUnnecessary = fields.reportsUnnecessary or false,
        reportsDeprecated = fields.reportsDeprecated or false,
        skippedOnNoEmit = fields.skippedOnNoEmit or false,
        repopulateInfo = fields.repopulateInfo,
    }, BuildInfoDiagnostic)
end

function BuildInfoDiagnostic:MarshalJSON()
    return marshalObject({
        { "file", self.file, self.file == 0 },
        { "noFile", self.noFile, not self.noFile },
        { "pos", self.pos, self.pos == 0 },
        { "end", self.end_, self.end_ == 0 },
        { "code", self.code, self.code == 0 },
        { "category", self.category, self.category == 0 },
        { "source", self.source, self.source == "" },
        { "messageText", self.messageText, self.messageText == "" },
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

function incremental.decodeBuildInfoDiagnostic(v)
    local obj = decodeStruct(v)
    if obj == nil then
        return nil
    end
    return incremental.NewBuildInfoDiagnostic({
        file = decodeInt(field(obj, "file")),
        noFile = decodeBool(field(obj, "noFile")),
        pos = decodeInt(field(obj, "pos")),
        end_ = decodeInt(field(obj, "end")),
        code = decodeInt(field(obj, "code")),
        category = decodeInt(field(obj, "category")),
        source = decodeString(field(obj, "source")),
        messageText = decodeString(field(obj, "messageText")),
        messageKey = decodeString(field(obj, "messageKey")),
        messageArgs = decodeSlice(field(obj, "messageArgs"), decodeString),
        messageChain = decodeSlice(field(obj, "messageChain"), incremental.decodeBuildInfoDiagnostic),
        relatedInformation = decodeSlice(field(obj, "relatedInformation"), incremental.decodeBuildInfoDiagnostic),
        reportsUnnecessary = decodeBool(field(obj, "reportsUnnecessary")),
        reportsDeprecated = decodeBool(field(obj, "reportsDeprecated")),
        skippedOnNoEmit = decodeBool(field(obj, "skippedOnNoEmit")),
        repopulateInfo = incremental.decodeBuildInfoRepopulateInfo(field(obj, "repopulateInfo")),
    })
end

-- BuildInfoRepopulateInfo: { kind, moduleReference, mode, packageName }
local BuildInfoRepopulateInfo = {}
BuildInfoRepopulateInfo.__index = BuildInfoRepopulateInfo
incremental.BuildInfoRepopulateInfo = BuildInfoRepopulateInfo

function incremental.NewBuildInfoRepopulateInfo(fields)
    return setmetatable({
        kind = fields.kind or 0,
        moduleReference = fields.moduleReference or "",
        mode = fields.mode or 0,
        packageName = fields.packageName or "",
    }, BuildInfoRepopulateInfo)
end

function BuildInfoRepopulateInfo:MarshalJSON()
    return marshalObject({
        { "kind", self.kind, false },
        { "moduleReference", self.moduleReference, self.moduleReference == "" },
        { "mode", self.mode, self.mode == 0 },
        { "packageName", self.packageName, self.packageName == "" },
    }), nil
end

function incremental.decodeBuildInfoRepopulateInfo(v)
    local obj = decodeStruct(v)
    if obj == nil then
        return nil
    end
    return incremental.NewBuildInfoRepopulateInfo({
        kind = decodeInt(field(obj, "kind")),
        moduleReference = decodeString(field(obj, "moduleReference")),
        mode = decodeInt(field(obj, "mode")),
        packageName = decodeString(field(obj, "packageName")),
    })
end

-- BuildInfoDiagnosticsOfFile: { fileId, diagnostics }
local BuildInfoDiagnosticsOfFile = {}
BuildInfoDiagnosticsOfFile.__index = BuildInfoDiagnosticsOfFile
incremental.BuildInfoDiagnosticsOfFile = BuildInfoDiagnosticsOfFile

function incremental.NewBuildInfoDiagnosticsOfFile(fileId, diags)
    return setmetatable({ fileId = fileId, diagnostics = diags }, BuildInfoDiagnosticsOfFile)
end

function BuildInfoDiagnosticsOfFile:MarshalJSON()
    return "[" .. marshal(self.fileId) .. "," .. marshalArray(self.diagnostics) .. "]", nil
end

function incremental.decodeBuildInfoDiagnosticsOfFile(v)
    if isNull(v) then
        return nil
    end
    if not isArray(v) then
        decodeError("invalid BuildInfoDiagnosticsOfFile")
    end
    if #v ~= 2 then
        decodeError("invalid BuildInfoDiagnosticsOfFile: expected 2 elements")
    end
    local fileId = decodeInt(v[1])
    local diags = decodeSlice(v[2], incremental.decodeBuildInfoDiagnostic)
    return incremental.NewBuildInfoDiagnosticsOfFile(fileId, diags)
end

-- BuildInfoSemanticDiagnostic: { fileId (File is not in changedSet and still doesnt have cached
-- diagnostics), diagnostics (*BuildInfoDiagnosticsOfFile: Diagnostics for file) }
local BuildInfoSemanticDiagnostic = {}
BuildInfoSemanticDiagnostic.__index = BuildInfoSemanticDiagnostic
incremental.BuildInfoSemanticDiagnostic = BuildInfoSemanticDiagnostic

function incremental.NewBuildInfoSemanticDiagnostic(fileId, diags)
    return setmetatable({ fileId = fileId or 0, diagnostics = diags }, BuildInfoSemanticDiagnostic)
end

function BuildInfoSemanticDiagnostic:MarshalJSON()
    if self.fileId ~= 0 then
        return marshal(self.fileId), nil
    end
    return marshal(self.diagnostics), nil
end

function incremental.decodeBuildInfoSemanticDiagnostic(v)
    if isNull(v) then
        return nil
    end
    local fileId, ok = try(decodeInt, v)
    if not ok then
        local diags
        diags, ok = try(incremental.decodeBuildInfoDiagnosticsOfFile, v)
        if not ok then
            decodeError("invalid BuildInfoSemanticDiagnostic")
        end
        return incremental.NewBuildInfoSemanticDiagnostic(0, diags)
    end
    return incremental.NewBuildInfoSemanticDiagnostic(fileId, nil)
end

-- fileId if pending emit is same as what compilerOptions suggest
-- [fileId] if pending emit is only dts file emit
-- [fileId, emitKind] if any other type emit is pending
local BuildInfoFilePendingEmit = {}
BuildInfoFilePendingEmit.__index = BuildInfoFilePendingEmit
incremental.BuildInfoFilePendingEmit = BuildInfoFilePendingEmit

function incremental.NewBuildInfoFilePendingEmit(fileId, emitKind)
    return setmetatable({ fileId = fileId, emitKind = emitKind or 0 }, BuildInfoFilePendingEmit)
end

function BuildInfoFilePendingEmit:MarshalJSON()
    if self.emitKind == 0 then
        return marshal(self.fileId), nil
    end
    if self.emitKind == FileEmitKind.Dts then
        return marshal({ self.fileId }), nil
    end
    return marshal({ self.fileId, self.emitKind }), nil
end

function incremental.decodeBuildInfoFilePendingEmit(v)
    if isNull(v) then
        return nil
    end
    local fileId, ok = try(decodeInt, v)
    if not ok then
        local intTuple
        intTuple, ok = try(function(x) return decodeSlice(x, decodeInt) end, v)
        if not ok or intTuple == nil or #intTuple == 0 then
            decodeError("invalid BuildInfoFilePendingEmit")
        end
        if #intTuple == 1 then
            return incremental.NewBuildInfoFilePendingEmit(intTuple[1], FileEmitKind.Dts)
        elseif #intTuple == 2 then
            return incremental.NewBuildInfoFilePendingEmit(intTuple[1], intTuple[2])
        else
            decodeError("invalid BuildInfoFilePendingEmit: expected 1 or 2 integers")
        end
    end
    return incremental.NewBuildInfoFilePendingEmit(fileId, 0)
end

-- [fileId, signature] if different from file's signature
-- fileId if file wasnt emitted
-- BuildInfoEmitSignature: { fileId, signature (Signature if it is different from file's Signature),
-- differsOnlyInDtsMap (true if signature is different only in dtsMap value),
-- differsInOptions (true if signature is different in options used to emit file) }
local BuildInfoEmitSignature = {}
BuildInfoEmitSignature.__index = BuildInfoEmitSignature
incremental.BuildInfoEmitSignature = BuildInfoEmitSignature

function incremental.NewBuildInfoEmitSignature(fields)
    return setmetatable({
        fileId = fields.fileId or 0,
        signature = fields.signature or "",
        differsOnlyInDtsMap = fields.differsOnlyInDtsMap or false,
        differsInOptions = fields.differsInOptions or false,
    }, BuildInfoEmitSignature)
end

function BuildInfoEmitSignature:noEmitSignature()
    return self.signature == "" and not self.differsOnlyInDtsMap and not self.differsInOptions
end

function BuildInfoEmitSignature:toEmitSignature(path, emitSignatures)
    local signature = ""
    local signatureWithDifferentOptions = nil
    if self.differsOnlyInDtsMap then
        local info = emitSignatures:Load(path)
        signatureWithDifferentOptions = { info.signature }
    elseif self.differsInOptions then
        signatureWithDifferentOptions = { self.signature }
    else
        signature = self.signature
    end
    return incremental.newEmitSignature(signature, signatureWithDifferentOptions)
end

function BuildInfoEmitSignature:MarshalJSON()
    if self:noEmitSignature() then
        return marshal(self.fileId), nil
    end
    local signature
    if self.differsOnlyInDtsMap then
        signature = "[]"
    elseif self.differsInOptions then
        signature = "[" .. marshal(self.signature) .. "]"
    else
        signature = marshal(self.signature)
    end
    return "[" .. marshal(self.fileId) .. "," .. signature .. "]", nil
end

function incremental.decodeBuildInfoEmitSignature(v)
    if isNull(v) then
        return nil
    end
    local fileId, ok = try(decodeInt, v)
    if not ok then
        if not isArray(v) then
            decodeError("invalid BuildInfoEmitSignature")
        end
        if #v ~= 2 then
            decodeError("invalid BuildInfoEmitSignature: expected 2 elements")
        end
        if type(v[1]) ~= "number" then
            decodeError("invalid fileId in BuildInfoEmitSignature: expected float64")
        end
        fileId = math.tointeger(v[1]) or math.floor(v[1])
        local signature = ""
        local differsOnlyInDtsMap, differsInOptions = false, false
        if type(v[2]) ~= "string" then
            if not isArray(v[2]) then
                decodeError("invalid signature in BuildInfoEmitSignature: expected string or []string")
            end
            local signatureList = v[2]
            if #signatureList == 0 then
                differsOnlyInDtsMap = true
            elseif #signatureList == 1 then
                if type(signatureList[1]) ~= "string" then
                    decodeError("invalid signature in BuildInfoEmitSignature: expected string")
                end
                signature = signatureList[1]
                differsInOptions = true
            else
                decodeError("invalid signature in BuildInfoEmitSignature: expected string or []string with 0 or 1 element")
            end
        else
            signature = v[2]
        end
        return incremental.NewBuildInfoEmitSignature({
            fileId = fileId,
            signature = signature,
            differsOnlyInDtsMap = differsOnlyInDtsMap,
            differsInOptions = differsInOptions,
        })
    end
    return incremental.NewBuildInfoEmitSignature({ fileId = fileId })
end

local BuildInfoResolvedRoot = {}
BuildInfoResolvedRoot.__index = BuildInfoResolvedRoot
incremental.BuildInfoResolvedRoot = BuildInfoResolvedRoot

function incremental.NewBuildInfoResolvedRoot(resolved, root)
    return setmetatable({ resolved = resolved, root = root }, BuildInfoResolvedRoot)
end

function BuildInfoResolvedRoot:MarshalJSON()
    return marshal({ self.resolved, self.root }), nil
end

function incremental.decodeBuildInfoResolvedRoot(v)
    local ok, pair = pcall(decodeIntPair, v)
    if not ok then
        decodeError("invalid BuildInfoResolvedRoot")
    end
    return incremental.NewBuildInfoResolvedRoot(pair[1], pair[2])
end

-- BuildInfo. Slice fields are nil when Go's are nil (omitted from the JSON).
local BuildInfo = {}
BuildInfo.__index = BuildInfo
incremental.BuildInfo = BuildInfo

function incremental.NewBuildInfo(fields)
    fields = fields or {}
    return setmetatable({
        version = fields.version or "",

        -- Common between incremental and tsc -b buildinfo for non incremental programs
        errors = fields.errors or false,
        checkPending = fields.checkPending or false,
        root = fields.root,
        packageJsons = fields.packageJsons,
        missingPackageJsons = fields.missingPackageJsons,
        contentMapperIdentities = fields.contentMapperIdentities,

        -- IncrementalProgram info
        fileNames = fields.fileNames,
        fileInfos = fields.fileInfos,
        fileIdsList = fields.fileIdsList,
        options = fields.options,
        referencedMap = fields.referencedMap,
        semanticDiagnosticsPerFile = fields.semanticDiagnosticsPerFile,
        emitDiagnosticsPerFile = fields.emitDiagnosticsPerFile,
        changeFileSet = fields.changeFileSet,
        affectedFilesPendingEmit = fields.affectedFilesPendingEmit,
        latestChangedDtsFile = fields.latestChangedDtsFile or "", -- Because this is only output file in the program, we dont need fileId to deduplicate name
        emitSignatures = fields.emitSignatures,
        resolvedRoot = fields.resolvedRoot,

        -- NonIncrementalProgram info
        semanticErrors = fields.semanticErrors or false,
    }, BuildInfo)
end

function BuildInfo:MarshalJSON()
    local ok, result = pcall(function()
        return marshalObject({
            { "version", self.version, self.version == "" },
            { "errors", self.errors, not self.errors },
            { "checkPending", self.checkPending, not self.checkPending },
            { "root", arrayValue(self.root), self.root == nil },
            { "packageJsons", arrayValue(self.packageJsons), self.packageJsons == nil },
            { "missingPackageJsons", arrayValue(self.missingPackageJsons), self.missingPackageJsons == nil },
            { "contentMapperIdentities", arrayValue(self.contentMapperIdentities), self.contentMapperIdentities == nil },
            { "fileNames", arrayValue(self.fileNames), self.fileNames == nil },
            { "fileInfos", arrayValue(self.fileInfos), self.fileInfos == nil },
            { "fileIdsList", raw(self.fileIdsList ~= nil and marshalArray(core.Map(self.fileIdsList, arrayValue)) or "null"), self.fileIdsList == nil },
            { "options", self.options, self.options == nil },
            { "referencedMap", arrayValue(self.referencedMap), self.referencedMap == nil },
            { "semanticDiagnosticsPerFile", arrayValue(self.semanticDiagnosticsPerFile), self.semanticDiagnosticsPerFile == nil },
            { "emitDiagnosticsPerFile", arrayValue(self.emitDiagnosticsPerFile), self.emitDiagnosticsPerFile == nil },
            { "changeFileSet", arrayValue(self.changeFileSet), self.changeFileSet == nil },
            { "affectedFilesPendingEmit", arrayValue(self.affectedFilesPendingEmit), self.affectedFilesPendingEmit == nil },
            { "latestChangedDtsFile", self.latestChangedDtsFile, self.latestChangedDtsFile == "" },
            { "emitSignatures", arrayValue(self.emitSignatures), self.emitSignatures == nil },
            { "resolvedRoot", arrayValue(self.resolvedRoot), self.resolvedRoot == nil },
            { "semanticErrors", self.semanticErrors, not self.semanticErrors },
        })
    end)
    if not ok then
        if type(result) == "table" and result.marshalError ~= nil then
            return nil, result.marshalError
        end
        error(result, 0)
    end
    return result, nil
end

-- Go json.Unmarshal(data, &buildInfo). Returns (buildInfo, err).
function incremental.UnmarshalBuildInfo(data)
    local value, err = json.Unmarshal(data, { ordered = true })
    if err ~= nil then
        return nil, err
    end
    local ok, result = pcall(function()
        local obj = decodeStruct(value)
        if obj == nil then
            return incremental.NewBuildInfo()
        end
        local options = field(obj, "options")
        if isNull(options) then
            options = nil
        elseif not isObject(options) then
            decodeError("cannot unmarshal non-object JSON value into Map")
        end
        return incremental.NewBuildInfo({
            version = decodeString(field(obj, "version")),
            errors = decodeBool(field(obj, "errors")),
            checkPending = decodeBool(field(obj, "checkPending")),
            root = decodeSlice(field(obj, "root"), incremental.decodeBuildInfoRoot),
            packageJsons = decodeSlice(field(obj, "packageJsons"), decodeString),
            missingPackageJsons = decodeSlice(field(obj, "missingPackageJsons"), decodeString),
            contentMapperIdentities = decodeSlice(field(obj, "contentMapperIdentities"), decodeString),
            fileNames = decodeSlice(field(obj, "fileNames"), decodeString),
            fileInfos = decodeSlice(field(obj, "fileInfos"), incremental.decodeBuildInfoFileInfo),
            fileIdsList = decodeSlice(field(obj, "fileIdsList"), function(x)
                return decodeSlice(x, decodeInt)
            end),
            options = options,
            referencedMap = decodeSlice(field(obj, "referencedMap"), incremental.decodeBuildInfoReferenceMapEntry),
            semanticDiagnosticsPerFile = decodeSlice(field(obj, "semanticDiagnosticsPerFile"), incremental.decodeBuildInfoSemanticDiagnostic),
            emitDiagnosticsPerFile = decodeSlice(field(obj, "emitDiagnosticsPerFile"), incremental.decodeBuildInfoDiagnosticsOfFile),
            changeFileSet = decodeSlice(field(obj, "changeFileSet"), decodeInt),
            affectedFilesPendingEmit = decodeSlice(field(obj, "affectedFilesPendingEmit"), incremental.decodeBuildInfoFilePendingEmit),
            latestChangedDtsFile = decodeString(field(obj, "latestChangedDtsFile")),
            emitSignatures = decodeSlice(field(obj, "emitSignatures"), incremental.decodeBuildInfoEmitSignature),
            resolvedRoot = decodeSlice(field(obj, "resolvedRoot"), incremental.decodeBuildInfoResolvedRoot),
            semanticErrors = decodeBool(field(obj, "semanticErrors")),
        })
    end)
    if not ok then
        if type(result) == "table" and result.decodeError ~= nil then
            return nil, result.decodeError
        end
        error(result, 0)
    end
    return result, nil
end

function BuildInfo:IsValidVersion()
    return self.version == core.Version()
end

-- ContentMapperIdentities returns the project's sorted mapper transform identities. A nil project means
-- the compiler host has no configured content mappers. Returns (identities, err).
function incremental.ContentMapperIdentities(project)
    if project == nil then
        return nil, nil
    end
    return project:Identities()
end

-- ContentMapperIdentitiesMatch reports whether the content mapper identities recorded in this build info
-- match the given current identities (as produced by ContentMapperIdentities).
function BuildInfo:ContentMapperIdentitiesMatch(current)
    local a, b = self.contentMapperIdentities or {}, current or {}
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

function BuildInfo:IsIncremental()
    return self ~= nil and core.Len(self.fileNames) ~= 0
end

function incremental.IsBuildInfoFileNameDefaultLibrary(fileName)
    return not tspath.PathIsRelative(fileName) and not tspath.PathIsAbsolute(fileName)
end

function BuildInfo:fileName(fileId)
    if fileId < 1 or fileId > core.Len(self.fileNames) then
        return ""
    end
    return self.fileNames[fileId]
end

function BuildInfo:fileInfo(fileId)
    if fileId < 1 or fileId > core.Len(self.fileInfos) then
        return nil
    end
    return self.fileInfos[fileId]
end

function BuildInfo:GetCompilerOptions(buildInfoDirectory)
    local options = core.NewCompilerOptions()
    for option, value in collections.OrderedMap.Entries(self.options) do
        local done = false
        if buildInfoDirectory ~= "" then
            local result, ok = tsoptions.ConvertOptionToAbsolutePath(option, value, tsoptions.CommandLineCompilerOptionsMap, buildInfoDirectory)
            if ok then
                tsoptions.ParseCompilerOptions(option, result, options)
                done = true
            end
        end
        if not done then
            tsoptions.ParseCompilerOptions(option, value, options)
        end
    end
    return options
end

function BuildInfo:IsEmitPending(resolved, buildInfoDirectory)
    -- Some of the emit files like source map or dts etc are not yet done
    if not isTrue(resolved:CompilerOptions().noEmit) or resolved:CompilerOptions():GetEmitDeclarations() then
        local pendingEmit = incremental.getPendingEmitKindWithOptions(resolved:CompilerOptions(), self:GetCompilerOptions(buildInfoDirectory))
        if isTrue(resolved:CompilerOptions().noEmit) then
            pendingEmit = pendingEmit & FileEmitKind.DtsErrors
        end
        return pendingEmit ~= 0
    end
    return false
end

-- Returns a Lua iterator.
function BuildInfo:GetPackageJsons(buildInfoDirectory)
    return incremental.getNormalizedPaths(self.packageJsons, buildInfoDirectory)
end

-- Returns a Lua iterator.
function BuildInfo:GetMissingPackageJsons(buildInfoDirectory)
    return incremental.getNormalizedPaths(self.missingPackageJsons, buildInfoDirectory)
end

function incremental.getNormalizedPaths(paths, buildInfoDirectory)
    local i = 0
    return function()
        i = i + 1
        local path = paths ~= nil and paths[i] or nil
        if path == nil then
            return nil
        end
        return tspath.GetNormalizedAbsolutePath(path, buildInfoDirectory)
    end
end

function BuildInfo:GetBuildInfoRootInfoReader(buildInfoDirectory, comparePathOptions)
    local resolvedRootFileInfos = {}
    -- Roots of the File
    local rootToResolved = collections.NewOrderedMapWithSizeHint(core.Len(self.fileNames))
    local resolvedToRoot = {}
    local function toPath(fileName)
        return tspath.ToPath(fileName, buildInfoDirectory, comparePathOptions.useCaseSensitiveFileNames)
    end

    -- Create map from resolvedRoot to Root
    for _, resolved in ipairs(self.resolvedRoot or {}) do
        local resolvedRoot = self:fileName(resolved.resolved)
        local root = self:fileName(resolved.root)
        if resolvedRoot ~= "" and root ~= "" then
            resolvedToRoot[toPath(resolvedRoot)] = toPath(root)
        end
    end

    local function addRoot(resolvedRoot, fileInfo)
        if resolvedRoot == "" then
            return
        end
        local resolvedRootPath = toPath(resolvedRoot)
        local rootPath = resolvedToRoot[resolvedRootPath]
        if rootPath ~= nil then
            rootToResolved:Set(rootPath, resolvedRootPath)
        else
            rootToResolved:Set(resolvedRootPath, resolvedRootPath)
        end
        if fileInfo ~= nil then
            resolvedRootFileInfos[resolvedRootPath] = fileInfo
        end
    end

    for _, root in ipairs(self.root or {}) do
        if root.nonIncremental ~= "" then
            addRoot(root.nonIncremental, nil)
        elseif root.end_ == 0 then
            addRoot(self:fileName(root.start), self:fileInfo(root.start))
        else
            for i = root.start, root.end_ do
                addRoot(self:fileName(i), self:fileInfo(i))
            end
        end
    end

    return incremental.newBuildInfoRootInfoReader(resolvedRootFileInfos, rootToResolved)
end

-- BuildInfoRootInfoReader: { resolvedRootFileInfos (path -> *BuildInfoFileInfo), rootToResolved (OrderedMap path -> path) }
local BuildInfoRootInfoReader = {}
BuildInfoRootInfoReader.__index = BuildInfoRootInfoReader
incremental.BuildInfoRootInfoReader = BuildInfoRootInfoReader

function incremental.newBuildInfoRootInfoReader(resolvedRootFileInfos, rootToResolved)
    return setmetatable({
        resolvedRootFileInfos = resolvedRootFileInfos,
        rootToResolved = rootToResolved,
    }, BuildInfoRootInfoReader)
end

-- Returns (info, resolvedPath).
function BuildInfoRootInfoReader:GetBuildInfoFileInfo(inputFilePath)
    local info = self.resolvedRootFileInfos[inputFilePath]
    if info ~= nil then
        return info, inputFilePath
    end
    local resolved, ok = self.rootToResolved:Get(inputFilePath)
    if ok then
        return self.resolvedRootFileInfos[resolved], resolved
    end
    return nil, ""
end

-- Returns a Lua iterator over the root paths.
function BuildInfoRootInfoReader:Roots()
    return self.rootToResolved:Keys()
end
