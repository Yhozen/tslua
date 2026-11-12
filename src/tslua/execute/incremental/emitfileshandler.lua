local incremental = require("tslua.execute.incremental")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

local FileEmitKind = incremental.FileEmitKind
local EmitOnly = compiler.EmitOnly
local SignatureUpdateKind = incremental.SignatureUpdateKind
local isTrue = core.Tristate_IsTrue

-- emitUpdate: { pendingKind, result, dtsErrorsFromCache }

local emitFilesHandler = {}
emitFilesHandler.__index = emitFilesHandler
incremental.emitFilesHandler = emitFilesHandler

function incremental.newEmitFilesHandler(ctx, program, isForDtsErrors)
    return setmetatable({
        ctx = ctx,
        program = program,
        isForDtsErrors = isForDtsErrors,
        signatures = collections.NewSyncMap(),
        emitSignatures = collections.NewSyncMap(),
        latestChangedDtsFiles = collections.NewSyncMap(),
        deletedPendingKinds = collections.NewSet(),
        emitUpdates = collections.NewSyncMap(),
        hasEmitDiagnostics = false,
    }, emitFilesHandler)
end

-- Determining what all is pending to be emitted based on previous options or previous file emit flags
function emitFilesHandler:getPendingEmitKindForEmitOptions(emitKind, options)
    local pendingKind = incremental.getPendingEmitKind(emitKind, 0)
    if options.emitOnly == EmitOnly.Dts then
        pendingKind = pendingKind & FileEmitKind.AllDts
    end
    if self.isForDtsErrors then
        pendingKind = pendingKind & FileEmitKind.DtsErrors
    end
    return pendingKind
end

-- Emits the next affected file's emit result (EmitResult and sourceFiles emitted) or returns undefined if iteration is complete
-- The first of writeFile if provided, writeFile of BuilderProgramHost if provided, writeFile of compiler host
-- in that order would be used to write the files
function emitFilesHandler:emitAllAffectedFiles(options)
    -- Emit all affected files
    if self.program.snapshot:canUseIncrementalState() then
        local results = self:emitFilesIncremental(options)
        if self.isForDtsErrors then
            if options.targetSourceFiles ~= nil then
                -- Result from cache
                local result = compiler.newEmitResult({
                    emitSkipped = true,
                    diagnostics = core.FlatMap(options.targetSourceFiles, function(targetFile)
                        local diags = self.program.snapshot.emitDiagnosticsPerFile:Load(targetFile:Path())
                        if diags == nil then
                            return nil
                        end
                        return diags:getDiagnostics(self.program.program, targetFile)
                    end),
                })
                self:updateHasEmitDiagnostics(result)
                return result
            end
            for _, result in ipairs(results or {}) do
                self:updateHasEmitDiagnostics(result)
            end
            return compiler.CombineEmitResults(results or {})
        else
            -- Combine results and update buildInfo
            local result = compiler.CombineEmitResults(results or {})
            self:updateHasEmitDiagnostics(result)
            self:emitBuildInfo(options, result)
            return result
        end
    elseif not self.isForDtsErrors then
        local result = self.program.program:Emit(self.ctx, self:getEmitOptions(options))
        self:updateHasEmitDiagnostics(result)
        self:updateSnapshot()
        self:emitBuildInfo(options, result)
        return result
    else
        local diags
        if options.targetSourceFiles == nil then
            diags = self.program.program:GetDeclarationDiagnostics(self.ctx, nil)
        else
            diags = core.FlatMap(options.targetSourceFiles, function(targetSourceFile)
                return self.program.program:GetDeclarationDiagnostics(self.ctx, targetSourceFile)
            end)
        end
        local result = compiler.newEmitResult({
            emitSkipped = true,
            diagnostics = diags,
        })
        if core.Len(result.diagnostics) ~= 0 then
            self:updateHasEmitDiagnostics(result)
            self.program.snapshot.hasEmitDiagnostics = true
        end
        return result
    end
end

function emitFilesHandler:updateHasEmitDiagnostics(result)
    if result ~= nil and core.Len(result.diagnostics) ~= 0 then
        self.hasEmitDiagnostics = true
    end
end

function emitFilesHandler:emitBuildInfo(options, result)
    local buildInfoResult = self.program:emitBuildInfo(self.ctx, options)
    if buildInfoResult ~= nil then
        result.diagnostics = core.AppendAll(result.diagnostics, buildInfoResult.diagnostics)
        result.emittedFiles = core.AppendAll(result.emittedFiles, buildInfoResult.emittedFiles)
    end
end

function emitFilesHandler:emitFilesIncremental(options)
    -- Get all affected files
    incremental.collectAllAffectedFiles(self.ctx, self.program)
    if incremental.ctxErr(self.ctx) ~= nil then
        return nil
    end

    local wg = core.NewWorkGroup(self.program.program:SingleThreaded())
    incremental.rangeSorted(self.program.snapshot.affectedFilesPendingEmit, function(path, emitKind)
        local affectedFile = self.program.program:GetSourceFileByPath(path)
        if affectedFile == nil or not self.program.program:SourceFileMayBeEmitted(affectedFile, false) then
            self.deletedPendingKinds:Add(path)
            return true
        end
        local pendingKind = self:getPendingEmitKindForEmitOptions(emitKind, options)
        if pendingKind ~= 0 then
            wg:Queue(function()
                -- Determine if we can do partial emit
                local emitOnly = EmitOnly.EmitAll
                if (pendingKind & FileEmitKind.AllJs) ~= 0 then
                    emitOnly = EmitOnly.Js
                end
                if (pendingKind & FileEmitKind.AllDts) ~= 0 then
                    if emitOnly == EmitOnly.Js then
                        emitOnly = EmitOnly.EmitAll
                    else
                        emitOnly = EmitOnly.Dts
                    end
                end
                local result
                if not self.isForDtsErrors then
                    result = self.program.program:Emit(self.ctx, self:getEmitOptions(compiler.NewEmitOptions({
                        targetSourceFiles = core.SingleElementSlice(affectedFile),
                        emitOnly = emitOnly,
                        writeFile = options.writeFile,
                    })))
                else
                    result = compiler.newEmitResult({
                        emitSkipped = true,
                        diagnostics = self.program.program:GetDeclarationDiagnostics(self.ctx, affectedFile),
                    })
                end
                self:updateHasEmitDiagnostics(result)

                -- Update the pendingEmit for the file
                self.emitUpdates:Store(path, {
                    pendingKind = incremental.getPendingEmitKind(emitKind, pendingKind),
                    result = result,
                    dtsErrorsFromCache = false,
                })
            end)
        end
        return true
    end)
    wg:RunAndWait()
    if incremental.ctxErr(self.ctx) ~= nil then
        return nil
    end

    -- Get updated errors that were not included in affected files emit
    incremental.rangeSorted(self.program.snapshot.emitDiagnosticsPerFile, function(path, diags)
        local _, ok = self.emitUpdates:Load(path)
        if not ok then
            local affectedFile = self.program.program:GetSourceFileByPath(path)
            if affectedFile == nil or not self.program.program:SourceFileMayBeEmitted(affectedFile, false) then
                self.deletedPendingKinds:Add(path)
                return true
            end
            local pendingKind = self.program.snapshot.affectedFilesPendingEmit:Load(path) or 0
            self.emitUpdates:Store(path, {
                pendingKind = pendingKind,
                result = compiler.newEmitResult({
                    emitSkipped = true,
                    diagnostics = diags:getDiagnostics(self.program.program, affectedFile),
                }),
                dtsErrorsFromCache = true,
            })
        end
        return true
    end)

    return self:updateSnapshot()
end

function emitFilesHandler:getEmitOptions(options)
    if not self.program.snapshot.options:GetEmitDeclarations() then
        return options
    end
    local canUseIncrementalState = self.program.snapshot:canUseIncrementalState()
    return compiler.NewEmitOptions({
        targetSourceFiles = options.targetSourceFiles,
        emitOnly = options.emitOnly,
        forceEmit = options.forceEmit,
        writeFile = function(fileName, text, data)
            local differsOnlyInMap = { value = false }
            if tspath.IsDeclarationFileName(fileName) then
                if canUseIncrementalState then
                    local emitSignature = ""
                    local info = self.program.snapshot.fileInfos:Load(data.sourceFile:Path())
                    if info.signature == info.version then
                        local signature = self.program.snapshot:computeSignatureWithDiagnostics(data.sourceFile, text, data)
                        -- With d.ts diagnostics they are also part of the signature so emitSignature will be different from it since its just hash of d.ts
                        if core.Len(data.diagnostics) == 0 then
                            emitSignature = signature
                        end
                        if signature ~= info.version then -- Update it
                            self.signatures:Store(data.sourceFile:Path(), signature)
                        end
                    end

                    -- Store d.ts emit hash so later can be compared to check if d.ts has changed.
                    -- Currently we do this only for composite projects since these are the only projects that can be referenced by other projects
                    -- and would need their d.ts change time in --build mode
                    if self:skipDtsOutputOfComposite(data.sourceFile, fileName, text, data, emitSignature, differsOnlyInMap) then
                        return nil
                    end
                end
            end

            local aTime = 0
            if differsOnlyInMap.value then
                aTime = self.program.host:GetMTime(fileName)
            end
            local err
            if options.writeFile ~= nil then
                err = options.writeFile(fileName, text, data)
            else
                err = self.program.program:Host():FS():WriteFile(fileName, text)
            end
            if err == nil and differsOnlyInMap.value then
                -- Revert the time to original one
                err = self.program.host:SetMTime(fileName, aTime)
            end
            return err
        end,
    })
end

-- Compare to existing computed signature and store it or handle the changes in d.ts map option from before
-- returning undefined means that, we dont need to emit this d.ts file since its contents didnt change
-- differsOnlyInMap is a { value = bool } box (Go *bool).
function emitFilesHandler:skipDtsOutputOfComposite(file, outputFileName, text, data, newSignature, differsOnlyInMap)
    if not isTrue(self.program.snapshot.options.composite) then
        return false
    end
    local oldSignature = ""
    local oldSignatureFormat, ok = self.program.snapshot.emitSignatures:Load(file:Path())
    if ok then
        if oldSignatureFormat.signature ~= "" then
            oldSignature = oldSignatureFormat.signature
        else
            oldSignature = oldSignatureFormat.signatureWithDifferentOptions[1]
        end
    end
    if newSignature == "" then
        newSignature = self.program.snapshot:computeHash(incremental.getTextHandlingSourceMapForSignature(text, data))
    end
    -- Dont write dts files if they didn't change
    if newSignature == oldSignature then
        -- If the signature was encoded as string the dts map options match so nothing to do
        if oldSignatureFormat ~= nil and oldSignatureFormat.signature == oldSignature then
            data.skippedDtsWrite = true
            return true
        else
            -- Mark as differsOnlyInMap so that we can reverse the timestamp with --build so that
            -- the downstream projects dont detect this as change in d.ts file
            differsOnlyInMap.value = isTrue(self.program:Options().build)
        end
    else
        self.latestChangedDtsFiles:Store(file:Path(), outputFileName)
    end
    self.emitSignatures:Store(file:Path(), incremental.newEmitSignature(newSignature, nil))
    return false
end

function emitFilesHandler:updateSnapshot()
    if self.program.snapshot:canUseIncrementalState() then
        incremental.rangeSorted(self.signatures, function(file, signature)
            local info = self.program.snapshot.fileInfos:Load(file)
            info.signature = signature
            if self.program.testingData ~= nil then
                self.program.testingData.updatedSignatureKinds[file] = SignatureUpdateKind.StoredAtEmit
            end
            self.program.snapshot.buildInfoEmitPending = true
            return true
        end)
        incremental.rangeSorted(self.emitSignatures, function(file, signature)
            self.program.snapshot.emitSignatures:Store(file, signature)
            self.program.snapshot.buildInfoEmitPending = true
            return true
        end)
        for _, file in ipairs(incremental.sortedKeys(self.deletedPendingKinds:Keys())) do
            self.program.snapshot.affectedFilesPendingEmit:Delete(file)
            self.program.snapshot.buildInfoEmitPending = true
        end
        -- Always use correct order when to collect the result
        local results = nil
        for _, file in ipairs(self.program:GetSourceFiles()) do
            local latestChangedDtsFile, ok = self.latestChangedDtsFiles:Load(file:Path())
            if ok then
                self.program.snapshot.latestChangedDtsFile = latestChangedDtsFile
                self.program.snapshot.buildInfoEmitPending = true
                self.program.snapshot.hasChangedDtsFile = true
            end
            local update, updateOk = self.emitUpdates:Load(file:Path())
            if updateOk then
                if not update.dtsErrorsFromCache then
                    if update.pendingKind == 0 then
                        self.program.snapshot.affectedFilesPendingEmit:Delete(file:Path())
                    else
                        self.program.snapshot.affectedFilesPendingEmit:Store(file:Path(), update.pendingKind)
                    end
                    self.program.snapshot.buildInfoEmitPending = true
                end
                if update.result ~= nil then
                    results = core.Append(results, update.result)
                    if core.Len(update.result.diagnostics) ~= 0 then
                        self.program.snapshot.emitDiagnosticsPerFile:Store(file:Path(), incremental.newDiagnosticsOrBuildInfoDiagnosticsWithFileName(update.result.diagnostics, nil))
                    end
                end
            end
        end
        return results
    elseif self.hasEmitDiagnostics then
        self.program.snapshot.hasEmitDiagnostics = true
    end
    return nil
end

function incremental.emitFiles(ctx, program, options, isForDtsErrors)
    local emitHandler = incremental.newEmitFilesHandler(ctx, program, isForDtsErrors)

    -- Single file emit - do direct from program
    if not isForDtsErrors and options.targetSourceFiles ~= nil then
        local result = program.program:Emit(ctx, emitHandler:getEmitOptions(options))
        emitHandler:updateHasEmitDiagnostics(result)
        if incremental.ctxErr(ctx) ~= nil then
            return nil
        end
        emitHandler:updateSnapshot()
        return result
    end

    -- Emit only affected files if using builder for emit
    return emitHandler:emitAllAffectedFiles(options)
end
