local ls = require("tslua.ls")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local change = require("tslua.ls.change")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local modulespecifiers = require("tslua.modulespecifiers")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local strings = require("tslua.module").strings

local LanguageService = ls.LanguageService

-- pathUpdater: func(path) (string, bool)
-- toImport: { newFileName, updated }
-- movedFile: { sourceFile, newFileName }

-- Returns []lsproto.TextDocumentEditOrCreateFileOrRenameFileOrDeleteFile (union tables
-- { renameFile = ... } / { textDocumentEdit = ... }).
function LanguageService:GetEditsForFileRename(ctx, oldURI, newURI)
    local program = self:GetProgram()
    local oldPath = lsproto.DocumentUri_FileName(oldURI)
    local newPath = lsproto.DocumentUri_FileName(newURI)

    local oldToNew = self:createPathUpdater(oldPath, newPath)

    local changeTracker = change.NewTracker(ctx, program:Options(), self:FormatOptions(), self.converters)
    self:updateTsconfigFiles(program, changeTracker, oldToNew, oldPath, newPath)
    self:updateImportsForFileRename(program, changeTracker, oldToNew)

    local documentChanges = nil

    -- When renaming e.g. `foo.d.css.ts` -> `bar.d.css.ts`, also rename `foo.css` -> `bar.css` if it exists.
    if tspath.IsDeclarationFileName(oldPath) and tspath.IsDeclarationFileName(newPath) then
        local dtsExt = tspath.GetDeclarationFileExtension(oldPath)
        local originalExtensions = tspath.GetPossibleOriginalInputExtensionForExtension(dtsExt)
        for _, ext in ipairs(originalExtensions or {}) do
            local oldOriginalPath = tspath.ChangeFullExtension(oldPath, ext)
            if self.host:FileExists(oldOriginalPath) then
                local newDtsExt = tspath.GetDeclarationFileExtension(oldPath)
                local newOriginalExtensions = tspath.GetPossibleOriginalInputExtensionForExtension(newDtsExt)
                if core.FindIndex(newOriginalExtensions, function(e)
                    return e == ext
                end) >= 0 then
                    local newOriginalPath = tspath.ChangeFullExtension(newPath, ext)
                    documentChanges = core.Append(documentChanges, {
                        renameFile = {
                            oldUri = lsconv.FileNameToDocumentURI(oldOriginalPath),
                            newUri = lsconv.FileNameToDocumentURI(newOriginalPath),
                        },
                    })
                end
            end
        end
    end

    local changes = changeTracker:GetChanges()
    -- Go iterates the map in random order; iterate file names sorted for determinism.
    local fileNames = {}
    for fileName in pairs(changes) do
        fileNames[#fileNames + 1] = fileName
    end
    table.sort(fileNames)
    for _, fileName in ipairs(fileNames) do
        local edits = changes[fileName]
        local uri = lsconv.FileNameToDocumentURI(fileName)
        local lspEdits = {}
        for _, edit in ipairs(edits) do
            lspEdits[#lspEdits + 1] = {
                textEdit = edit,
            }
        end
        documentChanges = core.Append(documentChanges, {
            textDocumentEdit = {
                textDocument = { uri = uri },
                edits = lspEdits,
            },
        })
    end

    return documentChanges
end

function LanguageService:createPathUpdater(oldPath, newPath)
    local compareOptions = tspath.NewComparePathsOptions(self:UseCaseSensitiveFileNames(), "")
    local trimmedOldPath = tspath.RemoveTrailingDirectorySeparator(oldPath)
    return function(path)
        if tspath.ComparePaths(path, oldPath, compareOptions) == 0 then
            return newPath, true
        end
        -- Trim the directory prefix ourselves (rather than using
        -- tspath.StartsWithDirectory followed by a separate slice on
        -- len(oldPath)) so the containment check and the suffix we return can
        -- never disagree, and so we don't slice path by a byte count derived
        -- from a canonicalized/differently-cased string: case-folding can
        -- change a path's UTF-8 byte length without changing its rune count
        -- (e.g. the Kelvin sign 'K' folds to the single-byte 'k'), which
        -- could otherwise put len(oldPath) out of range of path.
        local suffix, ok = tspath.TrimFilePathPrefix(path, trimmedOldPath, self:UseCaseSensitiveFileNames())
        if ok and (strings.HasPrefix(suffix, "/") or strings.HasPrefix(suffix, "\\")) then
            return newPath .. suffix, true
        end
        return "", false
    end
end

function LanguageService:updateTsconfigFiles(program, changeTracker, oldToNew, oldPath, newPath)
    local commandLine = program:CommandLine()
    if commandLine == nil or commandLine.configFile == nil then
        return
    end

    local configFile = commandLine.configFile.sourceFile
    if configFile == nil then
        return
    end
    local configDir = tspath.GetDirectoryPath(configFile:FileName())
    local jsonObjectLiteral = ls.getTsConfigObjectLiteralExpression(configFile)
    if jsonObjectLiteral == nil then
        return
    end

    ls.forEachObjectProperty(jsonObjectLiteral, function(property, propertyName)
        if propertyName == "files" or propertyName == "include" or propertyName == "exclude" then
            local foundExactMatch = ls.updatePathsProperty(configFile, configDir, property, changeTracker, oldToNew, self.converters, self:UseCaseSensitiveFileNames())
            if foundExactMatch or propertyName ~= "include" or not ast.IsArrayLiteralExpression(property.initializer) then
                return
            end
            local oldSpec, isDefault = commandLine:GetMatchedIncludeSpec(oldPath)
            if oldSpec ~= "" and not isDefault then
                local newSpec = commandLine:GetMatchedIncludeSpec(newPath)
                if newSpec == "" then
                    local elements = property.initializer:Elements()
                    if core.Len(elements) > 0 then
                        changeTracker:InsertNodeAfter(
                            configFile,
                            elements[#elements],
                            changeTracker.nodeFactory:NewStringLiteral(ls.relativePathFromDirectory(configDir, newPath, self:UseCaseSensitiveFileNames()), ast.TokenFlags.None)
                        )
                    end
                end
            end
        elseif propertyName == "compilerOptions" then
            if not ast.IsObjectLiteralExpression(property.initializer) then
                return
            end
            ls.forEachObjectProperty(property.initializer:AsObjectLiteralExpression(), function(prop, name)
                local option = tsoptions.CommandLineOptionNameMap_Get(tsoptions.CommandLineCompilerOptionsMap, name)
                if option ~= nil then
                    local elementOption = option:Elements()
                    if option.isFilePath or (option.kind == tsoptions.CommandLineOptionKind.CommandLineOptionTypeList and elementOption ~= nil and elementOption.isFilePath) then
                        ls.updatePathsProperty(configFile, configDir, prop, changeTracker, oldToNew, self.converters, self:UseCaseSensitiveFileNames())
                        return
                    end
                end

                if name ~= "paths" or not ast.IsObjectLiteralExpression(prop.initializer) then
                    return
                end
                ls.forEachObjectProperty(prop.initializer:AsObjectLiteralExpression(), function(pathsProperty, _)
                    if not ast.IsArrayLiteralExpression(pathsProperty.initializer) then
                        return
                    end
                    for _, element in ipairs(pathsProperty.initializer:Elements() or {}) do
                        ls.tryUpdateConfigString(configFile, configDir, element, changeTracker, oldToNew, self.converters, self:UseCaseSensitiveFileNames())
                    end
                end)
            end)
        end
    end)
end

function ls.updatePathsProperty(configFile, configDir, property, changeTracker, oldToNew, converters, useCaseSensitiveFileNames)
    local elements = { property.initializer }
    if ast.IsArrayLiteralExpression(property.initializer) then
        elements = property.initializer:Elements() or {}
    end

    local foundExactMatch = false
    for _, element in ipairs(elements) do
        foundExactMatch = ls.tryUpdateConfigString(configFile, configDir, element, changeTracker, oldToNew, converters, useCaseSensitiveFileNames) or foundExactMatch
    end
    return foundExactMatch
end

function ls.tryUpdateConfigString(configFile, configDir, element, changeTracker, oldToNew, converters, useCaseSensitiveFileNames)
    if not ast.IsStringLiteral(element) then
        return false
    end

    local elementFileName = tspath.NormalizePath(tspath.CombinePaths(configDir, element:Text()))
    local updated, ok = oldToNew(elementFileName)
    if not ok then
        return false
    end

    local textRange = core.NewTextRange(scanner.GetTokenPosOfNode(element, configFile, false) + 1, element:End() - 1)
    local lspRange, fidelity = converters:ToLSPRange(configFile, textRange)
    debug.Assert(spanmap.Fidelity_IsExact(fidelity), "config files are not content-mapped")
    changeTracker:ReplaceRangeWithText(configFile, lspRange, ls.relativePathFromDirectory(configDir, updated, useCaseSensitiveFileNames))
    return true
end

function LanguageService:updateRelativePath(oldToNew, oldImportFromPath, newImportFromPath, relativeSpecifier)
    local oldAbsolute = tspath.NormalizePath(tspath.CombinePaths(tspath.GetDirectoryPath(oldImportFromPath), relativeSpecifier))
    local newAbsolute, ok = oldToNew(oldAbsolute)
    if not ok then
        newAbsolute = oldAbsolute
    end
    return ls.relativeImportPathFromDirectory(tspath.GetDirectoryPath(newImportFromPath), newAbsolute, self:UseCaseSensitiveFileNames())
end

function LanguageService:updateImportsForFileRename(program, changeTracker, oldToNew)
    local allFiles = program:GetSourceFiles()
    local c, done = program:GetTypeChecker(nil)
    local moduleSpecifierPreferences = self:UserPreferences():ModuleSpecifierPreferences()

    local movedFiles = {}
    for _, sourceFile in ipairs(allFiles or {}) do
        local newFileName, ok = oldToNew(sourceFile:OriginalFileName())
        if ok then
            movedFiles[#movedFiles + 1] = { sourceFile = sourceFile, newFileName = newFileName }
        end
    end

    for _, sourceFile in ipairs(allFiles or {}) do
        local oldFileName = sourceFile:OriginalFileName()
        local newFromOld, fileMoved = oldToNew(oldFileName)
        local newImportFromPath = oldFileName
        if fileMoved then
            newImportFromPath = newFromOld
        end

        for _, ref in ipairs(sourceFile.referencedFiles or {}) do
            if tspath.IsExternalModuleNameRelative(ref.fileName) then
                local updated = self:updateRelativePath(oldToNew, oldFileName, newImportFromPath, ref.fileName)
                if updated ~= ref.fileName then
                    changeTracker:ReplaceTextRangeWithText(sourceFile, core.NewTextRange(ref.pos, ref.end_), updated)
                end
            end
        end

        for _, importStringLiteral in ipairs(sourceFile:Imports() or {}) do
            local updated = self:getUpdatedImportSpecifier(program, c, sourceFile, importStringLiteral, oldToNew, movedFiles, newImportFromPath, fileMoved, moduleSpecifierPreferences)
            if updated ~= "" and updated ~= importStringLiteral:Text() then
                changeTracker:ReplaceTextRangeWithText(sourceFile, ls.createStringTextRange(sourceFile, importStringLiteral), updated)
            end
        end
    end
    if done ~= nil then
        done()
    end
end

-- We assume the source file did not move to a different program.
function LanguageService:getUpdatedImportSpecifier(program, c, sourceFile, importLiteral, oldToNew, movedFiles, newImportFromPath, importingSourceFileMoved, userPreferences)
    local importedModuleSymbol = c:GetSymbolAtLocation(importLiteral)
    if ls.isAmbientModuleSymbol(importedModuleSymbol) then
        return ""
    end

    local target = ls.getSourceFileToImport(program, sourceFile, importLiteral, oldToNew)

    if target == nil then
        -- First fall back: try every file affected by the rename to see if any of them would match the import specifier, and if so, obtain the updated specifier for that file.
        local updated = ls.getUpdatedImportSpecifierFromMovedSourceFiles(program, sourceFile, importLiteral, movedFiles, newImportFromPath, userPreferences)
        if updated ~= "" and updated ~= importLiteral:Text() then
            return updated
        end
        -- Fall back to a regular path update for unresolved module.
        if tspath.IsExternalModuleNameRelative(importLiteral:Text()) then
            return self:updateRelativePath(oldToNew, sourceFile:FileName(), newImportFromPath, importLiteral:Text())
        end
        return ""
    end

    -- Optimization: neither the importing or imported file changed.
    if not target.updated and not (importingSourceFileMoved and tspath.IsExternalModuleNameRelative(importLiteral:Text())) then
        return ""
    end

    local updated = modulespecifiers.UpdateModuleSpecifier(
        program:Options(),
        program,
        sourceFile,
        newImportFromPath,
        importLiteral:Text(),
        target.newFileName,
        userPreferences,
        modulespecifiers.ModuleSpecifierOptions_new({
            overrideImportMode = program:GetModeForUsageLocation(sourceFile, importLiteral),
        })
    )
    return updated
end

function ls.getSourceFileToImport(program, sourceFile, importLiteral, oldToNew)
    local resolved = program:GetResolvedModuleFromModuleSpecifier(sourceFile, importLiteral)
    if resolved ~= nil and resolved.resolvedFileName ~= "" then
        local oldFileName = resolved.resolvedFileName
        local newFileName, ok = oldToNew(oldFileName)
        if ok then
            return { newFileName = newFileName, updated = true }
        end
        return { newFileName = oldFileName, updated = false }
    end

    return nil
end

-- As a fall back for unresolved modules, we'll check every file affected by the rename to see if any of them would match
-- the import specifier, and if so, we'll obtain the updated specifier for that file.
function ls.getUpdatedImportSpecifierFromMovedSourceFiles(program, sourceFile, importLiteral, movedFiles, importingSourceFileName, userPreferences)
    local resolutionMode = program:GetModeForUsageLocation(sourceFile, importLiteral)
    for _, candidate in ipairs(movedFiles) do
        local oldSpecifier = modulespecifiers.UpdateModuleSpecifier(
            program:Options(),
            program,
            sourceFile,
            importingSourceFileName,
            importLiteral:Text(),
            candidate.sourceFile:FileName(),
            userPreferences,
            modulespecifiers.ModuleSpecifierOptions_new({
                overrideImportMode = resolutionMode,
            })
        )
        if oldSpecifier == importLiteral:Text() then
            return modulespecifiers.UpdateModuleSpecifier(
                program:Options(),
                program,
                sourceFile,
                importingSourceFileName,
                importLiteral:Text(),
                candidate.newFileName,
                userPreferences,
                modulespecifiers.ModuleSpecifierOptions_new({
                    overrideImportMode = resolutionMode,
                })
            )
        end
    end
    return ""
end

function ls.createStringTextRange(sourceFile, node)
    return core.NewTextRange(scanner.GetTokenPosOfNode(node, sourceFile, false) + 1, node:End() - 1)
end

function ls.getTsConfigObjectLiteralExpression(tsConfigSourceFile)
    if tsConfigSourceFile ~= nil and tsConfigSourceFile.statements ~= nil and #tsConfigSourceFile.statements.nodes > 0 then
        local expression = tsConfigSourceFile.statements.nodes[1]:Expression()
        if ast.IsObjectLiteralExpression(expression) then
            return expression:AsObjectLiteralExpression()
        end
    end
    return nil
end

function ls.forEachObjectProperty(objectLiteral, cb)
    if objectLiteral == nil then
        return
    end
    for _, property in ipairs(objectLiteral.properties.nodes) do
        if ast.IsPropertyAssignment(property) then
            local name, ok = ast.TryGetTextOfPropertyName(property:Name())
            if ok then
                cb(property:AsPropertyAssignment(), name)
            end
        end
    end
end

function ls.relativePathFromDirectory(fromDirectory, to, useCaseSensitiveFileNames)
    return tspath.GetRelativePathFromDirectory(fromDirectory, to, tspath.NewComparePathsOptions(useCaseSensitiveFileNames, ""))
end

function ls.relativeImportPathFromDirectory(fromDirectory, to, useCaseSensitiveFileNames)
    return tspath.EnsurePathIsNonModuleName(ls.relativePathFromDirectory(fromDirectory, to, useCaseSensitiveFileNames))
end

function ls.isAmbientModuleSymbol(symbol)
    if symbol == nil then
        return false
    end
    return core.Some(symbol.declarations, ast.IsModuleWithStringLiteralName)
end
