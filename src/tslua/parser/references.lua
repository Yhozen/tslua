local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

function parser.collectExternalModuleReferences(file)
    for _, node in ipairs(file.statements.nodes) do
        parser.collectModuleReferences(file, node, false --[[inAmbientModule]])
    end

    if file.flags & ast.NodeFlags.PossiblyContainsDynamicImport ~= 0 or ast.IsInJSFile(file) then
        ast.ForEachDynamicImportOrRequireCall(file, true --[[includeTypeSpaceImports]], true --[[requireStringLiteralLikeArgument]], function(node, moduleSpecifier)
            ast.SetImportsOfSourceFile(file, core.Append(file:Imports(), moduleSpecifier))
            return false
        end)
    end
end

function parser.collectModuleReferences(file, node, inAmbientModule)
    if ast.IsAnyImportOrReExport(node) then
        local moduleNameExpr = ast.GetExternalModuleName(node)
        -- TypeScript 1.0 spec (April 2014): 12.1.6
        -- An ExternalImportDeclaration in an AmbientExternalModuleDeclaration may reference other external modules
        -- only through top - level external module names. Relative external module names are not permitted.
        if moduleNameExpr ~= nil and ast.IsStringLiteral(moduleNameExpr) then
            local moduleName = moduleNameExpr:Text()
            if moduleName ~= "" and (not inAmbientModule or not tspath.IsExternalModuleNameRelative(moduleName)) then
                ast.SetImportsOfSourceFile(file, core.Append(file:Imports(), moduleNameExpr))
                -- !!! removed `&& p.currentNodeModulesDepth == 0`
                if file.usesUriStyleNodeCoreModules ~= core.Tristate.TSTrue and not file.isDeclarationFile then
                    if string.sub(moduleName, 1, 5) == "node:" and not core.ExclusivelyPrefixedNodeCoreModules[moduleName] then
                        -- Presence of `node:` prefix takes precedence over unprefixed node core modules
                        file.usesUriStyleNodeCoreModules = core.Tristate.TSTrue
                    elseif file.usesUriStyleNodeCoreModules == core.Tristate.TSUnknown and core.UnprefixedNodeCoreModules[moduleName] then
                        -- Avoid `unprefixedNodeCoreModules.has` for every import
                        file.usesUriStyleNodeCoreModules = core.Tristate.TSFalse
                    end
                end
            end
        end
        return
    end
    if ast.IsModuleDeclaration(node) and ast.IsAmbientModule(node) and (inAmbientModule or ast.HasSyntacticModifier(node, ast.ModifierFlags.Ambient) or file.isDeclarationFile) then
        local nameText = node:AsModuleDeclaration():Name():Text()
        -- Ambient module declarations can be interpreted as augmentations for some existing external modules.
        -- This will happen in two cases:
        -- - if current file is external module then module augmentation is a ambient module declaration defined in the top level scope
        -- - if current file is not external module then module augmentation is an ambient module declaration with non-relative module name
        --   immediately nested in top level ambient module declaration .
        if ast.IsExternalModule(file) or (inAmbientModule and not tspath.IsExternalModuleNameRelative(nameText)) then
            file.moduleAugmentations = core.Append(file.moduleAugmentations, node:AsModuleDeclaration():Name())
        elseif not inAmbientModule then
            file.ambientModuleNames = core.Append(file.ambientModuleNames, nameText)
            -- An AmbientExternalModuleDeclaration declares an external module.
            -- This type of declaration is permitted only in the global module.
            -- The StringLiteral must specify a top - level external module name.
            -- Relative external module names are not permitted
            -- NOTE: body of ambient module is always a module block, if it exists
            if node:Body() ~= nil then
                for _, statement in ipairs(node:Body():Statements() or {}) do
                    parser.collectModuleReferences(file, statement, true --[[inAmbientModule]])
                end
            end
        end
    end
end
