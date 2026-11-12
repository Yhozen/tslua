local moduletransforms = require("tslua.transformers.moduletransforms")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local printer = require("tslua.printer")
local stringutil = require("tslua.stringutil")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local EF = printer.EmitFlags
local ModuleKind = core.ModuleKind

-- externalModuleInfo: {
--   externalImports              []ImportDeclaration | ImportEqualsDeclaration | ExportDeclaration. imports and reexports of other external modules
--   exportSpecifiers             MultiMap string -> ExportSpecifier. Maps local names to their associated export specifiers (excludes reexports)
--   exportedBindings             MultiMap Declaration -> ModuleExportName. Maps local declarations to their associated export aliases
--   exportedNames                []ModuleExportName. all exported names in the module, both local and re-exported, excluding the names of locally exported function declarations
--   exportedFunctions            OrderedSet FunctionDeclaration. all of the top-level exported function declarations
--   exportEquals                 ExportAssignment. an export=/module.exports= declaration if one was present
--   hasExportStarsToExportValues bool. whether this module contains export*
-- }
function moduletransforms.newExternalModuleInfo()
    return {
        externalImports = nil,
        exportSpecifiers = collections.NewMultiMap(),
        exportedBindings = collections.NewMultiMap(),
        exportedNames = nil,
        exportedFunctions = collections.NewOrderedSet(),
        exportEquals = nil,
        hasExportStarsToExportValues = false,
    }
end

local externalModuleInfoCollector = {}
externalModuleInfoCollector.__index = externalModuleInfoCollector
moduletransforms.externalModuleInfoCollector = externalModuleInfoCollector

function moduletransforms.collectExternalModuleInfo(sourceFile, compilerOptions, emitContext, resolver)
    local c = setmetatable({
        sourceFile = sourceFile,
        compilerOptions = compilerOptions,
        emitContext = emitContext,
        resolver = resolver,
        uniqueExports = collections.NewSet(),
        hasExportDefault = false,
        output = moduletransforms.newExternalModuleInfo(),
    }, externalModuleInfoCollector)
    return c:collect()
end

function externalModuleInfoCollector:collect()
    local hasImportStar = false
    local hasImportDefault = false
    for _, node in ipairs(self.sourceFile.statements.nodes or {}) do
        -- Look through NotEmittedStatement to find elided export= declarations
        -- (e.g., `declare export = x` is elided by the type eraser but must still be collected)
        if ast.IsNotEmittedStatement(node) then
            local original = self.emitContext:MostOriginal(node)
            if original ~= nil and ast.IsExportAssignment(original) then
                local n = original:AsExportAssignment()
                if n.isExportEquals and self.output.exportEquals == nil then
                    self.output.exportEquals = n
                end
            end
            goto continue
        end
        if node.kind == Kind.ImportDeclaration then
            -- import "mod"
            -- import x from "mod"
            -- import * as x from "mod"
            -- import { x, y } from "mod"
            local n = node:AsImportDeclaration()
            self:addExternalImport(node)
            if not hasImportStar and moduletransforms.getImportNeedsImportStarHelper(n) then
                hasImportStar = true
            end
            if not hasImportDefault and moduletransforms.getImportNeedsImportDefaultHelper(n) then
                hasImportDefault = true
            end
        elseif node.kind == Kind.ImportEqualsDeclaration then
            local n = node:AsImportEqualsDeclaration()
            if ast.IsExternalModuleReference(n.moduleReference) then
                -- import x = require("mod")
                self:addExternalImport(node)
            end
        elseif node.kind == Kind.ExportDeclaration then
            local n = node:AsExportDeclaration()
            if n.moduleSpecifier ~= nil then
                -- export * from "mod"
                -- export * as ns from "mod"
                -- export { x, y } from "mod"
                self:addExternalImport(node)
                if n.exportClause == nil then
                    -- export * from "mod"
                    self.output.hasExportStarsToExportValues = true
                elseif ast.IsNamedExports(n.exportClause) then
                    -- export { x, y } from "mod"
                    self:addExportedNamesForExportDeclaration(n)
                    if not hasImportDefault then
                        hasImportDefault = moduletransforms.containsDefaultReference(n.exportClause)
                    end
                else
                    -- export * as ns from "mod"
                    local name = n.exportClause:AsNamespaceExport():Name()
                    local nameText = name:Text()
                    if self:addUniqueExport(nameText) then
                        self:addExportedBinding(node, name)
                        self:addExportedName(name)
                    end
                    -- we use the same helpers for `export * as ns` as we do for `import * as ns`
                    hasImportStar = true
                end
            else
                -- export { x, y }
                self:addExportedNamesForExportDeclaration(node:AsExportDeclaration())
            end
        elseif node.kind == Kind.ExportAssignment then
            local n = node:AsExportAssignment()
            if n.isExportEquals and self.output.exportEquals == nil then
                -- export = x
                self.output.exportEquals = n
            end
        elseif node.kind == Kind.VariableStatement then
            local n = node:AsVariableStatement()
            if ast.HasSyntacticModifier(node, ModifierFlags.Export) then
                for _, decl in ipairs(n.declarationList:AsVariableDeclarationList().declarations.nodes or {}) do
                    self:collectExportedVariableInfo(decl)
                end
            end
        elseif node.kind == Kind.FunctionDeclaration then
            local n = node:AsFunctionDeclaration()
            if ast.HasSyntacticModifier(node, ModifierFlags.Export) then
                self:addExportedFunctionDeclaration(n, nil --[[name]], ast.HasSyntacticModifier(node, ModifierFlags.Default))
            end
        elseif node.kind == Kind.ClassDeclaration then
            local n = node:AsClassDeclaration()
            if ast.HasSyntacticModifier(node, ModifierFlags.Export) then
                if ast.HasSyntacticModifier(node, ModifierFlags.Default) then
                    -- export default class { }
                    if not self.hasExportDefault then
                        local name = n:Name()
                        if name == nil then
                            name = self.emitContext.factory:NewGeneratedNameForNode(node)
                        end
                        self:addExportedBinding(node, name)
                        self.hasExportDefault = true
                    end
                else
                    -- export class x { }
                    local name = n:Name()
                    if name ~= nil then
                        if self:addUniqueExport(name:Text()) then
                            self:addExportedBinding(node, name)
                            self:addExportedName(name)
                        end
                    end
                end
            end
        end
        ::continue::
    end

    return self.output
end

function externalModuleInfoCollector:addUniqueExport(name)
    if not self.uniqueExports:Has(name) then
        self.uniqueExports:Add(name)
        return true
    end
    return false
end

function externalModuleInfoCollector:addExportedBinding(decl, name)
    self.output.exportedBindings:Add(self.emitContext:MostOriginal(decl), name)
end

function externalModuleInfoCollector:addExternalImport(node)
    self.output.externalImports = core.Append(self.output.externalImports, node)
end

function externalModuleInfoCollector:addExportedName(name)
    self.output.exportedNames = core.Append(self.output.exportedNames, name)
end

function externalModuleInfoCollector:addExportedNamesForExportDeclaration(node)
    for _, specifier in ipairs(node.exportClause:Elements() or {}) do
        local specifierNameText = specifier:Name():Text()
        if self:addUniqueExport(specifierNameText) then
            local name = specifier:PropertyNameOrName()
            if name.kind ~= Kind.StringLiteral then
                if node.moduleSpecifier == nil then
                    self.output.exportSpecifiers:Add(name:Text(), specifier:AsExportSpecifier())
                end

                local decl = self.resolver:GetReferencedImportDeclaration(self.emitContext:MostOriginal(name))
                if decl == nil then
                    decl = self.resolver:GetReferencedValueDeclaration(self.emitContext:MostOriginal(name))
                end
                if decl ~= nil then
                    if decl.kind == Kind.FunctionDeclaration then
                        self.uniqueExports:Delete(specifierNameText)
                        self:addExportedFunctionDeclaration(decl:AsFunctionDeclaration(), specifier:Name(), ast.ModuleExportNameIsDefault(specifier:Name()))
                        goto continue
                    end
                    self:addExportedBinding(decl, specifier:Name())
                end
            end

            self:addExportedName(specifier:Name())
        end
        ::continue::
    end
end

function externalModuleInfoCollector:addExportedFunctionDeclaration(node, name, isDefault)
    self.output.exportedFunctions:Add(self.emitContext:MostOriginal(node:AsNode()))
    if isDefault then
        -- export default function() { }
        -- function x() { } + export { x as default };
        if not self.hasExportDefault then
            if name == nil then
                name = self.emitContext.factory:NewGeneratedNameForNode(node:AsNode())
            end
            self:addExportedBinding(node:AsNode(), name)
            self.hasExportDefault = true
        end
    else
        -- export function x() { }
        -- function x() { } + export { x }
        if name == nil then
            name = node:Name()
        end
        local nameText = name:Text()
        if self:addUniqueExport(nameText) then
            self:addExportedBinding(node:AsNode(), name)
        end
    end
end

function externalModuleInfoCollector:collectExportedVariableInfo(decl)
    if ast.IsBindingPattern(decl:Name()) then
        for _, element in ipairs(decl:Name():Elements() or {}) do
            local e = element:AsBindingElement()
            if e:Name() ~= nil then
                self:collectExportedVariableInfo(element)
            end
        end
    elseif not self.emitContext:HasAutoGenerateInfo(decl:Name()) then
        local text = decl:Name():Text()
        if self:addUniqueExport(text) then
            self:addExportedName(decl:Name())
            if transformers.IsLocalName(self.emitContext, decl:Name()) then
                self:addExportedBinding(decl, decl:Name())
            end
        end
    end
end

moduletransforms.externalHelpersModuleNameText = "tslib"

function moduletransforms.createExternalHelpersImportDeclarationIfNeeded(emitContext, sourceFile, compilerOptions, fileModuleKind, hasExportStarsToExportValues, hasImportStar, hasImportDefault)
    if core.Tristate_IsTrue(compilerOptions.importHelpers) and ast.IsEffectiveExternalModule(sourceFile, compilerOptions) then
        local moduleKind = compilerOptions:GetEmitModuleKind()
        local helpers = moduletransforms.getImportedHelpers(emitContext, sourceFile)
        if fileModuleKind == ModuleKind.CommonJS or fileModuleKind == ModuleKind.None and moduleKind == ModuleKind.CommonJS then
            -- When we emit to a non-ES module, generate a synthetic `import tslib = require("tslib")` to be further transformed.
            local externalHelpersModuleName = moduletransforms.getOrCreateExternalHelpersModuleNameIfNeeded(emitContext, sourceFile, compilerOptions, helpers, hasExportStarsToExportValues, hasImportStar or hasImportDefault, fileModuleKind)
            if externalHelpersModuleName ~= nil then
                local externalHelpersImportDeclaration = emitContext.factory:NewImportEqualsDeclaration(
                    nil, --[[modifiers]]
                    false, --[[isTypeOnly]]
                    externalHelpersModuleName,
                    emitContext.factory:NewExternalModuleReference(emitContext.factory:NewStringLiteral(moduletransforms.externalHelpersModuleNameText, ast.TokenFlags.None))
                )
                emitContext:AddEmitFlags(externalHelpersImportDeclaration, EF.EFCustomPrologue)
                return externalHelpersImportDeclaration
            end
        else
            -- When we emit as an ES module, generate an `import` declaration that uses named imports for helpers.
            -- If we cannot determine the implied module kind under `module: preserve` we assume ESM.
            local helperNames = nil
            for _, helper in ipairs(helpers or {}) do
                local importName = helper.importName or ""
                if #importName > 0 then
                    helperNames = core.AppendIfUnique(helperNames, importName)
                end
            end
            if core.Len(helperNames) > 0 then
                core.SortFunc(helperNames, stringutil.CompareStringsCaseSensitive)
                -- Alias the imports if the names are used somewhere in the file.
                -- NOTE: We don't need to care about global import collisions as this is a module.

                local importSpecifiers = core.Map(helperNames, function(name)
                    if emitContext:IsFileLevelUniqueName(sourceFile, name, nil --[[hasGlobalName]]) then
                        return emitContext.factory:NewImportSpecifier(false --[[isTypeOnly]], nil --[[propertyName]], emitContext.factory:NewIdentifier(name))
                    else
                        return emitContext.factory:NewImportSpecifier(false --[[isTypeOnly]], emitContext.factory:NewIdentifier(name), emitContext.factory:NewUnscopedHelperName(name))
                    end
                end)
                local namedBindings = emitContext.factory:NewNamedImports(emitContext.factory:NewNodeList(importSpecifiers))
                local parseNode = emitContext:MostOriginal(sourceFile:AsNode())
                emitContext:AddEmitFlags(parseNode, EF.EFExternalHelpers)

                local externalHelpersImportDeclaration = emitContext.factory:NewImportDeclaration(
                    nil, --[[modifiers]]
                    emitContext.factory:NewImportClause(Kind.Unknown --[[phaseModifier]], nil --[[name]], namedBindings),
                    emitContext.factory:NewStringLiteral(moduletransforms.externalHelpersModuleNameText, ast.TokenFlags.None),
                    nil --[[attributes]]
                )

                emitContext:AddEmitFlags(externalHelpersImportDeclaration, EF.EFCustomPrologue)
                return externalHelpersImportDeclaration
            end
        end
    end
    return nil
end

function moduletransforms.getImportedHelpers(emitContext, sourceFile)
    local helpers = nil
    for _, helper in ipairs(emitContext:GetEmitHelpers(sourceFile:AsNode()) or {}) do
        if not helper.scoped then
            helpers = core.Append(helpers, helper)
        end
    end
    return helpers
end

function moduletransforms.getOrCreateExternalHelpersModuleNameIfNeeded(emitContext, node, compilerOptions, helpers, hasExportStarsToExportValues, hasImportStarOrImportDefault, fileModuleKind)
    local externalHelpersModuleName = emitContext:GetExternalHelpersModuleName(node)
    if externalHelpersModuleName ~= nil then
        return externalHelpersModuleName
    end

    local create = core.Len(helpers) > 0 or
        (hasExportStarsToExportValues or hasImportStarOrImportDefault) and
        fileModuleKind < ModuleKind.System

    if create then
        externalHelpersModuleName = emitContext.factory:NewUniqueName(moduletransforms.externalHelpersModuleNameText)
        emitContext:SetExternalHelpersModuleName(node, externalHelpersModuleName)
    end

    return externalHelpersModuleName
end

function moduletransforms.isNamedDefaultReference(e)
    return ast.ModuleExportNameIsDefault(e:PropertyNameOrName())
end

function moduletransforms.containsDefaultReference(node)
    return node ~= nil and (ast.IsNamedImports(node) or ast.IsNamedExports(node)) and core.Some(node:Elements(), moduletransforms.isNamedDefaultReference)
end

function moduletransforms.getExportNeedsImportStarHelper(node)
    return ast.GetNamespaceDeclarationNode(node:AsNode()) ~= nil
end

function moduletransforms.getImportNeedsImportStarHelper(node)
    if ast.GetNamespaceDeclarationNode(node:AsNode()) ~= nil then
        return true
    end
    if node.importClause == nil then
        return false
    end
    local bindings = node.importClause:AsImportClause().namedBindings
    if bindings == nil then
        return false
    end
    if not ast.IsNamedImports(bindings) then
        return false
    end
    local namedImports = bindings:AsNamedImports()
    local defaultRefCount = 0
    for _, binding in ipairs(namedImports.elements.nodes or {}) do
        if moduletransforms.isNamedDefaultReference(binding) then
            defaultRefCount = defaultRefCount + 1
        end
    end
    -- Import star is required if there's default named refs mixed with non-default refs, or if theres non-default refs and it has a default import
    return (defaultRefCount > 0 and defaultRefCount ~= core.Len(namedImports.elements.nodes)) or ((core.Len(namedImports.elements.nodes) - defaultRefCount) ~= 0 and ast.IsDefaultImport(node:AsNode()))
end

function moduletransforms.getImportNeedsImportDefaultHelper(node)
    -- Import default is needed if there's a default import or a default ref and no other refs (meaning an import star helper wasn't requested)
    return not moduletransforms.getImportNeedsImportStarHelper(node) and (ast.IsDefaultImport(node:AsNode()) or (node.importClause ~= nil and
        ast.IsNamedImports(node.importClause:AsImportClause().namedBindings) and
        moduletransforms.containsDefaultReference(node.importClause:AsImportClause().namedBindings)))
end
