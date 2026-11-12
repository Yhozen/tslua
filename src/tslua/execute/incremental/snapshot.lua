local incremental = require("tslua.execute.incremental")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tspath = require("tslua.tspath")
local xxh3 = require("tslua.xxh3")

local FileEmitKind = incremental.FileEmitKind
local Tristate = core.Tristate
local isTrue = core.Tristate_IsTrue

-- FileInfo: { version, signature, affectsGlobalScope, impliedNodeFormat }
local FileInfo = {}
FileInfo.__index = FileInfo
incremental.FileInfo = FileInfo

function incremental.newFileInfo(fields)
    return setmetatable({
        version = fields.version or "",
        signature = fields.signature or "",
        affectsGlobalScope = fields.affectsGlobalScope or false,
        impliedNodeFormat = fields.impliedNodeFormat or 0,
    }, FileInfo)
end

function FileInfo:Version() return self.version end
function FileInfo:Signature() return self.signature end
function FileInfo:AffectsGlobalScope() return self.affectsGlobalScope end
function FileInfo:ImpliedNodeFormat() return self.impliedNodeFormat end

function incremental.ComputeHash(text, hashWithText)
    local hash = xxh3.HashString128(text):Hex()
    if hashWithText then
        hash = hash .. "-" .. text
    end
    return hash
end

function incremental.GetFileEmitKind(options)
    local result = FileEmitKind.Js
    if isTrue(options.sourceMap) then
        result = result | FileEmitKind.JsMap
    end
    if isTrue(options.inlineSourceMap) then
        result = result | FileEmitKind.JsInlineMap
    end
    if options:GetEmitDeclarations() then
        result = result | FileEmitKind.Dts
    end
    if isTrue(options.declarationMap) then
        result = result | FileEmitKind.DtsMap
    end
    if isTrue(options.emitDeclarationOnly) then
        result = result & FileEmitKind.AllDts
    end
    return result
end

function incremental.getPendingEmitKindWithOptions(options, oldOptions)
    local oldEmitKind = incremental.GetFileEmitKind(oldOptions)
    local newEmitKind = incremental.GetFileEmitKind(options)
    return incremental.getPendingEmitKind(newEmitKind, oldEmitKind)
end

function incremental.getPendingEmitKind(emitKind, oldEmitKind)
    if oldEmitKind == emitKind then
        return FileEmitKind.None
    end
    if oldEmitKind == 0 or emitKind == 0 then
        return emitKind
    end
    local diff = oldEmitKind ~ emitKind
    local result = FileEmitKind.None
    -- If there is diff in Js emit, pending emit is js emit flags
    if (diff & FileEmitKind.AllJs) ~= 0 then
        result = result | (emitKind & FileEmitKind.AllJs)
    end
    -- If dts errors pending, add dts errors flag
    if (diff & FileEmitKind.DtsErrors) ~= 0 then
        result = result | (emitKind & FileEmitKind.AllDts)
    end
    -- If there is diff in Dts emit, pending emit is dts emit flags
    if (diff & FileEmitKind.AllDtsEmit) ~= 0 then
        result = result | (emitKind & FileEmitKind.AllDtsEmit)
    end
    return result
end

-- Signature (Hash of d.ts emitted), is string if it was emitted using same d.ts.map option as what compilerOptions indicate,
-- otherwise tuple of string
-- emitSignature: { signature = "", signatureWithDifferentOptions = nil | { string } }
local emitSignature = {}
emitSignature.__index = emitSignature
incremental.emitSignature = emitSignature

function incremental.newEmitSignature(signature, signatureWithDifferentOptions)
    return setmetatable({
        signature = signature or "",
        signatureWithDifferentOptions = signatureWithDifferentOptions,
    }, emitSignature)
end

-- Covert to Emit signature based on oldOptions and EmitSignature format
-- If d.ts map options differ then swap the format, otherwise use as is
function emitSignature:getNewEmitSignature(oldOptions, newOptions)
    if isTrue(oldOptions.declarationMap) == isTrue(newOptions.declarationMap) then
        return self
    end
    if self.signatureWithDifferentOptions == nil then
        return incremental.newEmitSignature("", { self.signature })
    else
        return incremental.newEmitSignature(self.signatureWithDifferentOptions[1], nil)
    end
end

-- buildInfoDiagnosticWithFileName: { file (path, "" if same file), noFile, pos, end_, code, category,
-- source, messageText, messageKey, messageArgs, messageChain, relatedInformation, reportsUnnecessary,
-- reportsDeprecated, skippedOnNoEmit, repopulateInfo }
local buildInfoDiagnosticWithFileName = {}
buildInfoDiagnosticWithFileName.__index = buildInfoDiagnosticWithFileName
incremental.buildInfoDiagnosticWithFileName = buildInfoDiagnosticWithFileName

function incremental.newBuildInfoDiagnosticWithFileName(fields)
    return setmetatable({
        -- filename if it is for a File thats other than its stored for
        file = fields.file or "",
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
    }, buildInfoDiagnosticWithFileName)
end

-- DiagnosticsOrBuildInfoDiagnosticsWithFileName: { diagnostics = nil | []*ast.Diagnostic,
-- buildInfoDiagnostics = nil | []*buildInfoDiagnosticWithFileName }
local DiagnosticsOrBuildInfoDiagnosticsWithFileName = {}
DiagnosticsOrBuildInfoDiagnosticsWithFileName.__index = DiagnosticsOrBuildInfoDiagnosticsWithFileName
incremental.DiagnosticsOrBuildInfoDiagnosticsWithFileName = DiagnosticsOrBuildInfoDiagnosticsWithFileName

function incremental.newDiagnosticsOrBuildInfoDiagnosticsWithFileName(diags, buildInfoDiagnostics)
    return setmetatable({
        diagnostics = diags,
        buildInfoDiagnostics = buildInfoDiagnostics,
    }, DiagnosticsOrBuildInfoDiagnosticsWithFileName)
end

function buildInfoDiagnosticWithFileName:toDiagnostic(p, file)
    local fileForDiagnostic = nil
    if self.file ~= "" then
        fileForDiagnostic = p:GetSourceFileByPath(self.file)
    elseif not self.noFile then
        fileForDiagnostic = file
    end

    if self.repopulateInfo ~= nil then
        return incremental.repopulateDiagnosticChain(self, p, fileForDiagnostic)
    end

    local messageChain = nil
    for _, msg in ipairs(self.messageChain or {}) do
        messageChain = core.Append(messageChain, msg:toDiagnostic(p, fileForDiagnostic))
    end
    local relatedInformation = nil
    for _, info in ipairs(self.relatedInformation or {}) do
        relatedInformation = core.Append(relatedInformation, info:toDiagnostic(p, fileForDiagnostic))
    end
    local diagnostic = ast.NewDiagnosticFromSerialized(
        fileForDiagnostic,
        core.NewTextRange(self.pos, self.end_),
        self.code,
        self.category,
        self.messageKey,
        self.messageArgs,
        messageChain,
        relatedInformation,
        self.reportsUnnecessary,
        self.reportsDeprecated,
        self.skippedOnNoEmit
    )
    if self.source ~= "" or self.messageText ~= "" then
        diagnostic:SetExternalData(self.source, self.messageText)
    end
    return diagnostic
end

-- repopulateDiagnosticChain recomputes a diagnostic chain entry that depends on
-- program state which may have changed between incremental builds.
function incremental.repopulateDiagnosticChain(b, p, file)
    local info = b.repopulateInfo
    if info.kind == ast.RepopulateDiagnosticKind.RepopulateModeMismatch then
        return incremental.repopulateModeMismatchChain(b, p, file)
    elseif info.kind == ast.RepopulateDiagnosticKind.RepopulateModuleNotFound then
        return incremental.repopulateModuleNotFoundChain(b, p, file, info)
    else
        -- Fall back to using the stored (possibly stale) data
        return b:toDiagnosticWithoutRepopulate(p, file)
    end
end

function buildInfoDiagnosticWithFileName:toDiagnosticWithoutRepopulate(p, file)
    local messageChain = nil
    for _, msg in ipairs(self.messageChain or {}) do
        messageChain = core.Append(messageChain, msg:toDiagnostic(p, file))
    end
    local relatedInformation = nil
    for _, info in ipairs(self.relatedInformation or {}) do
        relatedInformation = core.Append(relatedInformation, info:toDiagnostic(p, file))
    end
    return ast.NewDiagnosticFromSerialized(
        file,
        core.NewTextRange(self.pos, self.end_),
        self.code,
        self.category,
        self.messageKey,
        self.messageArgs,
        messageChain,
        relatedInformation,
        self.reportsUnnecessary,
        self.reportsDeprecated,
        self.skippedOnNoEmit
    )
end

function incremental.repopulateModeMismatchChain(b, p, file)
    if file == nil then
        return b:toDiagnosticWithoutRepopulate(p, file)
    end

    local details = checker.CreateModeMismatchDetails(p, file)

    local nextChain = nil
    for _, msg in ipairs(b.messageChain or {}) do
        nextChain = core.Append(nextChain, msg:toDiagnostic(p, file))
    end

    return ast.NewDiagnosticFromSerialized(
        file,
        core.NewTextRange(b.pos, b.end_),
        details.message:Code(),
        details.message:Category(),
        details.message:Key(),
        diagnostics.StringifyArgs(details.args),
        nextChain,
        nil,
        false,
        false,
        false
    )
end

function incremental.repopulateModuleNotFoundChain(b, p, file, info)
    if file == nil then
        return b:toDiagnosticWithoutRepopulate(p, file)
    end

    local packageName = info.packageName
    if packageName == "" then
        packageName = info.moduleReference
    end

    local details = checker.CreateModuleNotFoundChain(p, file, info.moduleReference, info.mode, packageName)

    local nextChain = nil
    for _, msg in ipairs(b.messageChain or {}) do
        nextChain = core.Append(nextChain, msg:toDiagnostic(p, file))
    end

    return ast.NewDiagnosticFromSerialized(
        file,
        core.NewTextRange(b.pos, b.end_),
        details.message:Code(),
        details.message:Category(),
        details.message:Key(),
        diagnostics.StringifyArgs(details.args),
        nextChain,
        nil,
        false,
        false,
        false
    )
end

function DiagnosticsOrBuildInfoDiagnosticsWithFileName:getDiagnostics(p, file)
    if self.diagnostics ~= nil then
        return self.diagnostics
    end
    -- Convert and cache the diagnostics
    self.diagnostics = core.Map(self.buildInfoDiagnostics, function(diag)
        return diag:toDiagnostic(p, file)
    end)
    return self.diagnostics
end

-- snapshot
local snapshot = {}
snapshot.__index = snapshot
incremental.snapshot = snapshot

function incremental.newSnapshot(fields)
    fields = fields or {}
    return setmetatable({
        -- These are the fields that get serialized

        -- Information of the file eg. its version, signature etc
        fileInfos = collections.NewSyncMap(),
        options = fields.options,
        --  Contains the map of ReferencedSet=Referenced files of the file if module emit is enabled
        referencedMap = incremental.newReferenceMap(),
        -- Cache of semantic diagnostics for files with their Path being the key
        semanticDiagnosticsPerFile = collections.NewSyncMap(),
        -- Cache of dts emit diagnostics for files with their Path being the key
        emitDiagnosticsPerFile = collections.NewSyncMap(),
        -- The map has key by source file's path that has been changed
        changedFilesSet = collections.NewSyncSet(),
        -- Files pending to be emitted
        affectedFilesPendingEmit = collections.NewSyncMap(),
        -- Name of the file whose dts was the latest to change
        latestChangedDtsFile = "",
        -- Hash of d.ts emitted for the file, use to track when emit of d.ts changes
        emitSignatures = collections.NewSyncMap(),
        -- Recorded if program had errors that need to be reported even with --noCheck
        hasErrors = Tristate.TSUnknown,
        -- Recorded if program had semantic errors only for non incremental build
        hasSemanticErrors = false,
        -- If semantic diagnostic check is pending
        checkPending = fields.checkPending or false,
        -- Looked up package.json files from
        packageJsons = nil,
        missingPackageJsons = nil,

        -- Additional fields that are not serialized but needed to track state

        -- true if build info emit is pending
        buildInfoEmitPending = false,
        hasErrorsFromOldState = Tristate.TSUnknown,
        hasSemanticErrorsFromOldState = false,
        allFilesExcludingDefaultLibraryFileDone = false,
        packageJsonsFromOldState = nil,
        missingPackageJsonsFromOldState = nil,
        --  Cache of all files excluding default library file for the current program
        allFilesExcludingDefaultLibraryFile = nil,
        hasChangedDtsFile = false,
        hasEmitDiagnostics = false,

        -- Used with testing to add text of hash for better comparison
        hashWithText = fields.hashWithText or false,
    }, snapshot)
end

function snapshot:addFileToChangeSet(filePath)
    self.changedFilesSet:Add(filePath)
    self.buildInfoEmitPending = true
end

function snapshot:addFileToAffectedFilesPendingEmit(filePath, emitKind)
    local existingKind = self.affectedFilesPendingEmit:Load(filePath) or 0
    self.affectedFilesPendingEmit:Store(filePath, existingKind | emitKind)
    if emitKind & FileEmitKind.DtsErrors ~= 0 then
        self.emitDiagnosticsPerFile:Delete(filePath)
    end
    self.buildInfoEmitPending = true
end

function snapshot:getAllFilesExcludingDefaultLibraryFile(program, firstSourceFile)
    if not self.allFilesExcludingDefaultLibraryFileDone then
        self.allFilesExcludingDefaultLibraryFileDone = true
        local files = program:GetSourceFiles()
        self.allFilesExcludingDefaultLibraryFile = {}
        local function addSourceFile(file)
            if not program:IsSourceFileDefaultLibrary(file:Path()) then
                local list = self.allFilesExcludingDefaultLibraryFile
                list[#list + 1] = file
            end
        end
        if firstSourceFile ~= nil then
            addSourceFile(firstSourceFile)
        end
        for _, file in ipairs(files) do
            if file ~= firstSourceFile then
                addSourceFile(file)
            end
        end
    end
    return self.allFilesExcludingDefaultLibraryFile
end

function incremental.getTextHandlingSourceMapForSignature(text, data)
    if data.sourceMapUrlPos ~= -1 then
        return string.sub(text, 1, data.sourceMapUrlPos)
    end
    return text
end

function snapshot:computeSignatureWithDiagnostics(file, text, data)
    local builder = { incremental.getTextHandlingSourceMapForSignature(text, data) }
    for _, diag in ipairs(data.diagnostics or {}) do
        incremental.diagnosticToStringBuilder(diag, file, builder)
    end
    return self:computeHash(table.concat(builder))
end

-- builder is an array of string pieces.
function incremental.diagnosticToStringBuilder(diagnostic, file, builder)
    if diagnostic == nil then
        return
    end
    builder[#builder + 1] = "\n"
    if diagnostic:File() ~= file then
        builder[#builder + 1] = tspath.EnsurePathIsNonModuleName(tspath.GetRelativePathFromDirectory(
            tspath.GetDirectoryPath(file:Path()),
            diagnostic:File():Path(),
            tspath.NewComparePathsOptions(false, "")
        ))
    end
    if diagnostic:File() ~= nil then
        builder[#builder + 1] = string.format("(%d,%d): ", diagnostic:Pos(), diagnostic:Len())
    end
    builder[#builder + 1] = diagnostics.Category_Name(diagnostic:Category())
    builder[#builder + 1] = string.format("%d: ", diagnostic:Code())
    builder[#builder + 1] = diagnostic:MessageKey()
    builder[#builder + 1] = "\n"
    for _, arg in ipairs(diagnostic:MessageArgs() or {}) do
        builder[#builder + 1] = arg
        builder[#builder + 1] = "\n"
    end
    for _, chain in ipairs(diagnostic:MessageChain() or {}) do
        incremental.diagnosticToStringBuilder(chain, file, builder)
    end
    for _, info in ipairs(diagnostic:RelatedInformation() or {}) do
        incremental.diagnosticToStringBuilder(info, file, builder)
    end
end

function snapshot:computeHash(text)
    return incremental.ComputeHash(text, self.hashWithText)
end

function snapshot:canUseIncrementalState()
    if not self.options:IsIncremental() and isTrue(self.options.build) then
        -- If not incremental build (with tsc -b), we don't need to track state except diagnostics per file so we can use it
        return false
    end
    return true
end
