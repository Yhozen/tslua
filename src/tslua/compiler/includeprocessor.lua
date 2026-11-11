local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")

local includeProcessor = {}
includeProcessor.__index = includeProcessor
compiler.includeProcessor = includeProcessor

function compiler.newIncludeProcessor(fileIncludeReasons, processingDiagnostics)
    return setmetatable({
        fileIncludeReasons = fileIncludeReasons or {},
        processingDiagnostics = processingDiagnostics,
        reasonToReferenceLocation = {},
        includeReasonToRelatedInfo = {},
        redirectAndFileFormat = {},
        redirectAndFileFormatPresent = {},
        computedDiagnostics = nil,
        computedDiagnosticsDone = false,
        compilerOptionsSyntax = nil,
        compilerOptionsSyntaxDone = false,
    }, includeProcessor)
end

function compiler.updateFileIncludeProcessor(p)
    p.includeProcessor = compiler.newIncludeProcessor(p.includeProcessor.fileIncludeReasons, p.includeProcessor.processingDiagnostics)
end

function includeProcessor:getDiagnostics(p)
    if not self.computedDiagnosticsDone then
        self.computedDiagnosticsDone = true
        self.computedDiagnostics = ast.NewDiagnosticsCollection()
        for _, d in ipairs(self.processingDiagnostics or {}) do
            self.computedDiagnostics:Add(d:toDiagnostic(p))
        end
        for _, path in ipairs(compiler.sortedKeys(p.resolvedModules)) do
            for _, _, resolvedModule in compiler.modeAwareCachePairs(p.resolvedModules[path]) do
                for _, diag in ipairs(resolvedModule.resolutionDiagnostics or {}) do
                    self.computedDiagnostics:Add(diag)
                end
            end
        end
        for _, path in ipairs(compiler.sortedKeys(p.typeResolutionsInFile)) do
            for _, _, resolvedTypeRef in compiler.modeAwareCachePairs(p.typeResolutionsInFile[path]) do
                for _, diag in ipairs(resolvedTypeRef.resolutionDiagnostics or {}) do
                    self.computedDiagnostics:Add(diag)
                end
            end
        end
    end
    return self.computedDiagnostics
end

function includeProcessor:addProcessingDiagnostic(...)
    for i = 1, select("#", ...) do
        self.processingDiagnostics = core.Append(self.processingDiagnostics, (select(i, ...)))
    end
end

function includeProcessor:addProcessingDiagnosticsForFileCasing(file, existingCasing, currentCasing, reason)
    local hasReferencedReason = false
    for _, r in ipairs(self.fileIncludeReasons[file] or {}) do
        if compiler.isReferencedFileReason(r) then
            hasReferencedReason = true
            break
        end
    end
    if not compiler.isReferencedFileReason(reason) and hasReferencedReason then
        self:addProcessingDiagnostic(compiler.newProcessingDiagnostic(
            compiler.processingDiagnosticKindExplainingFileInclude,
            compiler.newIncludeExplainingDiagnostic({
                file = file,
                diagnosticReason = reason,
                message = diagnostics.Already_included_file_name_0_differs_from_file_name_1_only_in_casing,
                args = { existingCasing, currentCasing },
            })
        ))
    else
        self:addProcessingDiagnostic(compiler.newProcessingDiagnostic(
            compiler.processingDiagnosticKindExplainingFileInclude,
            compiler.newIncludeExplainingDiagnostic({
                file = file,
                diagnosticReason = reason,
                message = diagnostics.File_name_0_differs_from_already_included_file_name_1_only_in_casing,
                args = { currentCasing, existingCasing },
            })
        ))
    end
end

function includeProcessor:getReferenceLocation(r, program)
    local existing = self.reasonToReferenceLocation[r]
    if existing ~= nil then
        return existing
    end
    local loc = r:getReferencedLocation(program)
    self.reasonToReferenceLocation[r] = loc
    return loc
end

function includeProcessor:getCompilerOptionsObjectLiteralSyntax(program)
    if not self.compilerOptionsSyntaxDone then
        self.compilerOptionsSyntaxDone = true
        local configFile = program.opts.config.configFile
        if configFile ~= nil then
            local compilerOptionsProperty = tsoptions.ForEachTsConfigPropArray(configFile.sourceFile, "compilerOptions", core.Identity)
            if compilerOptionsProperty ~= nil and
                compilerOptionsProperty.initializer ~= nil and
                ast.IsObjectLiteralExpression(compilerOptionsProperty.initializer) then
                self.compilerOptionsSyntax = compilerOptionsProperty.initializer
            end
        else
            self.compilerOptionsSyntax = nil
        end
    end
    return self.compilerOptionsSyntax
end

function includeProcessor:getRelatedInfo(r, program)
    if self.includeReasonToRelatedInfo[r] ~= nil then
        return self.includeReasonToRelatedInfo[r] or nil
    end
    local relatedInfo = r:toRelatedInfo(program)
    -- false records a computed nil
    self.includeReasonToRelatedInfo[r] = relatedInfo or false
    return relatedInfo
end

function includeProcessor:explainRedirectAndImpliedFormat(program, filePath, toFileName)
    if self.redirectAndFileFormatPresent[filePath] then
        return self.redirectAndFileFormat[filePath]
    end
    local file
    local sourceFile = nil
    local redirectsFile = program.redirectFilesByPath ~= nil and program.redirectFilesByPath[filePath] or nil
    if redirectsFile ~= nil then
        file = redirectsFile
    else
        sourceFile = program:GetSourceFileByPath(filePath)
        if sourceFile == nil then
            return nil
        end
        file = sourceFile
    end
    local result = nil
    local source = program:GetSourceOfProjectReferenceIfOutputIncluded(file)
    if source ~= file:FileName() then
        result = core.Append(result, ast.NewCompilerDiagnostic(
            diagnostics.File_is_output_of_project_reference_source_0,
            toFileName(source)
        ))
    end

    if redirectsFile ~= nil then
        local targetFile = program:GetSourceFileByPath(redirectsFile.target)
        result = core.Append(result, ast.NewCompilerDiagnostic(
            diagnostics.File_redirects_to_file_0,
            toFileName(targetFile:FileName())
        ))
    end

    if sourceFile ~= nil and ast.IsExternalOrCommonJSModule(sourceFile) then
        local metaData = program:GetSourceFileMetaData(file:Path())
        local format = program:GetImpliedNodeFormatForEmit(file)
        if format == core.ModuleKind.ESNext then
            if metaData.packageJsonType == "module" then
                result = core.Append(result, ast.NewCompilerDiagnostic(
                    diagnostics.File_is_ECMAScript_module_because_0_has_field_type_with_value_module,
                    toFileName(metaData.packageJsonDirectory .. "/package.json")
                ))
            end
        elseif format == core.ModuleKind.CommonJS then
            if metaData.packageJsonType ~= "" then
                result = core.Append(result, ast.NewCompilerDiagnostic(diagnostics.File_is_CommonJS_module_because_0_has_field_type_whose_value_is_not_module, toFileName(metaData.packageJsonDirectory .. "/package.json")))
            elseif metaData.packageJsonDirectory ~= "" then
                if metaData.packageJsonType == "" then
                    result = core.Append(result, ast.NewCompilerDiagnostic(diagnostics.File_is_CommonJS_module_because_0_does_not_have_field_type, toFileName(metaData.packageJsonDirectory .. "/package.json")))
                end
            else
                result = core.Append(result, ast.NewCompilerDiagnostic(diagnostics.File_is_CommonJS_module_because_package_json_was_not_found))
            end
        end
    end

    self.redirectAndFileFormatPresent[filePath] = true
    self.redirectAndFileFormat[filePath] = result
    return result
end
