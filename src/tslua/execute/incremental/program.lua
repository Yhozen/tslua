local incremental = require("tslua.execute.incremental")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tracing = require("tslua.tracing")
local json = require("tslua.json")
local outputpaths = require("tslua.outputpaths")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate
local isTrue = core.Tristate_IsTrue

-- Program implements compiler.ProgramLike.
local Program = {}
Program.__index = Program
incremental.Program = Program

function incremental.newProgramStruct(fields)
    return setmetatable({
        snapshot = fields.snapshot,
        program = fields.program,
        host = fields.host,

        -- Testing data
        testingData = nil,

        nestedEmitNow = fields.nestedEmitNow,
        nestedEmitDepth = 0,
        nestedEmitStart = 0,
        nestedEmitTime = 0,
    }, Program)
end

-- nestedEmitNow is a function returning the current time (a number) or nil.
function incremental.NewProgram(program, oldProgram, host, nestedEmitNow, testing)
    local incrementalProgram = incremental.newProgramStruct({
        snapshot = incremental.programToSnapshot(program, oldProgram, testing),
        program = program,
        host = host,
        nestedEmitNow = nestedEmitNow,
    })

    if testing then
        incrementalProgram.testingData = incremental.newTestingData()
        incrementalProgram.testingData.semanticDiagnosticsPerFile = incrementalProgram.snapshot.semanticDiagnosticsPerFile
        if oldProgram ~= nil then
            incrementalProgram.testingData.oldProgramSemanticDiagnosticsPerFile = oldProgram.snapshot.semanticDiagnosticsPerFile
        else
            incrementalProgram.testingData.oldProgramSemanticDiagnosticsPerFile = collections.NewSyncMap()
        end
        incrementalProgram.testingData.updatedSignatureKinds = {}
    end
    return incrementalProgram
end

-- TestingData: { semanticDiagnosticsPerFile, oldProgramSemanticDiagnosticsPerFile (SyncMaps),
-- updatedSignatureKinds (path -> SignatureUpdateKind) }
function incremental.newTestingData()
    return {
        semanticDiagnosticsPerFile = nil,
        oldProgramSemanticDiagnosticsPerFile = nil,
        updatedSignatureKinds = nil,
    }
end

function Program:GetTestingData()
    return self.testingData
end

function Program:beginNestedEmit()
    local now = self.nestedEmitNow
    if now == nil then
        return function() end
    end
    if self.nestedEmitDepth == 0 then
        self.nestedEmitStart = now()
    end
    self.nestedEmitDepth = self.nestedEmitDepth + 1

    return function()
        self.nestedEmitDepth = self.nestedEmitDepth - 1
        if self.nestedEmitDepth == 0 then
            self.nestedEmitTime = self.nestedEmitTime + (now() - self.nestedEmitStart)
        end
    end
end

function Program:TakeNestedEmitTime()
    local nestedEmitTime = self.nestedEmitTime
    self.nestedEmitTime = 0
    return nestedEmitTime
end

function Program:panicIfNoProgram(method)
    if self.program == nil then
        error(method .. ": should not be called without program", 0)
    end
end

function Program:GetProgram()
    self:panicIfNoProgram("GetProgram")
    return self.program
end

function Program:HasChangedDtsFile()
    return self.snapshot.hasChangedDtsFile
end

-- Options implements compiler.AnyProgram interface.
function Program:Options()
    return self.snapshot.options
end

-- CommonSourceDirectory implements compiler.AnyProgram interface.
function Program:CommonSourceDirectory()
    self:panicIfNoProgram("CommonSourceDirectory")
    return self.program:CommonSourceDirectory()
end

-- Program implements compiler.AnyProgram interface.
function Program:Program()
    self:panicIfNoProgram("Program")
    return self.program
end

-- IsSourceFileDefaultLibrary implements compiler.AnyProgram interface.
function Program:IsSourceFileDefaultLibrary(path)
    self:panicIfNoProgram("IsSourceFileDefaultLibrary")
    return self.program:IsSourceFileDefaultLibrary(path)
end

-- GetSourceFiles implements compiler.AnyProgram interface.
function Program:GetSourceFiles()
    self:panicIfNoProgram("GetSourceFiles")
    return self.program:GetSourceFiles()
end

-- GetSourceFile implements compiler.AnyProgram interface.
function Program:GetSourceFile(path)
    self:panicIfNoProgram("GetSourceFile")
    return self.program:GetSourceFile(path)
end

-- GetConfigFileParsingDiagnostics implements compiler.AnyProgram interface.
function Program:GetConfigFileParsingDiagnostics()
    self:panicIfNoProgram("GetConfigFileParsingDiagnostics")
    return self.program:GetConfigFileParsingDiagnostics()
end

-- GetSyntacticDiagnostics implements compiler.AnyProgram interface.
function Program:GetSyntacticDiagnostics(ctx, file)
    self:panicIfNoProgram("GetSyntacticDiagnostics")
    return self.program:GetSyntacticDiagnostics(ctx, file)
end

-- GetBindDiagnostics implements compiler.AnyProgram interface.
function Program:GetBindDiagnostics(ctx, file)
    self:panicIfNoProgram("GetBindDiagnostics")
    return self.program:GetBindDiagnostics(ctx, file)
end

function Program:GetProgramDiagnostics()
    self:panicIfNoProgram("GetProgramDiagnostics")
    return self.program:GetProgramDiagnostics()
end

function Program:GetGlobalDiagnostics(ctx)
    self:panicIfNoProgram("GetGlobalDiagnostics")
    return self.program:GetGlobalDiagnostics(ctx)
end

-- GetSemanticDiagnostics implements compiler.AnyProgram interface.
function Program:GetSemanticDiagnostics(ctx, file)
    self:panicIfNoProgram("GetSemanticDiagnostics")
    if isTrue(self.snapshot.options.noCheck) then
        return nil
    end

    -- Ensure all the diagnsotics are cached
    self:collectSemanticDiagnosticsOfAffectedFiles(ctx, file)
    if incremental.ctxErr(ctx) ~= nil then
        return nil
    end

    -- Return result from cache
    if file ~= nil then
        return self:getSemanticDiagnosticsOfFile(file)
    end

    local diags = nil
    for _, f in ipairs(self.program:GetSourceFiles()) do
        diags = core.AppendAll(diags, self:getSemanticDiagnosticsOfFile(f))
    end
    return diags
end

function Program:getSemanticDiagnosticsOfFile(file)
    local cachedDiagnostics, ok = self.snapshot.semanticDiagnosticsPerFile:Load(file:Path())
    if not ok then
        error("After handling all the affected files, there shouldnt be more changes", 0)
    end
    return core.Concatenate(
        compiler.FilterNoEmitSemanticDiagnostics(cachedDiagnostics:getDiagnostics(self.program, file), self.snapshot.options),
        self.program:GetIncludeProcessorDiagnostics(file)
    )
end

-- GetDeclarationDiagnostics implements compiler.AnyProgram interface.
function Program:GetDeclarationDiagnostics(ctx, file)
    self:panicIfNoProgram("GetDeclarationDiagnostics")
    local result = incremental.emitFiles(ctx, self, compiler.NewEmitOptions({
        targetSourceFiles = core.SingleElementSlice(file),
    }), true)
    if result ~= nil then
        return result.diagnostics
    end
    return nil
end

-- GetSuggestionDiagnostics implements compiler.AnyProgram interface.
function Program:GetSuggestionDiagnostics(ctx, file)
    self:panicIfNoProgram("GetSuggestionDiagnostics")
    return self.program:GetSuggestionDiagnostics(ctx, file) -- TODO: incremental suggestion diagnostics (only relevant in editor incremental builder?)
end

-- GetModeForUsageLocation implements compiler.AnyProgram interface.
function Program:Emit(ctx, options)
    self:panicIfNoProgram("Emit")
    options = compiler.NewEmitOptions(options)

    local result = nil
    if not options.forceEmit and options.emitOnly ~= compiler.EmitOnly.BuilderSignature then
        local emitBuildInfo = nil
        if isTrue(self:Options().noEmit) then
            emitBuildInfo = function()
                return self:emitBuildInfo(ctx, options)
            end
        end
        result = compiler.HandleNoEmitOptions(ctx, self, options.targetSourceFiles, emitBuildInfo)
        if incremental.ctxErr(ctx) ~= nil then
            return nil
        end
    end
    if result ~= nil then
        if options.targetSourceFiles ~= nil or isTrue(self:Options().noEmit) then
            return result
        end

        -- Emit buildInfo and combine result
        local buildInfoResult = self:emitBuildInfo(ctx, options)
        if buildInfoResult ~= nil then
            result.diagnostics = core.AppendAll(result.diagnostics, buildInfoResult.diagnostics)
            result.emittedFiles = core.AppendAll(result.emittedFiles, buildInfoResult.emittedFiles)
        end
        return result
    end
    return incremental.emitFiles(ctx, self, options, false)
end

-- Handle affected files and cache the semantic diagnostics for all of them or the file asked for
function Program:collectSemanticDiagnosticsOfAffectedFiles(ctx, file)
    if self.snapshot:canUseIncrementalState() then
        -- Get all affected files
        incremental.collectAllAffectedFiles(ctx, self)
        if incremental.ctxErr(ctx) ~= nil then
            return
        end

        if self.snapshot.semanticDiagnosticsPerFile:Size() == #self.program:GetSourceFiles() then
            -- If we have all the files,
            return
        end
    end

    local affectedFiles = nil
    if file ~= nil then
        local _, ok = self.snapshot.semanticDiagnosticsPerFile:Load(file:Path())
        if ok then
            return
        end
        affectedFiles = { file }
    else
        for _, f in ipairs(self.program:GetSourceFiles()) do
            local _, ok = self.snapshot.semanticDiagnosticsPerFile:Load(f:Path())
            if not ok then
                affectedFiles = core.Append(affectedFiles, f)
            end
        end
    end

    -- Get their diagnostics and cache them
    local diagnosticsPerFile = self.program:GetSemanticDiagnosticsWithoutNoEmitFiltering(ctx, affectedFiles or {})
    -- commit changes if no err
    if incremental.ctxErr(ctx) ~= nil then
        return
    end

    -- Commit changes to snapshot
    for _, f in ipairs(affectedFiles or {}) do
        local diags = diagnosticsPerFile[f]
        if diags ~= nil then
            self.snapshot.semanticDiagnosticsPerFile:Store(f:Path(), incremental.newDiagnosticsOrBuildInfoDiagnosticsWithFileName(diags, nil))
        end
    end
    if self.snapshot.semanticDiagnosticsPerFile:Size() == #self.program:GetSourceFiles() and self.snapshot.checkPending and not isTrue(self.snapshot.options.noCheck) then
        self.snapshot.checkPending = false
    end
    self.snapshot.buildInfoEmitPending = true
end

local function stringSlicesEqual(a, b)
    a, b = a or {}, b or {}
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

function Program:emitBuildInfo(ctx, options)
    -- Go defers the trace pop until return: the body runs in a closure.
    local function emitBuildInfo()
        local buildInfoFileName = outputpaths.GetBuildInfoFileName(self.snapshot.options, tspath.NewComparePathsOptions(
            self.program:UseCaseSensitiveFileNames(),
            self.program:GetCurrentDirectory()
        ))
        if buildInfoFileName == "" or self.program:IsEmitBlocked(buildInfoFileName) then
            return nil
        end
        if self.snapshot.hasErrors == Tristate.TSUnknown then
            self:ensureHasErrorsForState(ctx, self.program)
            if self.snapshot.hasErrors ~= self.snapshot.hasErrorsFromOldState or self.snapshot.hasSemanticErrors ~= self.snapshot.hasSemanticErrorsFromOldState then
                self.snapshot.buildInfoEmitPending = true
            end
        end
        if self.snapshot.packageJsons == nil then
            self:ensurePackageJsonsForState()
            if not stringSlicesEqual(self.snapshot.packageJsons, self.snapshot.packageJsonsFromOldState) or
                not stringSlicesEqual(self.snapshot.missingPackageJsons, self.snapshot.missingPackageJsonsFromOldState) then
                self.snapshot.buildInfoEmitPending = true
            end
        end
        if not self.snapshot.buildInfoEmitPending then
            return nil
        end
        if incremental.ctxErr(ctx) ~= nil then
            return nil
        end
        local buildInfo, err = incremental.snapshotToBuildInfo(self.snapshot, self.program, buildInfoFileName)
        if err ~= nil then
            return compiler.newEmitResult({
                emitSkipped = true,
                diagnostics = {
                    compiler.ContentMapperProjectDiagnostic(err),
                },
            })
        end
        local text
        text, err = json.Marshal(buildInfo)
        if err ~= nil then
            error("Failed to marshal build info: " .. tostring(err), 0)
        end
        if options.writeFile ~= nil then
            err = options.writeFile(buildInfoFileName, text, compiler.newWriteFileData({
                buildInfo = buildInfo,
            }))
        else
            err = self.program:Host():FS():WriteFile(buildInfoFileName, text)
        end
        if err ~= nil then
            return compiler.newEmitResult({
                emitSkipped = true,
                diagnostics = {
                    ast.NewCompilerDiagnostic(diagnostics.Could_not_write_file_0_Colon_1, buildInfoFileName, tostring(err)),
                },
            })
        end
        self.snapshot.buildInfoEmitPending = false
        return compiler.newEmitResult({
            emitSkipped = false,
            emittedFiles = { buildInfoFileName },
        })
    end
    local tr = self.program:Tracing()
    if tr ~= nil then
        local pop = tr:Push(tracing.PhaseEmit, "emitBuildInfo", nil, true)
        local result = emitBuildInfo()
        pop()
        return result
    end
    return emitBuildInfo()
end

function Program:ensureHasErrorsForState(ctx, program)
    local hasIncludeProcessingDiagnostics = nil
    local hasEmitDiagnostics = false
    if self.snapshot:canUseIncrementalState() then
        if core.Some(program:GetSourceFiles(), function(file)
            local _, ok = self.snapshot.emitDiagnosticsPerFile:Load(file:Path())
            if ok then
                -- emit diagnostics will be encoded in buildInfo;
                return true
            end
            if hasIncludeProcessingDiagnostics == nil and core.Len(self.program:GetIncludeProcessorDiagnostics(file)) > 0 then
                hasIncludeProcessingDiagnostics = function() return true end
            end
            return false
        end) then
            hasEmitDiagnostics = true
        end
        if hasIncludeProcessingDiagnostics == nil then
            hasIncludeProcessingDiagnostics = function() return false end
        end
    else
        hasEmitDiagnostics = self.snapshot.hasEmitDiagnostics
        hasIncludeProcessingDiagnostics = function()
            return core.Some(program:GetSourceFiles(), function(file)
                return core.Len(self.program:GetIncludeProcessorDiagnostics(file)) > 0
            end)
        end
    end

    if hasEmitDiagnostics then
        -- Record this for only non incremental build info
        self.snapshot.hasErrors = core.IfElse(self.snapshot.options:IsIncremental(), Tristate.TSFalse, Tristate.TSTrue)
        -- Dont need to encode semantic errors state since the emit diagnostics are encoded
        self.snapshot.hasSemanticErrors = false
        return
    end

    if hasIncludeProcessingDiagnostics() or
        core.Len(program:GetConfigFileParsingDiagnostics()) > 0 or
        core.Len(program:GetSyntacticDiagnostics(ctx, nil)) > 0 or
        core.Len(program:GetProgramDiagnostics()) > 0 or
        core.Len(program:GetGlobalDiagnostics(ctx)) > 0 then
        self.snapshot.hasErrors = Tristate.TSTrue
        -- Dont need to encode semantic errors state since the syntax and program diagnostics are encoded as present
        self.snapshot.hasSemanticErrors = false
        return
    end

    self.snapshot.hasErrors = Tristate.TSFalse
    -- Check semantic and emit diagnostics first as we dont need to ask program about it
    if core.Some(self.program:GetSourceFiles(), function(file)
        local semanticDiagnostics, ok = self.snapshot.semanticDiagnosticsPerFile:Load(file:Path())
        if not ok then
            -- Missing semantic diagnostics in cache will be encoded in incremental buildInfo
            return self.snapshot.options:IsIncremental()
        end
        if core.Len(semanticDiagnostics.diagnostics) > 0 or core.Len(semanticDiagnostics.buildInfoDiagnostics) > 0 then
            -- cached semantic diagnostics will be encoded in buildInfo
            return true
        end
        return false
    end) then
        -- Because semantic diagnostics are recorded in buildInfo, we dont need to encode hasErrors in incremental buildInfo
        -- But encode as errors in non incremental buildInfo
        self.snapshot.hasSemanticErrors = not self.snapshot.options:IsIncremental()
    end
end

function Program:ensurePackageJsonsForState()
    local config = tspath.GetDirectoryPath(tsoptions.ParsedCommandLine.ConfigName(self.program:CommandLine()))
    if config ~= "" then
        self.program:PackageJsonCacheEntries(function(key, value)
            if value == nil then
                return true
            end
            local packageJson = tspath.CombinePaths(value.packageDirectory, "package.json")
            if value:Exists() or value.directoryExists then
                packageJson = self.program:Host():FS():Realpath(packageJson)
            end
            if value:Exists() then
                self.snapshot.packageJsons = core.Append(self.snapshot.packageJsons, packageJson)
            elseif string.find(packageJson, "/node_modules/", 1, true) ~= nil then
                self.snapshot.missingPackageJsons = core.Append(self.snapshot.missingPackageJsons, packageJson)
            end
            return true
        end)
    end
    self.snapshot.packageJsons = incremental.normalizePackageJsons(self.snapshot.packageJsons)
    self.snapshot.missingPackageJsons = incremental.normalizePackageJsons(self.snapshot.missingPackageJsons)
end

function incremental.normalizePackageJsons(packageJsons)
    if packageJsons == nil then
        return {}
    end
    table.sort(packageJsons)
    return core.Deduplicate(packageJsons)
end

function Program:PackageJsonLookupPaths()
    local config = tspath.GetDirectoryPath(tsoptions.ParsedCommandLine.ConfigName(self.program:CommandLine()))
    if config == "" then
        return nil
    end

    local packageJsons = nil
    self.program:PackageJsonCacheEntries(function(key, value)
        if value == nil then
            return true
        end
        local packageJson = tspath.CombinePaths(value.packageDirectory, "package.json")
        if value:Exists() or value.directoryExists then
            packageJson = self.program:Host():FS():Realpath(packageJson)
        end
        packageJsons = core.Append(packageJsons, packageJson)
        return true
    end)
    if packageJsons ~= nil then
        table.sort(packageJsons)
    end
    return core.Deduplicate(packageJsons)
end
