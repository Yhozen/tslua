local moduletransforms = require("tslua.transformers.moduletransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local outputpaths = require("tslua.outputpaths")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")
local tspath = require("tslua.tspath")

local Kind = ast.Kind

function moduletransforms.isDeclarationNameOfEnumOrNamespace(emitContext, node)
    local original = emitContext:MostOriginal(node)
    if original ~= nil and original.parent ~= nil then
        local k = original.parent.kind
        if k == Kind.EnumDeclaration or k == Kind.ModuleDeclaration then
            return original == original.parent:Name()
        end
    end
    return false
end

function moduletransforms.rewriteModuleSpecifier(emitContext, node, compilerOptions)
    if node == nil or not ast.IsStringLiteral(node) or not core.ShouldRewriteModuleSpecifier(node:Text(), compilerOptions) then
        return node
    end
    local updatedText = tspath.ChangeExtension(node:Text(), outputpaths.GetOutputExtension(node:Text(), compilerOptions.jsx))
    if updatedText ~= node:Text() then
        local updated = emitContext.factory:NewStringLiteral(updatedText, node:AsStringLiteral().tokenFlags)
        emitContext:SetOriginal(updated, node)
        emitContext:AssignCommentAndSourceMapRanges(updated, node)
        return updated
    end
    return node
end

function moduletransforms.createEmptyImports(factory)
    return factory:NewExportDeclaration(
        nil, --[[modifiers]]
        false, --[[isTypeOnly]]
        factory:NewNamedExports(factory:NewNodeList(nil)),
        nil, --[[moduleSpecifier]]
        nil --[[attributes]]
    )
end

-- Get the name of a target module from an import/export declaration as should be written in the emitted output.
-- The emitted output name can be different from the input if:
--  1. The module has a /// <amd-module name="<new name>" />
--  2. --out or --outFile is used, making the name relative to the rootDir
--     3- The containing SourceFile has an entry in renamedDependencies for the import as requested by some module loaders (e.g. System).
--
-- Otherwise, a new StringLiteral node representing the module name will be returned.
function moduletransforms.getExternalModuleNameLiteral(factory, importNode, sourceFile, host, resolver, compilerOptions)
    local moduleName = ast.GetExternalModuleName(importNode)
    if moduleName ~= nil and ast.IsStringLiteral(moduleName) then
        local name = moduletransforms.tryGetModuleNameFromDeclaration(importNode, host, factory, resolver, compilerOptions)
        if name == nil then
            name = moduletransforms.tryRenameExternalModule(factory, moduleName, sourceFile)
        end
        if name == nil then -- !!! propagate token flags (will produce new diffs)
            name = factory:NewStringLiteral(moduleName:Text(), ast.TokenFlags.None)
        end
        return name
    end
    return nil
end

-- Get the name of a module as should be written in the emitted output.
-- The emitted output name can be different from the input if:
--  1. The module has a /// <amd-module name="<new name>" />
--  2. --out or --outFile is used, making the name relative to the rootDir
--
-- Otherwise, a new StringLiteral node representing the module name will be returned.
function moduletransforms.tryGetModuleNameFromFile(factory, file, host, options)
    if file == nil then
        return nil
    end
    -- !!!
    -- if file.moduleName {
    -- 	return factory.createStringLiteral(file.moduleName)
    -- }
    return nil
end

function moduletransforms.tryGetModuleNameFromDeclaration(declaration, host, factory, resolver, compilerOptions)
    if resolver == nil then
        return nil
    end
    return moduletransforms.tryGetModuleNameFromFile(factory, resolver:GetExternalModuleFileFromDeclaration(declaration), host, compilerOptions)
end

-- Resolves a local path to a path which is absolute to the base of the emit
function moduletransforms.getExternalModuleNameFromPath(host, fileName, referencePath)
    -- !!!
    return ""
end

-- Some bundlers (SystemJS builder) sometimes want to rename dependencies.
-- Here we check if alternative name was provided for a given moduleName and return it if possible.
function moduletransforms.tryRenameExternalModule(factory, moduleName, sourceFile)
    -- !!!
    return nil
end

function moduletransforms.isFileLevelReservedGeneratedIdentifier(emitContext, name)
    local info = emitContext:GetAutoGenerateInfo(name)
    return info ~= nil and
        printer.GeneratedIdentifierFlags_IsFileLevel(info.flags) and
        printer.GeneratedIdentifierFlags_IsOptimistic(info.flags) and
        printer.GeneratedIdentifierFlags_IsReservedInNestedScopes(info.flags)
end

-- A simple inlinable expression is an expression which can be copied into multiple locations
-- without risk of repeating any sideeffects and whose value could not possibly change between
-- any such locations
function moduletransforms.isSimpleInlineableExpression(expression)
    return not ast.IsIdentifier(expression) and transformers.IsSimpleCopiableExpression(expression)
end
