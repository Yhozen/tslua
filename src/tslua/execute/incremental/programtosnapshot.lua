local incremental = require("tslua.execute.incremental")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local collections = require("tslua.collections")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local FileEmitKind = incremental.FileEmitKind
local isTrue = core.Tristate_IsTrue

function incremental.programToSnapshot(program, oldProgram, hashWithText)
    if oldProgram ~= nil and oldProgram.program == program then
        return oldProgram.snapshot
    end
    local snapshot = incremental.newSnapshot({
        options = program:Options(),
        hashWithText = hashWithText,
        checkPending = isTrue(program:Options().noCheck),
    })
    local to = incremental.newToProgramSnapshot(program, oldProgram, snapshot)

    if to.snapshot:canUseIncrementalState() then
        to:reuseFromOldProgram()
        to:computeProgramFileChanges()
        to:handleFileDelete()
        to:handleGlobalScopeChange()
        to:handlePendingEmit()
        to:handlePendingCheck()
    end
    return snapshot
end

local toProgramSnapshot = {}
toProgramSnapshot.__index = toProgramSnapshot
incremental.toProgramSnapshot = toProgramSnapshot

function incremental.newToProgramSnapshot(program, oldProgram, snapshot)
    return setmetatable({
        program = program,
        oldProgram = oldProgram,
        snapshot = snapshot,
        globalFileRemoved = false,
    }, toProgramSnapshot)
end

function toProgramSnapshot:reuseFromOldProgram()
    if self.oldProgram ~= nil then
        if isTrue(self.snapshot.options.composite) then
            self.snapshot.latestChangedDtsFile = self.oldProgram.snapshot.latestChangedDtsFile
        end
        -- Copy old snapshot's changed files set
        incremental.rangeSortedSet(self.oldProgram.snapshot.changedFilesSet, function(key)
            self.snapshot.changedFilesSet:Add(key)
            return true
        end)
        incremental.rangeSorted(self.oldProgram.snapshot.affectedFilesPendingEmit, function(key, emitKind)
            self.snapshot.affectedFilesPendingEmit:Store(key, emitKind)
            return true
        end)
        self.snapshot.buildInfoEmitPending = self.oldProgram.snapshot.buildInfoEmitPending
        self.snapshot.hasErrorsFromOldState = self.oldProgram.snapshot.hasErrors
        self.snapshot.hasSemanticErrorsFromOldState = self.oldProgram.snapshot.hasSemanticErrors
        self.snapshot.packageJsonsFromOldState = self.oldProgram.snapshot.packageJsons
        self.snapshot.missingPackageJsonsFromOldState = self.oldProgram.snapshot.missingPackageJsons
    else
        self.snapshot.buildInfoEmitPending = self.snapshot.options:IsIncremental()
    end
end

function toProgramSnapshot:computeProgramFileChanges()
    local canCopySemanticDiagnostics = self.oldProgram ~= nil and
        not tsoptions.CompilerOptionsAffectSemanticDiagnostics(self.oldProgram.snapshot.options, self.program:Options())
    -- We can only reuse emit signatures (i.e. .d.ts signatures) if the .d.ts file is unchanged,
    -- which will eg be depedent on change in options like declarationDir and outDir options are unchanged.
    -- We need to look in oldState.compilerOptions, rather than oldCompilerOptions (i.e.we need to disregard useOldState) because
    -- oldCompilerOptions can be undefined if there was change in say module from None to some other option
    -- which would make useOldState as false since we can now use reference maps that are needed to track what to emit, what to check etc
    -- but that option change does not affect d.ts file name so emitSignatures should still be reused.
    local canCopyEmitSignatures = isTrue(self.snapshot.options.composite) and
        self.oldProgram ~= nil and
        not tsoptions.CompilerOptionsAffectDeclarationPath(self.oldProgram.snapshot.options, self.program:Options())
    local copyDeclarationFileDiagnostics = canCopySemanticDiagnostics and
        isTrue(self.snapshot.options.skipLibCheck) == isTrue(self.oldProgram.snapshot.options.skipLibCheck)
    local copyLibFileDiagnostics = copyDeclarationFileDiagnostics and
        isTrue(self.snapshot.options.skipDefaultLibCheck) == isTrue(self.oldProgram.snapshot.options.skipDefaultLibCheck)

    local files = self.program:GetSourceFiles()
    local wg = core.NewWorkGroup(self.program:SingleThreaded())
    for _, file in ipairs(files) do
        wg:Queue(function()
            local versionText = file:Text()
            if file:ContentMapper() ~= "" then
                versionText = file:OriginalText() .. "\0" .. file:ContentMapperTransformIdentity()
            end
            local version = self.snapshot:computeHash(versionText)
            local impliedNodeFormat = self.program:GetSourceFileMetaData(file:Path()).impliedNodeFormat
            local affectsGlobalScope = incremental.fileAffectsGlobalScope(file)
            local signature = ""
            local newReferences = incremental.getReferencedFiles(self.program, file)
            if newReferences ~= nil then
                self.snapshot.referencedMap:storeReferences(file:Path(), newReferences)
            end
            if self.oldProgram ~= nil then
                local oldFileInfo, ok = self.oldProgram.snapshot.fileInfos:Load(file:Path())
                if ok then
                    signature = oldFileInfo.signature
                    if oldFileInfo.version ~= version or oldFileInfo.affectsGlobalScope ~= affectsGlobalScope or oldFileInfo.impliedNodeFormat ~= impliedNodeFormat then
                        self.snapshot:addFileToChangeSet(file:Path())
                    else
                        local oldReferences = self.oldProgram.snapshot.referencedMap:getReferences(file:Path())
                        if not collections.Set.Equals(newReferences, oldReferences) then
                            -- Referenced files changed
                            self.snapshot:addFileToChangeSet(file:Path())
                        elseif newReferences ~= nil then
                            for _, refPath in ipairs(incremental.sortedKeys(newReferences:Keys())) do
                                if self.program:GetSourceFileByPath(refPath) == nil then
                                    local _, refOk = self.oldProgram.snapshot.fileInfos:Load(refPath)
                                    if refOk then
                                        -- Referenced file was deleted in the new program
                                        self.snapshot:addFileToChangeSet(file:Path())
                                        break
                                    end
                                end
                            end
                        end
                    end
                else
                    self.snapshot:addFileToChangeSet(file:Path())
                end
                if not self.snapshot.changedFilesSet:Has(file:Path()) then
                    local emitDiagnostics, emitOk = self.oldProgram.snapshot.emitDiagnosticsPerFile:Load(file:Path())
                    if emitOk then
                        self.snapshot.emitDiagnosticsPerFile:Store(file:Path(), incremental.repopulateDiagnosticsOfFile(emitDiagnostics, self.program, file))
                    end
                    if canCopySemanticDiagnostics then
                        if (not file.isDeclarationFile or copyDeclarationFileDiagnostics) and
                            (not self.program:IsSourceFileDefaultLibrary(file:Path()) or copyLibFileDiagnostics) then
                            -- Unchanged file copy diagnostics
                            local diags, diagsOk = self.oldProgram.snapshot.semanticDiagnosticsPerFile:Load(file:Path())
                            if diagsOk then
                                self.snapshot.semanticDiagnosticsPerFile:Store(file:Path(), incremental.repopulateDiagnosticsOfFile(diags, self.program, file))
                            end
                        end
                    end
                end
                if canCopyEmitSignatures then
                    local oldEmitSignature, sigOk = self.oldProgram.snapshot.emitSignatures:Load(file:Path())
                    if sigOk then
                        self.snapshot.emitSignatures:Store(file:Path(), oldEmitSignature:getNewEmitSignature(self.oldProgram.snapshot.options, self.snapshot.options))
                    end
                end
            else
                self.snapshot:addFileToAffectedFilesPendingEmit(file:Path(), incremental.GetFileEmitKind(self.snapshot.options))
                signature = version
            end
            self.snapshot.fileInfos:Store(file:Path(), incremental.newFileInfo({
                version = version,
                signature = signature,
                affectsGlobalScope = affectsGlobalScope,
                impliedNodeFormat = impliedNodeFormat,
            }))
        end)
    end
    wg:RunAndWait()
end

function toProgramSnapshot:handleFileDelete()
    if self.oldProgram ~= nil then
        -- If the global file is removed, add all files as changed
        incremental.rangeSorted(self.oldProgram.snapshot.fileInfos, function(filePath, oldInfo)
            local _, ok = self.snapshot.fileInfos:Load(filePath)
            if not ok then
                if oldInfo.affectsGlobalScope then
                    for _, file in ipairs(self.snapshot:getAllFilesExcludingDefaultLibraryFile(self.program, nil)) do
                        self.snapshot:addFileToChangeSet(file:Path())
                    end
                    self.globalFileRemoved = true
                else
                    self.snapshot.buildInfoEmitPending = true
                end
                return false
            end
            return true
        end)
    end
end

function toProgramSnapshot:handleGlobalScopeChange()
    if self.oldProgram == nil or self.globalFileRemoved then
        return
    end
    local globalScopeLost = false
    incremental.rangeSorted(self.oldProgram.snapshot.fileInfos, function(filePath, oldInfo)
        if not oldInfo.affectsGlobalScope then
            return true
        end
        local newInfo, ok = self.snapshot.fileInfos:Load(filePath)
        if ok and not newInfo.affectsGlobalScope then
            globalScopeLost = true
            return false
        end
        return true
    end)
    if globalScopeLost then
        for _, file in ipairs(self.snapshot:getAllFilesExcludingDefaultLibraryFile(self.program, nil)) do
            self.snapshot:addFileToChangeSet(file:Path())
        end
    end
end

function toProgramSnapshot:handlePendingEmit()
    if self.oldProgram ~= nil and not self.globalFileRemoved then
        -- If options affect emit, then we need to do complete emit per compiler options
        -- otherwise only the js or dts that needs to emitted because its different from previously emitted options
        local pendingEmitKind
        if tsoptions.CompilerOptionsAffectEmit(self.oldProgram.snapshot.options, self.snapshot.options) then
            pendingEmitKind = incremental.GetFileEmitKind(self.snapshot.options)
        else
            pendingEmitKind = incremental.getPendingEmitKindWithOptions(self.snapshot.options, self.oldProgram.snapshot.options)
        end
        if pendingEmitKind ~= FileEmitKind.None then
            -- Add all files to affectedFilesPendingEmit since emit changed
            for _, file in ipairs(self.program:GetSourceFiles()) do
                -- Add to affectedFilesPending emit only if not changed since any changed file will do full emit
                if not self.snapshot.changedFilesSet:Has(file:Path()) then
                    self.snapshot:addFileToAffectedFilesPendingEmit(file:Path(), pendingEmitKind)
                end
            end
            self.snapshot.buildInfoEmitPending = true
        end
    end
end

function toProgramSnapshot:handlePendingCheck()
    if self.oldProgram ~= nil and
        self.snapshot.semanticDiagnosticsPerFile:Size() ~= #self.program:GetSourceFiles() and
        self.oldProgram.snapshot.checkPending ~= self.snapshot.checkPending then
        self.snapshot.buildInfoEmitPending = true
    end
end

function incremental.fileAffectsGlobalScope(file)
    binder.BindSourceFile(file)
    -- if file contains anything that augments to global scope we need to build them as if
    -- they are global files as well as module
    if core.Some(file.moduleAugmentations, function(augmentation)
        return ast.IsGlobalScopeAugmentation(augmentation.parent)
    end) then
        return true
    end

    if ast.IsExternalOrCommonJSModule(file) or ast.IsJsonSourceFile(file) then
        return false
    end

    -- For script files that contains only ambient external modules, although they are not actually external module files,
    -- they can only be consumed via importing elements from them. Regular script files cannot consume them. Therefore,
    -- there are no point to rebuild all script files if these special files have changed. However, if any statement
    -- in the file is not ambient external module, we treat it as a regular script file.
    return file.statements ~= nil and
        file.statements.nodes ~= nil and
        core.Some(file.statements.nodes, function(stmt)
            return not ast.IsModuleWithStringLiteralName(stmt)
        end)
end

function incremental.addReferencedFilesFromSymbol(file, referencedFiles, symbol)
    if symbol == nil then
        return
    end
    for _, declaration in ipairs(symbol.declarations or {}) do
        local fileOfDecl = ast.GetSourceFileOfNode(declaration)
        if fileOfDecl ~= nil then
            if file ~= fileOfDecl then
                referencedFiles:Add(fileOfDecl:Path())
            end
        end
    end
end

-- Get the module source file and all augmenting files from the import name node from file
function incremental.addReferencedFilesFromImportLiteral(file, referencedFiles, c, importName)
    local symbol = c:GetSymbolAtLocation(importName)
    incremental.addReferencedFilesFromSymbol(file, referencedFiles, symbol)
end

-- Gets the path to reference file from file name, it could be resolvedPath if present otherwise path
function incremental.addReferencedFileFromFileName(program, fileName, referencedFiles, sourceFileDirectory)
    local redirect = program:GetParseFileRedirect(fileName)
    if redirect ~= "" then
        referencedFiles:Add(tspath.ToPath(redirect, program:GetCurrentDirectory(), program:UseCaseSensitiveFileNames()))
    else
        referencedFiles:Add(tspath.ToPath(fileName, sourceFileDirectory, program:UseCaseSensitiveFileNames()))
    end
end

-- Gets the referenced files for a file from the program with values for the keys as referenced file's path to be true
function incremental.getReferencedFiles(program, file)
    local referencedFiles = collections.NewSet()

    -- We need to use a set here since the code can contain the same import twice,
    -- but that will only be one dependency.
    -- To avoid invernal conversion, the key of the referencedFiles map must be of type Path
    local c, done = program:GetTypeCheckerForFileExclusive(nil, file)
    for _, importName in ipairs(file:Imports() or {}) do
        incremental.addReferencedFilesFromImportLiteral(file, referencedFiles, c, importName)
    end

    local sourceFileDirectory = tspath.GetDirectoryPath(file:FileName())
    -- Handle triple slash references
    for _, referencedFile in ipairs(file.referencedFiles or {}) do
        incremental.addReferencedFileFromFileName(program, referencedFile.fileName, referencedFiles, sourceFileDirectory)
    end

    -- Handle type reference directives
    local typeRefsInFile = program:GetResolvedTypeReferenceDirectives()[file:Path()]
    if typeRefsInFile ~= nil then
        for _, _, typeRef in compiler.modeAwareCachePairs(typeRefsInFile) do
            if typeRef.resolvedFileName ~= "" then
                incremental.addReferencedFileFromFileName(program, typeRef.resolvedFileName, referencedFiles, sourceFileDirectory)
            end
        end
    end

    -- Add module augmentation as references
    for _, moduleName in ipairs(file.moduleAugmentations or {}) do
        if ast.IsStringLiteral(moduleName) then
            incremental.addReferencedFilesFromImportLiteral(file, referencedFiles, c, moduleName)
        end
    end

    -- From ambient modules
    for _, ambientModule in ipairs(c:GetAmbientModules() or {}) do
        incremental.addReferencedFilesFromSymbol(file, referencedFiles, ambientModule)
    end
    if done ~= nil then
        done()
    end
    return core.IfElse(referencedFiles:Len() > 0, referencedFiles, nil)
end

-- repopulateDiagnosticsOfFile repopulates diagnostic chains that depend on program state.
-- When diagnostics are copied from a previous build, their message chains may reference
-- stale program state (e.g., resolved module alternate results, package.json scope).
-- This function recomputes those chains using the current program's state.
function incremental.repopulateDiagnosticsOfFile(diags, p, file)
    if diags.diagnostics ~= nil then
        local repopulated = incremental.repopulateDiagnosticsList(diags.diagnostics, p, file)
        if repopulated == nil then
            return diags
        end
        return incremental.newDiagnosticsOrBuildInfoDiagnosticsWithFileName(repopulated, nil)
    end
    -- buildInfoDiagnostics will be repopulated via toDiagnostic's repopulateInfo handling
    return diags
end

-- repopulateDiagnosticsList repopulates diagnostic chains in a list of diagnostics.
-- Returns nil if no diagnostics needed repopulation (i.e., no changes were made).
function incremental.repopulateDiagnosticsList(diags, p, file)
    local changed = false
    local result = {}
    for i, d in ipairs(diags) do
        local repopulated = incremental.repopulateDiagnosticMessageChain(d:MessageChain(), p, file)
        if repopulated ~= nil then
            local clone = d:Clone()
            clone:SetMessageChain(repopulated)
            result[i] = clone
            changed = true
        else
            result[i] = d
        end
    end
    if not changed then
        return nil
    end
    return result
end

-- repopulateDiagnosticMessageChain repopulates chains that have repopulate info.
-- Returns nil if no changes were made.
function incremental.repopulateDiagnosticMessageChain(chain, p, file)
    if core.Len(chain) == 0 then
        return nil
    end
    local changed = false
    local result = {}
    for i, c in ipairs(chain) do
        if c:RepopulateInfo() ~= nil then
            -- Convert to buildInfoDiagnosticWithFileName and repopulate
            local b = incremental.newBuildInfoDiagnosticWithFileName({
                pos = c:Pos(),
                end_ = c:End(),
                code = c:Code(),
                category = c:Category(),
                source = c:Source(),
                messageText = c:MessageText(),
                messageKey = c:MessageKey(),
                messageArgs = c:MessageArgs(),
                repopulateInfo = c:RepopulateInfo(),
            })
            -- Recursively handle nested chains
            for _, nested in ipairs(c:MessageChain() or {}) do
                b.messageChain = core.Append(b.messageChain, incremental.astDiagToBuildInfoDiag(nested))
            end
            result[i] = incremental.repopulateDiagnosticChain(b, p, file)
            changed = true
        else
            -- Check nested chains
            local nested = incremental.repopulateDiagnosticMessageChain(c:MessageChain(), p, file)
            if nested ~= nil then
                local clone = c:Clone()
                clone:SetMessageChain(nested)
                result[i] = clone
                changed = true
            else
                result[i] = c
            end
        end
    end
    if not changed then
        return nil
    end
    return result
end

function incremental.astDiagToBuildInfoDiag(d)
    local b = incremental.newBuildInfoDiagnosticWithFileName({
        pos = d:Pos(),
        end_ = d:End(),
        code = d:Code(),
        category = d:Category(),
        source = d:Source(),
        messageText = d:MessageText(),
        messageKey = d:MessageKey(),
        messageArgs = d:MessageArgs(),
        repopulateInfo = d:RepopulateInfo(),
    })
    for _, nested in ipairs(d:MessageChain() or {}) do
        b.messageChain = core.Append(b.messageChain, incremental.astDiagToBuildInfoDiag(nested))
    end
    return b
end
