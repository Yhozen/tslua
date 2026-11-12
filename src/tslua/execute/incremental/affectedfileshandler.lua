local incremental = require("tslua.execute.incremental")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

local FileEmitKind = incremental.FileEmitKind
local SignatureUpdateKind = incremental.SignatureUpdateKind
local SymbolFlags = ast.SymbolFlags
local isTrue = core.Tristate_IsTrue

-- dtsMayChange is a plain table path -> FileEmitKind.
function incremental.dtsMayChange_addFileToAffectedFilesPendingEmit(c, filePath, emitKind)
    c[filePath] = emitKind
end

-- updatedSignature: { signature, kind }
function incremental.newUpdatedSignature()
    return { signature = "", kind = SignatureUpdateKind.ComputedDts }
end

local affectedFilesHandler = {}
affectedFilesHandler.__index = affectedFilesHandler
incremental.affectedFilesHandler = affectedFilesHandler

function incremental.newAffectedFilesHandler(ctx, program)
    return setmetatable({
        ctx = ctx,
        program = program,
        hasAllFilesExcludingDefaultLibraryFile = false,
        updatedSignatures = collections.NewSyncMap(),
        dtsMayChange = nil,
        filesToRemoveDiagnostics = collections.NewSyncSet(),
        cleanedDiagnosticsOfLibFilesDone = false,
        seenFileAndReferences = collections.NewSyncMap(),
    }, affectedFilesHandler)
end

function affectedFilesHandler:getDtsMayChange(affectedFilePath, affectedFileEmitKind)
    local result = { [affectedFilePath] = affectedFileEmitKind }
    self.dtsMayChange = core.Append(self.dtsMayChange, result)
    return result
end

function affectedFilesHandler:isChangedSignature(path)
    local newSignature = self.updatedSignatures:Load(path)
    -- This method is called after updating signatures of that path, so signature is present in updatedSignatures
    -- And is already calculated, so no need to lock and unlock mutex on the entry
    local oldInfo = self.program.snapshot.fileInfos:Load(path)
    return newSignature.signature ~= oldInfo.signature
end

function affectedFilesHandler:removeSemanticDiagnosticsOf(path)
    self.filesToRemoveDiagnostics:Add(path)
end

function affectedFilesHandler:removeDiagnosticsOfLibraryFiles()
    if not self.cleanedDiagnosticsOfLibFilesDone then
        self.cleanedDiagnosticsOfLibFilesDone = true
        for _, file in ipairs(self.program:GetSourceFiles()) do
            if self.program.program:IsSourceFileDefaultLibrary(file:Path()) and not self.program.program:SkipTypeChecking(file, true) then
                self:removeSemanticDiagnosticsOf(file:Path())
            end
        end
    end
end

function affectedFilesHandler:computeDtsSignature(file)
    local signature = ""
    local done = self.program:beginNestedEmit()
    self.program.program:Emit(self.ctx, compiler.NewEmitOptions({
        targetSourceFiles = core.SingleElementSlice(file),
        emitOnly = compiler.EmitOnly.BuilderSignature,
        writeFile = function(fileName, text, data)
            if not tspath.IsDeclarationFileName(fileName) then
                error("File extension for signature expected to be dts, got : " .. fileName, 0)
            end
            signature = self.program.snapshot:computeSignatureWithDiagnostics(file, text, data)
            return nil
        end,
    }))
    done()
    return signature
end

function affectedFilesHandler:updateShapeSignature(file, useFileVersionAsSignature)
    local update = incremental.newUpdatedSignature()
    -- If we have cached the result for this file, that means hence forth we should assume file shape is uptodate
    local _, loaded = self.updatedSignatures:LoadOrStore(file:Path(), update)
    if loaded then
        return false
    end

    local info = self.program.snapshot.fileInfos:Load(file:Path())
    local prevSignature = info.signature
    if not file.isDeclarationFile and not useFileVersionAsSignature then
        update.signature = self:computeDtsSignature(file)
    end
    -- Default is to use file version as signature
    if update.signature == "" then
        update.signature = info.version
        update.kind = SignatureUpdateKind.UsedVersion
    end
    return update.signature ~= prevSignature
end

function affectedFilesHandler:getFilesAffectedBy(path)
    local file = self.program.program:GetSourceFileByPath(path)
    if file == nil then
        return nil
    end

    if not self:updateShapeSignature(file, false) then
        return { file }
    end

    local info = self.program.snapshot.fileInfos:Load(file:Path())
    if info.affectsGlobalScope then
        self.hasAllFilesExcludingDefaultLibraryFile = true
        return self.program.snapshot:getAllFilesExcludingDefaultLibraryFile(self.program.program, file)
    end

    if isTrue(self.program.snapshot.options.isolatedModules) then
        return { file }
    end

    -- Now we need to if each file in the referencedBy list has a shape change as well.
    -- Because if so, its own referencedBy files need to be saved as well to make the
    -- emitting result consistent with files on disk.
    local seenFileNamesMap = self:forEachFileReferencedBy(
        file,
        function(currentFile, currentPath)
            -- If the current file is not nil and has a shape change, we need to queue it for processing
            if currentFile ~= nil and self:updateShapeSignature(currentFile, false) then
                return true, false
            end
            return false, false
        end
    )
    -- Return array of values that needs emit
    local result = {}
    for _, p in ipairs(incremental.sortedKeys(seenFileNamesMap)) do
        local f = seenFileNamesMap[p]
        if f ~= false then
            result[#result + 1] = f
        end
    end
    return result
end

-- Returns a table path -> *ast.SourceFile (false for paths without a source file, Go nil).
function affectedFilesHandler:forEachFileReferencedBy(file, fn)
    -- Now we need to if each file in the referencedBy list has a shape change as well.
    -- Because if so, its own referencedBy files need to be saved as well to make the
    -- emitting result consistent with files on disk.
    local seenFileNamesMap = {}
    -- Start with the paths this file was referenced by
    seenFileNamesMap[file:Path()] = file
    local queue = {}
    for ref in self.program.snapshot.referencedMap:getReferencedBy(file:Path()) do
        queue[#queue + 1] = ref
    end
    while #queue > 0 do
        local currentPath = queue[#queue]
        queue[#queue] = nil
        if seenFileNamesMap[currentPath] == nil then
            local currentFile = self.program.program:GetSourceFileByPath(currentPath)
            seenFileNamesMap[currentPath] = currentFile or false
            local queueForFile, fastReturn = fn(currentFile, currentPath)
            if fastReturn then
                return seenFileNamesMap
            end
            if queueForFile then
                for ref in self.program.snapshot.referencedMap:getReferencedBy(currentFile:Path()) do
                    queue[#queue + 1] = ref
                end
            end
        end
    end
    return seenFileNamesMap
end

-- Handles semantic diagnostics and dts emit for affectedFile and files, that are referencing modules that export entities from affected file
-- This is because even though js emit doesnt change, dts emit / type used can change resulting in need for dts emit and js change
function affectedFilesHandler:handleDtsMayChangeOfAffectedFile(dtsMayChange, affectedFile)
    self:removeSemanticDiagnosticsOf(affectedFile:Path())

    -- If affected files is everything except default library, then nothing more to do
    if self.hasAllFilesExcludingDefaultLibraryFile then
        self:removeDiagnosticsOfLibraryFiles()
        -- When a change affects the global scope, all files are considered to be affected without updating their signature
        -- That means when affected file is handled, its signature can be out of date
        -- To avoid this, ensure that we update the signature for any affected file in this scenario.
        self:updateShapeSignature(affectedFile, false)
        return
    end

    if isTrue(self.program.snapshot.options.assumeChangesOnlyAffectDirectDependencies) then
        return
    end

    -- Iterate on referencing modules that export entities from affected file and delete diagnostics and add pending emit
    -- If there was change in signature (dts output) for the changed file,
    -- then only we need to handle pending file emit
    if not self.program.snapshot.changedFilesSet:Has(affectedFile:Path()) or
        not self:isChangedSignature(affectedFile:Path()) then
        return
    end

    -- At this point affectedFile is actually one of the changed files
    -- that has some change in its .d.ts signature.

    -- Since isolated modules dont change js files, files affected by change in signature is itself
    -- But we need to cleanup semantic diagnostics and queue dts emit for affected files
    if isTrue(self.program.snapshot.options.isolatedModules) then
        self:forEachFileReferencedBy(
            affectedFile,
            function(currentFile, currentPath)
                if self:handleDtsMayChangeOfGlobalScope(dtsMayChange, currentPath, false --[[invalidateJsFiles]]) then
                    return false, true
                end
                self:handleDtsMayChangeOf(dtsMayChange, currentPath, false --[[invalidateJsFiles]])
                if self:isChangedSignature(currentPath) then
                    return true, false
                end
                return false, false
            end
        )
    end

    local invalidateJsFiles = false
    local typeChecker = nil
    local done = nil
    -- If exported const enum, we need to ensure that js files are emitted as well since the const enum value changed
    if affectedFile.symbol ~= nil then
        local exports = affectedFile.symbol.exports or {}
        for _, name in ipairs(incremental.sortedKeys(exports)) do
            local exported = exports[name]
            if exported.flags & SymbolFlags.ConstEnum ~= 0 then
                invalidateJsFiles = true
                break
            end
            if typeChecker == nil then
                typeChecker, done = self.program.program:GetTypeCheckerForFileExclusive(self.ctx, affectedFile)
            end
            local aliased = checker.SkipAlias(exported, typeChecker)
            if aliased ~= exported then
                if (aliased.flags & SymbolFlags.ConstEnum) ~= 0 then
                    if core.Some(aliased.declarations, function(d)
                        return ast.GetSourceFileOfNode(d) == affectedFile
                    end) then
                        invalidateJsFiles = true
                        break
                    end
                end
            end
        end
    end
    if done ~= nil then
        done()
    end

    -- Go through files that reference affected file and handle dts emit and semantic diagnostics for them and their references
    for fileReferencingChangedFile in self.program.snapshot.referencedMap:getReferencedBy(affectedFile:Path()) do
        if self:handleDtsMayChangeOfGlobalScope(dtsMayChange, fileReferencingChangedFile, invalidateJsFiles) then
            return
        end
        -- Since references of changed file = affected files - we would have already handled d.ts emit and semantic diagnostics
        -- for those files. Now we need to handle files referencing those affected files to ensure correctness.
        for fileReferencingAffectedFile in self.program.snapshot.referencedMap:getReferencedBy(fileReferencingChangedFile) do
            if self:handleDtsMayChangeOfFileAndReferences(dtsMayChange, fileReferencingAffectedFile, invalidateJsFiles) then
                return
            end
        end
    end
end

function affectedFilesHandler:handleDtsMayChangeOfFileAndReferences(dtsMayChange, filePath, invalidateJsFiles)
    local existing, loaded = self.seenFileAndReferences:LoadOrStore(filePath, invalidateJsFiles)
    if loaded and (existing or not invalidateJsFiles) then
        return false
    elseif loaded and invalidateJsFiles then
        self.seenFileAndReferences:Store(filePath, true)
    end

    if self:handleDtsMayChangeOfGlobalScope(dtsMayChange, filePath, invalidateJsFiles) then
        return true
    end
    self:handleDtsMayChangeOf(dtsMayChange, filePath, invalidateJsFiles)

    -- Remove the diagnostics of files that import this file and
    -- any files that are referenced by it (directly or indirectly)
    for referencingFilePath in self.program.snapshot.referencedMap:getReferencedBy(filePath) do
        if self:handleDtsMayChangeOfFileAndReferences(dtsMayChange, referencingFilePath, invalidateJsFiles) then
            return true
        end
    end
    return false
end

function affectedFilesHandler:handleDtsMayChangeOfGlobalScope(dtsMayChange, filePath, invalidateJsFiles)
    local info, ok = self.program.snapshot.fileInfos:Load(filePath)
    if not ok or not info.affectsGlobalScope then
        return false
    end
    -- Every file needs to be handled
    for _, file in ipairs(self.program.snapshot:getAllFilesExcludingDefaultLibraryFile(self.program.program, nil)) do
        self:handleDtsMayChangeOf(dtsMayChange, file:Path(), invalidateJsFiles)
    end
    self:removeDiagnosticsOfLibraryFiles()
    return true
end

-- Handle the dts may change, so they need to be added to pending emit if dts emit is enabled,
-- Also we need to make sure signature is updated for these files
function affectedFilesHandler:handleDtsMayChangeOf(dtsMayChange, path, invalidateJsFiles)
    if self.program.snapshot.changedFilesSet:Has(path) then
        return
    end
    local file = self.program.program:GetSourceFileByPath(path)
    if file == nil then
        return
    end
    self:removeSemanticDiagnosticsOf(path)
    -- Even though the js emit doesnt change and we are already handling dts emit and semantic diagnostics
    -- we need to update the signature to reflect correctness of the signature(which is output d.ts emit) of this file
    -- This ensures that we dont later during incremental builds considering wrong signature.
    -- Eg where this also is needed to ensure that .tsbuildinfo generated by incremental build should be same as if it was first fresh build
    -- But we avoid expensive full shape computation, as using file version as shape is enough for correctness.
    self:updateShapeSignature(file, true)
    -- If not dts emit, nothing more to do
    if invalidateJsFiles then
        incremental.dtsMayChange_addFileToAffectedFilesPendingEmit(dtsMayChange, path, incremental.GetFileEmitKind(self.program.snapshot.options))
    elseif self.program.snapshot.options:GetEmitDeclarations() then
        incremental.dtsMayChange_addFileToAffectedFilesPendingEmit(dtsMayChange, path, core.IfElse(isTrue(self.program.snapshot.options.declarationMap), FileEmitKind.AllDts, FileEmitKind.Dts))
    end
end

function affectedFilesHandler:updateSnapshot()
    if incremental.ctxErr(self.ctx) ~= nil then
        return
    end
    incremental.rangeSorted(self.updatedSignatures, function(filePath, update)
        local info, ok = self.program.snapshot.fileInfos:Load(filePath)
        if ok then
            info.signature = update.signature
            if self.program.testingData ~= nil then
                self.program.testingData.updatedSignatureKinds[filePath] = update.kind
            end
        end
        return true
    end)
    incremental.rangeSortedSet(self.filesToRemoveDiagnostics, function(file)
        self.program.snapshot.semanticDiagnosticsPerFile:Delete(file)
        return true
    end)
    for _, change in ipairs(self.dtsMayChange or {}) do
        for _, filePath in ipairs(incremental.sortedKeys(change)) do
            self.program.snapshot:addFileToAffectedFilesPendingEmit(filePath, change[filePath])
        end
    end
    self.program.snapshot.changedFilesSet = collections.NewSyncSet()
    self.program.snapshot.buildInfoEmitPending = true
end

function incremental.collectAllAffectedFiles(ctx, program)
    if program.snapshot.changedFilesSet:Size() == 0 then
        return
    end

    local handler = incremental.newAffectedFilesHandler(ctx, program)
    local wg = core.NewWorkGroup(handler.program.program:SingleThreaded())
    -- result: an insertion ordered set of *ast.SourceFile
    local result = {}
    local resultSet = {}
    incremental.rangeSortedSet(program.snapshot.changedFilesSet, function(file)
        wg:Queue(function()
            for _, affectedFile in ipairs(handler:getFilesAffectedBy(file) or {}) do
                if not resultSet[affectedFile] then
                    resultSet[affectedFile] = true
                    result[#result + 1] = affectedFile
                end
            end
        end)
        return true
    end)
    wg:RunAndWait()

    if incremental.ctxErr(ctx) ~= nil then
        return
    end

    -- For all the affected files, get all the files that would need to change their dts or js files,
    -- update their diagnostics
    wg = core.NewWorkGroup(program.program:SingleThreaded())
    local emitKind = incremental.GetFileEmitKind(program.snapshot.options)
    for _, file in ipairs(result) do
        -- remove the cached semantic diagnostics and handle dts emit and js emit if needed
        local dtsMayChange = handler:getDtsMayChange(file:Path(), emitKind)
        wg:Queue(function()
            handler:handleDtsMayChangeOfAffectedFile(dtsMayChange, file)
        end)
    end
    wg:RunAndWait()

    -- Update the snapshot with the new state
    handler:updateSnapshot()
end
