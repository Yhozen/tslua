local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

-- References from file
compiler.fileIncludeKindImport = 0
compiler.fileIncludeKindReferenceFile = 1
compiler.fileIncludeKindTypeReferenceDirective = 2
compiler.fileIncludeKindLibReferenceDirective = 3

compiler.fileIncludeKindRootFile = 4
compiler.fileIncludeKindLibFile = 5
compiler.fileIncludeKindAutomaticTypeDirectiveFile = 6
compiler.fileIncludeKindContentMapperSupplemental = 7

-- FileIncludeReason: { kind, data, relativeFileNameDiag, diag }
local FileIncludeReason = {}
FileIncludeReason.__index = FileIncludeReason
compiler.FileIncludeReason = FileIncludeReason

function compiler.newFileIncludeReason(kind, data)
    return setmetatable({
        kind = kind,
        data = data,
        relativeFileNameDiagDone = false,
        diagDone = false,
    }, FileIncludeReason)
end

-- referencedFileData: { file = tspath.Path, index = int, synthetic = *ast.Node }
function compiler.newReferencedFileData(file, index, synthetic)
    return { file = file, index = index, synthetic = synthetic }
end

-- referenceFileLocation: { file, node, ref, packageId, isSynthetic }
local referenceFileLocation = {}
referenceFileLocation.__index = referenceFileLocation
compiler.referenceFileLocation = referenceFileLocation

function compiler.newReferenceFileLocation(fields)
    return setmetatable({
        file = fields.file,
        node = fields.node,
        ref = fields.ref,
        packageId = fields.packageId,
        isSynthetic = fields.isSynthetic or false,
    }, referenceFileLocation)
end

function referenceFileLocation:text()
    if self.node ~= nil then
        if not ast.NodeIsSynthesized(self.node) then
            local text = self.file:Text()
            return string.sub(text, scanner.SkipTrivia(text, self.node.loc:Pos()) + 1, self.node:End())
        else
            return '"' .. self.node:Text() .. '"'
        end
    else
        return string.sub(self.file:Text(), self.ref:Pos() + 1, self.ref:End())
    end
end

function referenceFileLocation:diagnosticAt(message, ...)
    if self.node ~= nil then
        return tsoptions.CreateDiagnosticForNodeInSourceFile(self.file, self.node, message, ...)
    else
        return ast.NewDiagnostic(self.file, core.NewTextRange(self.ref:Pos(), self.ref:End()), message, ...)
    end
end

-- automaticTypeDirectiveFileData: { typeReference = string, packageId = module.PackageId }
function compiler.newAutomaticTypeDirectiveFileData(typeReference, packageId)
    return { typeReference = typeReference, packageId = packageId }
end

function FileIncludeReason:asIndex()
    return self.data
end

function FileIncludeReason:asLibFileIndex()
    local index = self.data
    if math.type(index) == "integer" then
        return index, true
    end
    return 0, false
end

-- Go (*FileIncludeReason).isReferencedFile, which accepts a nil receiver.
function compiler.isReferencedFileReason(r)
    return r ~= nil and r.kind <= compiler.fileIncludeKindLibReferenceDirective
end

function FileIncludeReason:isReferencedFile()
    return compiler.isReferencedFileReason(self)
end

function FileIncludeReason:asReferencedFileData()
    return self.data
end

function FileIncludeReason:asAutomaticTypeDirectiveFileData()
    return self.data
end

function FileIncludeReason:getReferencedLocation(program)
    local ref = self:asReferencedFileData()
    local file = program:GetSourceFileByPath(ref.file)
    if self.kind == compiler.fileIncludeKindImport then
        local specifier = nil
        local isSynthetic = false
        local imports = file:Imports()
        if ref.synthetic ~= nil then
            specifier = ref.synthetic
            isSynthetic = true
        elseif ref.index < #imports then
            specifier = imports[ref.index + 1]
        else
            local augIndex = #imports
            for _, imp in ipairs(file.moduleAugmentations or {}) do
                if imp.kind == ast.Kind.StringLiteral then
                    if augIndex == ref.index then
                        specifier = imp
                        break
                    end
                    augIndex = augIndex + 1
                end
            end
        end
        local resolution = program:GetResolvedModuleFromModuleSpecifier(file, specifier)
        return compiler.newReferenceFileLocation({
            file = file,
            node = specifier,
            packageId = resolution.packageId,
            isSynthetic = isSynthetic,
        })
    elseif self.kind == compiler.fileIncludeKindReferenceFile then
        return compiler.newReferenceFileLocation({
            file = file,
            ref = file.referencedFiles[ref.index + 1],
        })
    elseif self.kind == compiler.fileIncludeKindTypeReferenceDirective then
        return compiler.newReferenceFileLocation({
            file = file,
            ref = file.typeReferenceDirectives[ref.index + 1],
        })
    elseif self.kind == compiler.fileIncludeKindLibReferenceDirective then
        return compiler.newReferenceFileLocation({
            file = file,
            ref = file.libReferenceDirectives[ref.index + 1],
        })
    else
        error("unknown reason: " .. tostring(self.kind), 0)
    end
end

function FileIncludeReason:toDiagnostic(program, relativeFileName)
    if relativeFileName then
        if not self.relativeFileNameDiagDone then
            self.relativeFileNameDiagDone = true
            self.relativeFileNameDiag = self:computeDiagnostic(program, function(fileName)
                return tspath.GetRelativePathFromDirectory(program:GetCurrentDirectory(), fileName, program.comparePathsOptions)
            end)
        end
        return self.relativeFileNameDiag
    else
        if not self.diagDone then
            self.diagDone = true
            self.diag = self:computeDiagnostic(program, function(fileName) return fileName end)
        end
        return self.diag
    end
end

function FileIncludeReason:computeDiagnostic(program, toFileName)
    if self:isReferencedFile() then
        return self:computeReferenceFileDiagnostic(program, toFileName)
    end
    local kind = self.kind
    if kind == compiler.fileIncludeKindRootFile then
        if program.opts.config.configFile ~= nil then
            local config = program.opts.config
            local fileName = tspath.GetNormalizedAbsolutePath(config:FileNames()[self:asIndex() + 1], program:GetCurrentDirectory())
            local matchedFileSpec = config:GetMatchedFileSpec(fileName)
            if matchedFileSpec ~= "" then
                return ast.NewCompilerDiagnostic(diagnostics.Part_of_files_list_in_tsconfig_json, matchedFileSpec, toFileName(fileName))
            end
            local matchedIncludeSpec, isDefaultIncludeSpec = config:GetMatchedIncludeSpec(fileName)
            if matchedIncludeSpec ~= "" then
                if isDefaultIncludeSpec then
                    return ast.NewCompilerDiagnostic(diagnostics.Matched_by_default_include_pattern_Asterisk_Asterisk_Slash_Asterisk)
                else
                    return ast.NewCompilerDiagnostic(diagnostics.Matched_by_include_pattern_0_in_1, matchedIncludeSpec, toFileName(config:ConfigName()))
                end
            else
                return ast.NewCompilerDiagnostic(diagnostics.Root_file_specified_for_compilation)
            end
        else
            return ast.NewCompilerDiagnostic(diagnostics.Root_file_specified_for_compilation)
        end
    elseif kind == compiler.fileIncludeKindAutomaticTypeDirectiveFile then
        local data = self:asAutomaticTypeDirectiveFileData()
        if not program:Options():UsesWildcardTypes() then
            if compiler.packageIdName(data.packageId) ~= "" then
                return ast.NewCompilerDiagnostic(diagnostics.Entry_point_of_type_library_0_specified_in_compilerOptions_with_packageId_1, data.typeReference, compiler.packageIdString(data.packageId))
            else
                return ast.NewCompilerDiagnostic(diagnostics.Entry_point_of_type_library_0_specified_in_compilerOptions, data.typeReference)
            end
        else
            if compiler.packageIdName(data.packageId) ~= "" then
                return ast.NewCompilerDiagnostic(diagnostics.Entry_point_for_implicit_type_library_0_with_packageId_1, data.typeReference, compiler.packageIdString(data.packageId))
            else
                return ast.NewCompilerDiagnostic(diagnostics.Entry_point_for_implicit_type_library_0, data.typeReference)
            end
        end
    elseif kind == compiler.fileIncludeKindLibFile then
        local index, ok = self:asLibFileIndex()
        if ok then
            return ast.NewCompilerDiagnostic(diagnostics.Library_0_specified_in_compilerOptions, program:Options().lib[index + 1])
        end
        local target = core.ScriptTarget_String(program:Options():GetEmitScriptTarget())
        if target ~= "" then
            return ast.NewCompilerDiagnostic(diagnostics.Default_library_for_target_0, target)
        else
            return ast.NewCompilerDiagnostic(diagnostics.Default_library)
        end
    elseif kind == compiler.fileIncludeKindContentMapperSupplemental then
        local canonical = program:GetSourceFileByPath(self.data)
        return ast.NewCompilerDiagnostic(diagnostics.Supplemental_virtual_file_produced_by_the_content_mapper_for_file_0, toFileName(canonical:FileName()))
    else
        error("unknown reason: " .. tostring(kind), 0)
    end
end

function FileIncludeReason:computeReferenceFileDiagnostic(program, toFileName)
    local referenceLocation = program.includeProcessor:getReferenceLocation(self, program)
    local referenceText = referenceLocation:text()
    local kind = self.kind
    local pkgName = compiler.packageIdName(referenceLocation.packageId)
    if kind == compiler.fileIncludeKindImport then
        if not referenceLocation.isSynthetic then
            if pkgName ~= "" then
                return ast.NewCompilerDiagnostic(diagnostics.Imported_via_0_from_file_1_with_packageId_2, referenceText, toFileName(referenceLocation.file:FileName()), compiler.packageIdString(referenceLocation.packageId))
            else
                return ast.NewCompilerDiagnostic(diagnostics.Imported_via_0_from_file_1, referenceText, toFileName(referenceLocation.file:FileName()))
            end
        end
        local specifier = program.importHelpersImportSpecifiers ~= nil and program.importHelpersImportSpecifiers[referenceLocation.file:Path()] or nil
        if specifier ~= nil and specifier == referenceLocation.node then
            if pkgName ~= "" then
                return ast.NewCompilerDiagnostic(diagnostics.Imported_via_0_from_file_1_with_packageId_2_to_import_importHelpers_as_specified_in_compilerOptions, referenceText, toFileName(referenceLocation.file:FileName()), compiler.packageIdString(referenceLocation.packageId))
            else
                return ast.NewCompilerDiagnostic(diagnostics.Imported_via_0_from_file_1_to_import_importHelpers_as_specified_in_compilerOptions, referenceText, toFileName(referenceLocation.file:FileName()))
            end
        else
            if pkgName ~= "" then
                return ast.NewCompilerDiagnostic(diagnostics.Imported_via_0_from_file_1_with_packageId_2_to_import_jsx_and_jsxs_factory_functions, referenceText, toFileName(referenceLocation.file:FileName()), compiler.packageIdString(referenceLocation.packageId))
            else
                return ast.NewCompilerDiagnostic(diagnostics.Imported_via_0_from_file_1_to_import_jsx_and_jsxs_factory_functions, referenceText, toFileName(referenceLocation.file:FileName()))
            end
        end
    elseif kind == compiler.fileIncludeKindReferenceFile then
        return ast.NewCompilerDiagnostic(diagnostics.Referenced_via_0_from_file_1, referenceText, toFileName(referenceLocation.file:FileName()))
    elseif kind == compiler.fileIncludeKindTypeReferenceDirective then
        if pkgName ~= "" then
            return ast.NewCompilerDiagnostic(diagnostics.Type_library_referenced_via_0_from_file_1_with_packageId_2, referenceText, toFileName(referenceLocation.file:FileName()), compiler.packageIdString(referenceLocation.packageId))
        else
            return ast.NewCompilerDiagnostic(diagnostics.Type_library_referenced_via_0_from_file_1, referenceText, toFileName(referenceLocation.file:FileName()))
        end
    elseif kind == compiler.fileIncludeKindLibReferenceDirective then
        return ast.NewCompilerDiagnostic(diagnostics.Library_referenced_via_0_from_file_1, referenceText, toFileName(referenceLocation.file:FileName()))
    else
        error("unknown reason: " .. tostring(kind), 0)
    end
end

function FileIncludeReason:toRelatedInfo(program)
    if self:isReferencedFile() then
        return self:computeReferenceFileRelatedInfo(program)
    end
    if program.opts.config.configFile == nil then
        return nil
    end
    local config = program.opts.config
    local configSourceFile = config.configFile.sourceFile
    local kind = self.kind
    if kind == compiler.fileIncludeKindRootFile then
        local fileName = tspath.GetNormalizedAbsolutePath(config:FileNames()[self:asIndex() + 1], program:GetCurrentDirectory())
        local matchedFileSpec = config:GetMatchedFileSpec(fileName)
        if matchedFileSpec ~= "" then
            local filesNode = tsoptions.GetTsConfigPropArrayElementValue(configSourceFile, "files", matchedFileSpec)
            if filesNode ~= nil then
                return tsoptions.CreateDiagnosticForNodeInSourceFile(configSourceFile, filesNode, diagnostics.File_is_matched_by_files_list_specified_here)
            end
        else
            local matchedIncludeSpec, isDefaultIncludeSpec = config:GetMatchedIncludeSpec(fileName)
            if matchedIncludeSpec ~= "" and not isDefaultIncludeSpec then
                local includeNode = tsoptions.GetTsConfigPropArrayElementValue(configSourceFile, "include", matchedIncludeSpec)
                if includeNode ~= nil then
                    return tsoptions.CreateDiagnosticForNodeInSourceFile(configSourceFile, includeNode, diagnostics.File_is_matched_by_include_pattern_specified_here)
                end
            end
        end
    elseif kind == compiler.fileIncludeKindAutomaticTypeDirectiveFile then
        if not program:Options():UsesWildcardTypes() then
            local data = self:asAutomaticTypeDirectiveFileData()
            local typesSyntax = tsoptions.GetOptionsSyntaxByArrayElementValue(program.includeProcessor:getCompilerOptionsObjectLiteralSyntax(program), "types", data.typeReference)
            if typesSyntax ~= nil then
                return tsoptions.CreateDiagnosticForNodeInSourceFile(configSourceFile, typesSyntax, diagnostics.File_is_entry_point_of_type_library_specified_here)
            end
        end
    elseif kind == compiler.fileIncludeKindLibFile then
        local index, ok = self:asLibFileIndex()
        if ok then
            local libSyntax = tsoptions.GetOptionsSyntaxByArrayElementValue(program.includeProcessor:getCompilerOptionsObjectLiteralSyntax(program), "lib", program:Options().lib[index + 1])
            if libSyntax ~= nil then
                return tsoptions.CreateDiagnosticForNodeInSourceFile(configSourceFile, libSyntax, diagnostics.File_is_library_specified_here)
            end
        else
            local target = core.ScriptTarget_String(program:Options():GetEmitScriptTarget())
            if target ~= "" then
                local targetValueSyntax = tsoptions.ForEachPropertyAssignment(program.includeProcessor:getCompilerOptionsObjectLiteralSyntax(program), "target", tsoptions.GetCallbackForFindingPropertyAssignmentByValue(target))
                if targetValueSyntax ~= nil then
                    return tsoptions.CreateDiagnosticForNodeInSourceFile(configSourceFile, targetValueSyntax, diagnostics.File_is_default_library_for_target_specified_here)
                end
            end
        end
    elseif kind == compiler.fileIncludeKindContentMapperSupplemental then
        return nil
    else
        error("unknown reason: " .. tostring(kind), 0)
    end
    return nil
end

function FileIncludeReason:computeReferenceFileRelatedInfo(program)
    local referenceLocation = program.includeProcessor:getReferenceLocation(self, program)
    if referenceLocation.isSynthetic then
        return nil
    end
    local kind = self.kind
    if kind == compiler.fileIncludeKindImport then
        return referenceLocation:diagnosticAt(diagnostics.File_is_included_via_import_here)
    elseif kind == compiler.fileIncludeKindReferenceFile then
        return referenceLocation:diagnosticAt(diagnostics.File_is_included_via_reference_here)
    elseif kind == compiler.fileIncludeKindTypeReferenceDirective then
        return referenceLocation:diagnosticAt(diagnostics.File_is_included_via_type_library_reference_here)
    elseif kind == compiler.fileIncludeKindLibReferenceDirective then
        return referenceLocation:diagnosticAt(diagnostics.File_is_included_via_library_reference_here)
    else
        error("unknown reason: " .. tostring(kind), 0)
    end
end
