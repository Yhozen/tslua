local checker = require("tslua.checker")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local debug = require("tslua.debug")
local scanner = require("tslua.scanner")
local binder = require("tslua.binder")
local tspath = require("tslua.tspath")
local module = require("tslua.module")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local CheckMode = checker.CheckMode
local SignatureKind = checker.SignatureKind
local SignatureFlags = checker.SignatureFlags
local TypeSystemPropertyName = checker.TypeSystemPropertyName
local MembersOrExportsResolutionKind = checker.MembersOrExportsResolutionKind
local AccessFlags = checker.AccessFlags
local UnionReduction = checker.UnionReduction
local TypeFacts = checker.TypeFacts
local IterationUse = checker.IterationUse
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local ModuleKind = core.ModuleKind

-- Go nil-map read: m[k] with a possibly-nil map.
local function mapGet(m, k)
    if m == nil then
        return nil
    end
    return m[k]
end

-- Go len(m) for a possibly-nil map.
local function mapLen(m)
    local n = 0
    for _ in pairs(m or {}) do
        n = n + 1
    end
    return n
end

-- Go maps.Clone: nil stays nil.
local function cloneMap(m)
    if m == nil then
        return nil
    end
    local result = {}
    for k, v in pairs(m) do
        result[k] = v
    end
    return result
end

function checker.createDiagnosticForNode(node, message, ...)
    return checker.NewDiagnosticForNode(node, message, ...)
end

function checker.getAdjustedNodeForError(node)
    local name = ast.GetNameOfDeclaration(node)
    if name ~= nil then
        return name
    end
    return node
end

function Checker:lookupOrIssueError(location, message, ...)
    return self:addDiagnostic(checker.NewDiagnosticForNode(location, message, ...))
end

function checker.getFirstDeclaration(symbol)
    if core.Len(symbol.declarations) > 0 then
        return symbol.declarations[1]
    end
    return nil
end

function checker.getExcludedSymbolFlags(flags)
    local result = 0
    if flags & SymbolFlags.BlockScopedVariable ~= 0 then
        result = result | SymbolFlags.BlockScopedVariableExcludes
    end
    if flags & SymbolFlags.FunctionScopedVariable ~= 0 then
        result = result | SymbolFlags.FunctionScopedVariableExcludes
    end
    if flags & SymbolFlags.Property ~= 0 then
        result = result | SymbolFlags.PropertyExcludes
    end
    if flags & SymbolFlags.EnumMember ~= 0 then
        result = result | SymbolFlags.EnumMemberExcludes
    end
    if flags & SymbolFlags.Function ~= 0 then
        result = result | SymbolFlags.FunctionExcludes
    end
    if flags & SymbolFlags.Class ~= 0 then
        result = result | SymbolFlags.ClassExcludes
    end
    if flags & SymbolFlags.Interface ~= 0 then
        result = result | SymbolFlags.InterfaceExcludes
    end
    if flags & SymbolFlags.RegularEnum ~= 0 then
        result = result | SymbolFlags.RegularEnumExcludes
    end
    if flags & SymbolFlags.ConstEnum ~= 0 then
        result = result | SymbolFlags.ConstEnumExcludes
    end
    if flags & SymbolFlags.ValueModule ~= 0 then
        result = result | SymbolFlags.ValueModuleExcludes
    end
    if flags & SymbolFlags.Method ~= 0 then
        result = result | SymbolFlags.MethodExcludes
    end
    if flags & SymbolFlags.GetAccessor ~= 0 then
        result = result | SymbolFlags.GetAccessorExcludes
    end
    if flags & SymbolFlags.SetAccessor ~= 0 then
        result = result | SymbolFlags.SetAccessorExcludes
    end
    if flags & SymbolFlags.TypeParameter ~= 0 then
        result = result | SymbolFlags.TypeParameterExcludes
    end
    if flags & SymbolFlags.TypeAlias ~= 0 then
        result = result | SymbolFlags.TypeAliasExcludes
    end
    if flags & SymbolFlags.Alias ~= 0 then
        result = result | SymbolFlags.AliasExcludes
    end
    if flags & SymbolFlags.ReplaceableByMethod ~= 0 then
        result = result & ~SymbolFlags.Method
    end
    return result
end

function Checker:cloneSymbol(symbol)
    local result = self:newSymbol(symbol.flags, symbol.name)
    -- Force reallocation if anything is ever appended to declarations
    if symbol.declarations ~= nil then
        result.declarations = core.Slice(symbol.declarations, 0, #symbol.declarations)
    end
    result.parent = symbol.parent
    result.valueDeclaration = symbol.valueDeclaration
    result.members = cloneMap(symbol.members)
    result.exports = cloneMap(symbol.exports)
    self:recordMergedSymbol(result, symbol)
    return result
end

function Checker:getMergedSymbol(symbol)
    if symbol ~= nil then
        local merged = self.mergedSymbols[symbol]
        if merged ~= nil then
            return merged
        end
    end
    return symbol
end

function Checker:getParentOfSymbol(symbol)
    if symbol.parent ~= nil then
        return self:getMergedSymbol(self:getLateBoundSymbol(symbol.parent))
    end
    return nil
end

function Checker:recordMergedSymbol(target, source)
    self.mergedSymbols[source] = target
end

function Checker:getSymbolIfSameReference(s1, s2)
    if self:getMergedSymbol(self:resolveSymbol(self:getMergedSymbol(s1))) == self:getMergedSymbol(self:resolveSymbol(self:getMergedSymbol(s2))) then
        return s1
    end
    return nil
end

function Checker:getExportSymbolOfValueSymbolIfExported(symbol)
    if symbol ~= nil and symbol.flags & SymbolFlags.ExportValue ~= 0 and symbol.exportSymbol ~= nil then
        symbol = symbol.exportSymbol
    end
    return self:getMergedSymbol(symbol)
end

function Checker:getSymbolOfDeclaration(node)
    local symbol = node:Symbol()
    if symbol ~= nil then
        return self:getMergedSymbol(self:getLateBoundSymbol(symbol))
    end
    return nil
end

-- Get the merged symbol for a node. If you know the node is a `Declaration`, it is more type safe to
-- use use `getSymbolOfDeclaration` instead.
function Checker:getSymbolOfNode(node)
    local data = node:DeclarationData()
    if data ~= nil and data.symbol ~= nil then
        return self:getMergedSymbol(self:getLateBoundSymbol(data.symbol))
    end
    return nil
end

function Checker:getLateBoundSymbol(symbol)
    if symbol.flags & SymbolFlags.ClassMember == 0 or symbol.name ~= ast.InternalSymbolNameComputed then
        return symbol
    end
    local links = self.lateBoundLinks:Get(symbol)
    if links.lateSymbol == nil and core.Some(symbol.declarations, function(d)
        return self:hasLateBindableName(d)
    end) then
        -- force late binding of members/exports. This will set the late-bound symbol
        local parent = self:getMergedSymbol(symbol.parent)
        if core.Some(symbol.declarations, ast.HasStaticModifier) then
            self:getExportsOfSymbol(parent)
        else
            self:getMembersOfSymbol(parent)
        end
    end
    if links.lateSymbol == nil then
        links.lateSymbol = symbol
    end
    return links.lateSymbol
end

function Checker:resolveSymbol(symbol)
    return self:resolveSymbolEx(symbol, false --[[dontResolveAlias]])
end

function Checker:resolveSymbolEx(symbol, dontResolveAlias)
    if not dontResolveAlias and ast.IsNonLocalAlias(symbol, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace) then
        return self:resolveAlias(symbol)
    end
    return symbol
end

function Checker:getTargetOfImportEqualsDeclaration(node)
    -- Node is ImportEqualsDeclaration | VariableDeclaration
    if ast.IsVariableDeclaration(node) or node:AsImportEqualsDeclaration().moduleReference.kind == Kind.ExternalModuleReference then
        local moduleReference = checker.getExternalModuleRequireArgument(node)
        if moduleReference == nil then
            moduleReference = ast.GetExternalModuleImportEqualsDeclarationExpression(node)
        end
        local immediate = self:resolveExternalModuleName(node, moduleReference, false --[[ignoreErrors]])
        local resolved = self:resolveExternalModuleSymbol(immediate, true --[[dontResolveAlias]])
        if resolved ~= nil and ModuleKind.Node20 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext then
            local moduleExports = self:getExportOfModule(resolved, ast.InternalSymbolNameModuleExports, node, true --[[dontResolveAlias]])
            if moduleExports ~= nil then
                return moduleExports
            end
        end
        self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
        return resolved
    end
    local resolved = self:getSymbolOfPartOfRightHandSideOfImportEquals(node:AsImportEqualsDeclaration().moduleReference)
    self:checkAndReportErrorForResolvingImportAliasToTypeOnlySymbol(node, resolved)
    return resolved
end

function Checker:resolveExternalModuleTypeByLiteral(name)
    local moduleSym = self:resolveExternalModuleName(name, name, false --[[ignoreErrors]])
    if moduleSym ~= nil then
        local resolvedModuleSymbol = self:resolveExternalModuleSymbol(moduleSym, false --[[dontResolveAlias]])
        if resolvedModuleSymbol ~= nil then
            return self:getTypeOfSymbol(resolvedModuleSymbol)
        end
    end
    return self.anyType
end

-- This function is only for imports with entity names
function Checker:getSymbolOfPartOfRightHandSideOfImportEquals(entityName)
    -- There are three things we might try to look for. In the following examples,
    -- the search term is enclosed in |...|:
    --
    --     import a = |b|; // Namespace
    --     import a = |b.c|; // Value, type, namespace
    --     import a = |b.c|.d; // Namespace
    if entityName.kind == Kind.Identifier and ast.IsRightSideOfQualifiedNameOrPropertyAccess(entityName) then
        entityName = entityName.parent -- QualifiedName
    end
    -- Check for case 1 and 3 in the above example
    if entityName.kind == Kind.Identifier or entityName.parent.kind == Kind.QualifiedName then
        return self:resolveEntityName(entityName, SymbolFlags.Namespace, false --[[ignoreErrors]], true --[[dontResolveAlias]], nil --[[location]])
    end
    -- Case 2 in above example
    -- entityName.kind could be a QualifiedName or a Missing identifier
    debug.Assert(entityName.parent.kind == Kind.ImportEqualsDeclaration)
    return self:resolveEntityName(entityName, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace, false --[[ignoreErrors]], true --[[dontResolveAlias]], nil --[[location]])
end

function Checker:checkAndReportErrorForResolvingImportAliasToTypeOnlySymbol(node, resolved) -- luacheck: ignore resolved
    local decl = node:AsImportEqualsDeclaration()
    local name = decl.moduleReference
    while true do
        local typeOnlyDeclaration = self:getTypeOnlyDeclarationOfEntityName(name)
        if typeOnlyDeclaration ~= nil then
            local isExport = ast.NodeKindIs(typeOnlyDeclaration, Kind.ExportSpecifier, Kind.ExportDeclaration)
            local message = core.IfElse(isExport,
                diagnostics.An_import_alias_cannot_reference_a_declaration_that_was_exported_using_export_type,
                diagnostics.An_import_alias_cannot_reference_a_declaration_that_was_imported_using_import_type)
            local relatedMessage = core.IfElse(isExport,
                diagnostics.X_0_was_exported_here,
                diagnostics.X_0_was_imported_here)
            -- TODO: how to get name for export *?
            local name_ = "*"
            if not ast.IsExportDeclaration(typeOnlyDeclaration) then
                name_ = typeOnlyDeclaration:Name():Text()
            end
            self:error(decl.moduleReference, message):AddRelatedInfo(checker.createDiagnosticForNode(typeOnlyDeclaration, relatedMessage, name_))
            break
        end
        if ast.IsIdentifier(name) then
            break
        end
        name = name:AsQualifiedName().left
    end
end

function Checker:getTypeOnlyDeclarationOfEntityName(name)
    local symbol = self:resolveEntityName(name, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace, true --[[ignoreErrors]], true --[[dontResolveAlias]], nil --[[location]])
    if symbol ~= nil then
        return self:getTypeOnlyAliasDeclaration(symbol)
    end
    return nil
end

function Checker:getTargetOfImportClause(node)
    local moduleSymbol = self:resolveExternalModuleName(node, checker.getModuleSpecifierFromNode(node.parent), false --[[ignoreErrors]])
    if moduleSymbol ~= nil then
        return self:getTargetOfModuleDefault(moduleSymbol, node, true --[[dontResolveAlias]])
    end
    return nil
end

function Checker:getTargetOfModuleDefault(moduleSymbol, node, dontResolveAlias)
    local file = core.Find(moduleSymbol.declarations, ast.IsSourceFile)
    local specifier = self:getModuleSpecifierForImportOrExport(node)
    local exportDefaultSymbol
    local exportModuleDotExportsSymbol
    if checker.isShorthandAmbientModuleSymbol(moduleSymbol) then -- luacheck: ignore 542
        -- !!! exportDefaultSymbol = moduleSymbol
        -- Does nothing?
    elseif file ~= nil and specifier ~= nil and
        ModuleKind.Node20 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext and
        self:getEmitSyntaxForModuleSpecifierExpression(specifier) == ModuleKind.CommonJS and
        self.program:GetImpliedNodeFormatForEmit(file:AsSourceFile()) == ModuleKind.ESNext then
        exportModuleDotExportsSymbol = self:resolveExportByName(moduleSymbol, ast.InternalSymbolNameModuleExports, node, dontResolveAlias)
    end
    if exportModuleDotExportsSymbol ~= nil then
        -- We have a transpiled default import where the `require` resolves to an ES module with a `module.exports` named
        -- export. With `esModuleInterop` (always enabled), this will work:
        --
        -- const dep_1 = __importDefault(require("./dep.mjs")); // wraps like { default: require("./dep.mjs") }
        -- dep_1.default; // require("./dep.mjs") -> the `module.exports` export value
        self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
        return exportModuleDotExportsSymbol
    else
        exportDefaultSymbol = self:resolveExportByName(moduleSymbol, ast.InternalSymbolNameDefault, node, dontResolveAlias)
    end
    if specifier == nil then
        return exportDefaultSymbol
    end
    local hasDefaultOnly = self:isOnlyImportableAsDefault(specifier, moduleSymbol)
    local hasSyntheticDefault = self:canHaveSyntheticDefault(file, moduleSymbol, dontResolveAlias, specifier)
    if exportDefaultSymbol == nil and not hasSyntheticDefault and not hasDefaultOnly then
        if ast.IsImportClause(node) then
            self:reportNonDefaultExport(moduleSymbol, node)
        else
            local name
            if ast.IsImportOrExportSpecifier(node) then
                name = node:PropertyNameOrName()
            else
                name = node:Name()
            end
            self:errorNoModuleMemberSymbol(moduleSymbol, moduleSymbol, node, name)
        end
    elseif hasSyntheticDefault or hasDefaultOnly then
        -- per emit behavior, a synthetic default overrides a "real" .default member if `__esModule` is not present
        local resolved = self:resolveExternalModuleSymbol(moduleSymbol, dontResolveAlias)
        if resolved == nil then
            resolved = self:resolveSymbolEx(moduleSymbol, dontResolveAlias)
        end
        self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
        return resolved
    end
    self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
    return exportDefaultSymbol
end

function Checker:reportNonDefaultExport(moduleSymbol, node)
    if moduleSymbol.exports ~= nil and moduleSymbol.exports[node:Symbol().name] ~= nil then
        self:error(node, diagnostics.Module_0_has_no_default_export_Did_you_mean_to_use_import_1_from_0_instead, self:symbolToString(moduleSymbol), self:symbolToString(node:Symbol()))
    else
        local diagnostic = self:error(node:Name(), diagnostics.Module_0_has_no_default_export, self:symbolToString(moduleSymbol))
        local exportStar
        if moduleSymbol.exports ~= nil then
            exportStar = moduleSymbol.exports[ast.InternalSymbolNameExportStar]
        end
        if exportStar ~= nil then
            local defaultExport = core.Find(exportStar.declarations, function(decl)
                if not (ast.IsExportDeclaration(decl) and decl:ModuleSpecifier() ~= nil) then
                    return false
                end
                local resolvedExternalModuleName = self:resolveExternalModuleName(decl, decl:ModuleSpecifier(), false --[[ignoreErrors]])
                return resolvedExternalModuleName ~= nil and mapGet(resolvedExternalModuleName.exports, ast.InternalSymbolNameDefault) ~= nil
            end)
            if defaultExport ~= nil then
                diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(defaultExport, diagnostics.X_export_Asterisk_does_not_re_export_a_default))
            end
        end
    end
end

function Checker:resolveExportByName(moduleSymbol, name, sourceNode, dontResolveAlias)
    local exportValue = mapGet(moduleSymbol.exports, ast.InternalSymbolNameExportEquals)
    local exportSymbol
    if exportValue ~= nil then
        exportSymbol = self:getPropertyOfTypeEx(self:getTypeOfSymbol(exportValue), name, true --[[skipObjectFunctionPropertyAugment]], false --[[includeTypeOnlyMembers]])
    else
        exportSymbol = mapGet(moduleSymbol.exports, name)
    end
    local resolved = self:resolveSymbolEx(exportSymbol, dontResolveAlias)
    self:markSymbolOfAliasDeclarationIfTypeOnly(sourceNode, nil)
    return resolved
end

function Checker:getTargetOfNamespaceImport(node)
    local moduleSpecifier = self:getModuleSpecifierForImportOrExport(node)
    local immediate = self:resolveExternalModuleName(node, moduleSpecifier, false --[[ignoreErrors]])
    local resolved = self:resolveESModuleSymbol(immediate, node, moduleSpecifier)
    self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
    return resolved
end

function Checker:getTargetOfNamespaceExport(node)
    local moduleSpecifier = self:getModuleSpecifierForImportOrExport(node)
    if moduleSpecifier ~= nil then
        local immediate = self:resolveExternalModuleName(node, moduleSpecifier, false --[[ignoreErrors]])
        local resolved = self:resolveESModuleSymbol(immediate, node, moduleSpecifier)
        self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
        return resolved
    end
    return nil
end

function Checker:getTargetOfImportSpecifier(node)
    local name = node:PropertyNameOrName()
    if ast.IsImportSpecifier(node) and ast.ModuleExportNameIsDefault(name) then
        local specifier = self:getModuleSpecifierForImportOrExport(node)
        if specifier ~= nil then
            local moduleSymbol = self:resolveExternalModuleName(node, specifier, false --[[ignoreErrors]])
            if moduleSymbol ~= nil then
                return self:getTargetOfModuleDefault(moduleSymbol, node, true --[[dontResolveAlias]])
            end
        end
    end
    local root = node.parent.parent.parent -- ImportDeclaration
    if ast.IsBindingElement(node) then
        root = ast.GetRootDeclaration(node)
    end
    local resolved = self:getExternalModuleMember(root, node, true --[[dontResolveAlias]])
    self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
    return resolved
end

function Checker:getExternalModuleMember(node, specifier, dontResolveAlias)
    -- node is ImportDeclaration | ExportDeclaration | VariableDeclaration
    -- specifier is ImportSpecifier | ExportSpecifier | BindingElement | PropertyAccessExpression
    local moduleSpecifier = checker.getExternalModuleRequireArgument(node)
    if moduleSpecifier == nil then
        moduleSpecifier = ast.GetExternalModuleName(node)
    end
    local moduleSymbol = self:resolveExternalModuleName(node, moduleSpecifier, false --[[ignoreErrors]])
    local name
    if not ast.IsPropertyAccessExpression(specifier) then
        name = specifier:PropertyNameOrName()
    else
        name = specifier:Name()
    end
    if not ast.IsIdentifier(name) and not ast.IsStringLiteral(name) then
        return nil
    end
    local nameText = name:Text()
    local targetSymbol = self:resolveESModuleSymbol(moduleSymbol, specifier, moduleSpecifier)
    if targetSymbol ~= nil then
        -- Note: The empty string is a valid module export name:
        --
        --   import { "" as foo } from "./foo";
        --   export { foo as "" };
        --
        if nameText ~= "" or name.kind == Kind.StringLiteral then
            if checker.isShorthandAmbientModuleSymbol(moduleSymbol) then
                return moduleSymbol
            end
            local symbolFromVariable
            -- First check if module was specified with "export=". If so, get the member from the resolved type
            if moduleSymbol ~= nil and mapGet(moduleSymbol.exports, ast.InternalSymbolNameExportEquals) ~= nil then
                symbolFromVariable = self:getPropertyOfTypeEx(self:getTypeOfSymbol(targetSymbol), nameText, true --[[skipObjectFunctionPropertyAugment]], false --[[includeTypeOnlyMembers]])
            else
                symbolFromVariable = self:getPropertyOfVariable(targetSymbol, nameText)
            end
            -- if symbolFromVariable is export - get its final target
            symbolFromVariable = self:resolveSymbolEx(symbolFromVariable, dontResolveAlias)
            local exportContainer = targetSymbol
            if moduleSymbol ~= nil and mapGet(moduleSymbol.exports, ast.InternalSymbolNameExportEquals) ~= nil then
                -- For `export =` modules, supplemental type/namespace exports live on the original module symbol.
                exportContainer = moduleSymbol
            end
            local symbolFromModule = self:getExportOfModule(exportContainer, nameText, specifier, dontResolveAlias)
            if symbolFromModule == nil and nameText == ast.InternalSymbolNameDefault then
                local file = core.Find(moduleSymbol.declarations, ast.IsSourceFile)
                if self:isOnlyImportableAsDefault(moduleSpecifier, moduleSymbol) or self:canHaveSyntheticDefault(file, moduleSymbol, dontResolveAlias, moduleSpecifier) then
                    symbolFromModule = self:resolveExternalModuleSymbol(moduleSymbol, dontResolveAlias)
                    if symbolFromModule == nil then
                        symbolFromModule = self:resolveSymbolEx(moduleSymbol, dontResolveAlias)
                    end
                end
            end
            local symbol = symbolFromVariable
            if symbolFromModule ~= nil then
                symbol = symbolFromModule
                if symbolFromVariable ~= nil then
                    symbol = self:combineValueAndTypeSymbols(symbolFromVariable, symbolFromModule)
                end
            end
            if ast.IsImportOrExportSpecifier(specifier) and self:isOnlyImportableAsDefault(moduleSpecifier, moduleSymbol) and nameText ~= ast.InternalSymbolNameDefault then
                self:error(name, diagnostics.Named_imports_from_a_JSON_file_into_an_ECMAScript_module_are_not_allowed_when_module_is_set_to_0, core.ModuleKind_String(self.moduleKind))
            elseif symbol == nil then
                self:errorNoModuleMemberSymbol(moduleSymbol, targetSymbol, node, name)
            end
            return symbol
        end
    end
    return nil
end

function Checker:getPropertyOfVariable(symbol, name)
    if symbol.flags & SymbolFlags.Variable ~= 0 then
        local typeAnnotation = symbol.valueDeclaration:Type()
        if typeAnnotation ~= nil then
            return self:resolveSymbol(self:getPropertyOfType(self:getTypeFromTypeNode(typeAnnotation), name))
        end
    end
    return nil
end

-- This function creates a synthetic symbol that combines the value side of one symbol with the
-- type/namespace side of another symbol. Consider this example:
--
--	declare module graphics {
--	    interface Point {
--	        x: number;
--	        y: number;
--	    }
--	}
--	declare var graphics: {
--	    Point: new (x: number, y: number) => graphics.Point;
--	}
--	declare module "graphics" {
--	    export = graphics;
--	}
--
-- An 'import { Point } from "graphics"' needs to create a symbol that combines the value side 'Point'
-- property with the type/namespace side interface 'Point'.
function Checker:combineValueAndTypeSymbols(valueSymbol, typeSymbol)
    if valueSymbol == self.unknownSymbol and typeSymbol == self.unknownSymbol then
        return self.unknownSymbol
    end
    if typeSymbol.flags & SymbolFlags.Value ~= 0 then
        return typeSymbol
    end
    if valueSymbol.flags & (SymbolFlags.Type | SymbolFlags.Namespace) ~= 0 then
        return valueSymbol
    end
    local result = self:newSymbol(valueSymbol.flags | typeSymbol.flags, valueSymbol.name)
    debug.Assert(core.Len(valueSymbol.declarations) > 0 or core.Len(typeSymbol.declarations) > 0)
    -- slices.Compact(slices.Concat(...)): drop consecutive duplicates
    local declarations = {}
    for _, list in ipairs({ valueSymbol.declarations or {}, typeSymbol.declarations or {} }) do
        for _, d in ipairs(list) do
            if #declarations == 0 or declarations[#declarations] ~= d then
                declarations[#declarations + 1] = d
            end
        end
    end
    result.declarations = declarations
    result.parent = valueSymbol.parent
    if result.parent == nil then
        result.parent = typeSymbol.parent
    end
    result.valueDeclaration = valueSymbol.valueDeclaration
    result.members = cloneMap(typeSymbol.members)
    result.exports = cloneMap(valueSymbol.exports)
    return result
end

function Checker:getExportOfModule(symbol, nameText, specifier, dontResolveAlias)
    if symbol.flags & SymbolFlags.Module ~= 0 then
        local exportSymbol = mapGet(self:getExportsOfSymbol(symbol), nameText)
        local resolved = self:resolveSymbolEx(exportSymbol, dontResolveAlias)
        local exportStarDeclaration = mapGet(self.moduleSymbolLinks:Get(symbol).typeOnlyExportStarMap, nameText)
        self:markSymbolOfAliasDeclarationIfTypeOnly(specifier, exportStarDeclaration)
        return resolved
    end
    return nil
end

function Checker:isOnlyImportableAsDefault(usage, resolvedModule)
    -- In Node.js, JSON modules don't get named exports
    if ModuleKind.Node16 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext then
        local usageMode = self:getEmitSyntaxForModuleSpecifierExpression(usage)
        if usageMode == ModuleKind.ESNext then
            if resolvedModule == nil then
                resolvedModule = self:resolveExternalModuleName(usage, usage, true --[[ignoreErrors]])
            end
            local targetFile
            if resolvedModule ~= nil then
                targetFile = ast.GetSourceFileOfModule(resolvedModule)
            end
            return targetFile ~= nil and (ast.IsJsonSourceFile(targetFile) or tspath.GetDeclarationFileExtension(targetFile:FileName()) == ".d.json.ts")
        end
    end
    return false
end

function Checker:canHaveSyntheticDefault(file, moduleSymbol, dontResolveAlias, usage)
    local usageMode = ModuleKind.None
    if file ~= nil then
        usageMode = self:getEmitSyntaxForModuleSpecifierExpression(usage)
    end
    if file ~= nil and usageMode ~= ModuleKind.None then
        local targetMode = self.program:GetImpliedNodeFormatForEmit(file:AsSourceFile())
        if usageMode == ModuleKind.ESNext and targetMode == ModuleKind.CommonJS and ModuleKind.Node16 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext then
            -- In Node.js, CommonJS modules always have a synthetic default when imported into ESM
            return true
        end
        if usageMode == ModuleKind.ESNext and targetMode == ModuleKind.ESNext then
            -- No matter what the `module` setting is, if we're confident that both files
            -- are ESM, there cannot be a synthetic default.
            return false
        end
        -- For other files (not node16/nodenext with impliedNodeFormat), check if we can determine
        -- the module format from project references
        if targetMode == ModuleKind.None and file:AsSourceFile().isDeclarationFile then
            -- Try to get the project reference - try both source file mapping and output file mapping
            -- since declaration files can be mapped either way depending on how they're resolved
            if self.program:GetRedirectForResolution(file:AsSourceFile()) ~= nil or self.program:GetProjectReferenceFromOutputDts(file:AsSourceFile():Path()) ~= nil then
                -- This is a declaration file from a project reference, so we can determine
                -- its module format from the referenced project's options
                local targetModuleKind = self.program:GetEmitModuleFormatOfFile(file:AsSourceFile())
                if usageMode == ModuleKind.ESNext and ModuleKind.ES2015 <= targetModuleKind and targetModuleKind <= ModuleKind.ESNext then
                    return false
                end
            end
        end
    end
    -- Declaration files (and ambient modules)
    if file == nil or file:AsSourceFile().isDeclarationFile then
        -- Definitely cannot have a synthetic default if they have a syntactic default member specified
        local defaultExportSymbol = self:resolveExportByName(moduleSymbol, ast.InternalSymbolNameDefault --[[sourceNode]], nil --[[dontResolveAlias]], true) -- Dont resolve alias because we want the immediately exported symbol's declaration
        if defaultExportSymbol ~= nil and core.Some(defaultExportSymbol.declarations, checker.isSyntacticDefault) then
            return false
        end
        -- It _might_ still be incorrect to assume there is no __esModule marker on the import at runtime, even if there is no `default` member
        -- So we check a bit more,
        if self:resolveExportByName(moduleSymbol, "__esModule", nil --[[sourceNode]], dontResolveAlias) ~= nil then
            -- If there is an `__esModule` specified in the declaration (meaning someone explicitly added it or wrote it in their code),
            -- it definitely is a module and does not have a synthetic default
            return false
        end
        -- There are _many_ declaration files not written with esmodules in mind that still get compiled into a format with __esModule set
        -- Meaning there may be no default at runtime - however to be on the permissive side, we allow access to a synthetic default member
        -- as there is no marker to indicate if the accompanying JS has `__esModule` or not, or is even native esm
        return true
    end
    -- TypeScript files never have a synthetic default (as they are always emitted with an __esModule marker) _unless_ they contain an export= statement
    if not ast.IsInJSFile(file) then
        return checker.hasExportAssignmentSymbol(moduleSymbol)
    end

    -- JS files have a synthetic default if they do not contain ES2015+ module syntax (export = is not valid in js) _and_ do not have an __esModule marker
    return (file:AsSourceFile().externalModuleIndicator == nil or file:AsSourceFile().externalModuleIndicator == file) and self:resolveExportByName(moduleSymbol, "__esModule", nil --[[sourceNode]], dontResolveAlias) == nil
end

function Checker:getEmitSyntaxForModuleSpecifierExpression(usage)
    if ast.IsStringLiteralLike(usage) then
        return self.program:GetEmitSyntaxForUsageLocation(ast.GetSourceFileOfNode(usage), usage)
    end
    return ModuleKind.None
end

function Checker:errorNoModuleMemberSymbol(moduleSymbol, targetSymbol, node, name)
    if core.Tristate_IsTrue(self.compilerOptions.noCheck) then
        return
    end
    local moduleName = self:getFullyQualifiedName(moduleSymbol, node)
    local declarationName = scanner.DeclarationNameToString(name)
    local suggestion
    if ast.IsIdentifier(name) then
        suggestion = self:getSuggestedSymbolForNonexistentModule(name, targetSymbol)
    end
    if suggestion ~= nil then
        local suggestionName = self:symbolToString(suggestion)
        local diagnostic = self:error(name, diagnostics.X_0_has_no_exported_member_named_1_Did_you_mean_2, moduleName, declarationName, suggestionName)
        if suggestion.valueDeclaration ~= nil then
            diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(suggestion.valueDeclaration, diagnostics.X_0_is_declared_here, suggestionName))
        end
    else
        if mapGet(moduleSymbol.exports, ast.InternalSymbolNameDefault) ~= nil then
            self:error(name, diagnostics.Module_0_has_no_exported_member_1_Did_you_mean_to_use_import_1_from_0_instead, moduleName, declarationName)
        else
            self:reportNonExportedMember(name, declarationName, moduleSymbol, moduleName)
        end
    end
end

function Checker:reportNonExportedMember(name, declarationName, moduleSymbol, moduleName)
    local localSymbol
    local locals = moduleSymbol.valueDeclaration:Locals()
    if locals ~= nil then
        localSymbol = locals[name:Text()]
    end
    local exports = moduleSymbol.exports
    if localSymbol ~= nil then
        local exportedEqualsSymbol = mapGet(exports, ast.InternalSymbolNameExportEquals)
        if exportedEqualsSymbol ~= nil then
            if self:getSymbolIfSameReference(exportedEqualsSymbol, localSymbol) ~= nil then
                self:reportInvalidImportEqualsExportMember(name, declarationName, moduleName)
            else
                self:error(name, diagnostics.Module_0_has_no_exported_member_1, moduleName, declarationName)
            end
        else
            local exportedSymbol = checker.findInMap(exports or {}, function(symbol)
                return self:getSymbolIfSameReference(symbol, localSymbol) ~= nil
            end)
            local diagnostic
            if exportedSymbol ~= nil then
                diagnostic = self:error(name, diagnostics.Module_0_declares_1_locally_but_it_is_exported_as_2, moduleName, declarationName, self:symbolToString(exportedSymbol))
            else
                diagnostic = self:error(name, diagnostics.Module_0_declares_1_locally_but_it_is_not_exported, moduleName, declarationName)
            end
            for i, decl in ipairs(localSymbol.declarations or {}) do
                diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(decl, core.IfElse(i == 1, diagnostics.X_0_is_declared_here, diagnostics.X_and_here), declarationName))
            end
        end
    else
        self:error(name, diagnostics.Module_0_has_no_exported_member_1, moduleName, declarationName)
    end
end

function Checker:reportInvalidImportEqualsExportMember(name, declarationName, moduleName)
    if self.moduleKind >= ModuleKind.ES2015 then
        self:error(name, diagnostics.X_0_can_only_be_imported_by_using_a_default_import, declarationName)
    elseif ast.IsInJSFile(name) then
        self:error(name, diagnostics.X_0_can_only_be_imported_by_using_a_require_call_or_by_using_a_default_import, declarationName)
    else
        self:error(name, diagnostics.X_0_can_only_be_imported_by_using_import_1_require_2_or_a_default_import, declarationName, declarationName, moduleName)
    end
end

function Checker:getTargetOfExportSpecifier(node, meaning, dontResolveAlias)
    local name = node:PropertyNameOrName()
    if ast.ModuleExportNameIsDefault(name) then
        local specifier = self:getModuleSpecifierForImportOrExport(node)
        if specifier ~= nil then
            local moduleSymbol = self:resolveExternalModuleName(node, specifier, false --[[ignoreErrors]])
            if moduleSymbol ~= nil then
                return self:getTargetOfModuleDefault(moduleSymbol, node, dontResolveAlias)
            end
        end
    end
    local exportDeclaration = node.parent.parent
    local resolved
    if exportDeclaration:ModuleSpecifier() ~= nil then
        resolved = self:getExternalModuleMember(exportDeclaration, node, dontResolveAlias)
    elseif ast.IsStringLiteral(name) then
        resolved = nil
    else
        resolved = self:resolveEntityName(name, meaning, false --[[ignoreErrors]], dontResolveAlias, nil --[[location]])
    end
    self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
    return resolved
end

function Checker:getTargetOfExportAssignment(node)
    -- An `export =` / `export default` inside a namespace/module block is a grammar error;
    -- checkExportAssignment reports it and returns without resolving the expression. Mirror that
    -- bail-out here (using the same container computation) so that alias resolution triggered by
    -- the emit resolver does not resolve — and report "Cannot find name" diagnostics on — the
    -- expression, which would produce diagnostics inconsistent with checking.
    if checker.isContainedByNamespace(node) then
        return nil
    end
    local resolved = self:getTargetOfAliasLikeExpression(node:Expression())
    self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
    return resolved
end

function Checker:getTargetOfBinaryExpression(node)
    local resolved = self:getTargetOfAliasLikeExpression(node:AsBinaryExpression().right)
    self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
    return resolved
end

function Checker:getTargetOfAliasLikeExpression(expression)
    if ast.IsClassExpression(expression) then
        return self:checkExpressionCached(expression).symbol
    end
    if not ast.IsEntityName(expression) and not ast.IsEntityNameExpression(expression) then
        return nil
    end
    local aliasLike = self:resolveEntityName(expression, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace, true --[[ignoreErrors]], true --[[dontResolveAlias]], nil --[[location]])
    if aliasLike ~= nil then
        return aliasLike
    end
    self:checkExpressionCached(expression)
    return self:getResolvedSymbolOrNil(expression)
end

function Checker:getTargetOfNamespaceExportDeclaration(node)
    if ast.CanHaveSymbol(node.parent) then
        local resolved = self:resolveExternalModuleSymbol(node.parent:Symbol(), true --[[dontResolveAlias]])
        self:markSymbolOfAliasDeclarationIfTypeOnly(node, nil)
        return resolved
    end
    return nil
end

function Checker:getTargetOfAccessExpression(node)
    if ast.IsBinaryExpression(node.parent) then
        local expr = node.parent:AsBinaryExpression()
        if expr.left == node and expr.operatorToken.kind == Kind.EqualsToken then
            return self:getTargetOfAliasLikeExpression(expr.right)
        end
    end
    return nil
end

function Checker:getModuleSpecifierForImportOrExport(node)
    local kind = node.kind
    if kind == Kind.ImportClause then
        return checker.getModuleSpecifierFromNode(node.parent)
    elseif kind == Kind.ImportEqualsDeclaration then
        if ast.IsExternalModuleReference(node:AsImportEqualsDeclaration().moduleReference) then
            return node:AsImportEqualsDeclaration().moduleReference:Expression()
        else
            return nil
        end
    elseif kind == Kind.NamespaceImport then
        return checker.getModuleSpecifierFromNode(node.parent.parent)
    elseif kind == Kind.ImportSpecifier then
        return checker.getModuleSpecifierFromNode(node.parent.parent.parent)
    elseif kind == Kind.NamespaceExport then
        return checker.getModuleSpecifierFromNode(node.parent)
    elseif kind == Kind.ExportSpecifier then
        return checker.getModuleSpecifierFromNode(node.parent.parent)
    end
    error("Unhandled case in getModuleSpecifierForImportOrExport", 0)
end

function checker.getModuleSpecifierFromNode(node)
    local kind = node.kind
    if kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration then
        return node:ModuleSpecifier()
    elseif kind == Kind.ExportDeclaration then
        return node:ModuleSpecifier()
    end
    error("Unhandled case in getModuleSpecifierFromNode", 0)
end

--[[
 * Marks a symbol as type-only if its declaration is syntactically type-only.
 * If it is not itself marked type-only, but resolves to a type-only alias
 * somewhere in its resolution chain, save a reference to the type-only alias declaration
 * so the alias _not_ marked type-only can be identified as _transitively_ type-only.
 *
 * This function is called on each alias declaration that could be type-only or resolve to
 * another type-only alias during `resolveAlias`, so that later, when an alias is used in a
 * JS-emitting expression, we can quickly determine if that symbol is effectively type-only
 * and issue an error if so.
]]

function Checker:markSymbolOfAliasDeclarationIfTypeOnly(aliasDeclaration, exportStarDeclaration)
    if aliasDeclaration == nil or not ast.IsDeclarationNode(aliasDeclaration) then
        return false
    end
    -- If the declaration itself is type-only, mark it and return. No need to check what it resolves to.
    local sourceSymbol = self:getSymbolOfDeclaration(aliasDeclaration)
    local links = self.aliasSymbolLinks:Get(sourceSymbol)
    if links.typeOnlyDeclaration == nil and ast.IsTypeOnlyImportOrExportDeclaration(aliasDeclaration) then
        links.typeOnlyDeclaration = aliasDeclaration
        return true
    end
    if links.typeOnlyDeclaration == nil and exportStarDeclaration ~= nil then
        links.typeOnlyDeclaration = exportStarDeclaration
        return true
    end
    return links.typeOnlyDeclaration ~= nil
end

function Checker:resolveExternalModuleName(location, moduleReferenceExpression, ignoreErrors)
    local errorMessage = self:getCannotResolveModuleNameErrorForSpecificModule(moduleReferenceExpression)
    if errorMessage == nil then
        errorMessage = diagnostics.Cannot_find_module_0_or_its_corresponding_type_declarations
    end
    ignoreErrors = ignoreErrors or core.Tristate_IsTrue(self.compilerOptions.noCheck)
    return self:resolveExternalModuleNameWorker(location, moduleReferenceExpression, core.IfElse(ignoreErrors, nil, errorMessage), ignoreErrors, false --[[isForAugmentation]])
end

function Checker:getCannotResolveModuleNameErrorForSpecificModule(moduleName)
    if ast.IsStringLiteral(moduleName) then
        if core.NodeCoreModules()[moduleName:Text()] then
            if self.compilerOptions:UsesWildcardTypes() then
                return diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_node_Try_npm_i_save_dev_types_Slashnode
            end
            return diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_node_Try_npm_i_save_dev_types_Slashnode_and_then_add_node_to_the_types_field_in_your_tsconfig
        end
    end
    return nil
end

function Checker:resolveExternalModuleNameWorker(location, moduleReferenceExpression, moduleNotFoundError, ignoreErrors, isForAugmentation)
    if ast.IsStringLiteralLike(moduleReferenceExpression) then
        return self:resolveExternalModule(location, moduleReferenceExpression:Text(), moduleNotFoundError, core.IfElse(not ignoreErrors, moduleReferenceExpression, nil), isForAugmentation)
    end
    return nil
end

function Checker:getExternalModuleFileFromDeclaration(declaration)
    local specifier
    if declaration.kind == Kind.ModuleDeclaration then
        if ast.IsStringLiteral(declaration:Name()) then
            specifier = declaration:Name()
        end
    else
        specifier = ast.GetExternalModuleName(declaration)
    end
    local moduleSymbol = self:resolveExternalModuleNameWorker(specifier, specifier --[[moduleNotFoundError]], nil, false, false) -- TODO: GH#18217
    if moduleSymbol == nil then
        return nil
    end
    local decl = ast.GetDeclarationOfKind(moduleSymbol, Kind.SourceFile)
    if decl == nil then
        return nil
    end
    return decl:AsSourceFile()
end

function Checker:resolveExternalModule(location, moduleReference, moduleNotFoundError, errorNode, isForAugmentation)
    if errorNode ~= nil and string.sub(moduleReference, 1, #"@types/") == "@types/" then
        local withoutAtTypePrefix = string.sub(moduleReference, #"@types/" + 1)
        self:error(errorNode, diagnostics.Cannot_import_type_declaration_files_Consider_importing_0_instead_of_1, withoutAtTypePrefix, moduleReference)
    end
    local ambientModule = self:tryFindAmbientModule(moduleReference, true --[[withAugmentations]])
    if ambientModule ~= nil then
        return ambientModule
    end

    local importingSourceFile = ast.GetSourceFileOfNode(location)
    local contextSpecifier
    local mode

    if ast.IsStringLiteralLike(location) or location.parent ~= nil and ast.IsModuleDeclaration(location.parent) and location.parent:AsModuleDeclaration():Name() == location then
        contextSpecifier = location
    elseif ast.IsModuleDeclaration(location) then
        contextSpecifier = location:AsModuleDeclaration():Name()
    elseif ast.IsLiteralImportTypeNode(location) then
        contextSpecifier = location:AsImportTypeNode().argument:AsLiteralTypeNode().literal
    elseif ast.IsVariableDeclarationInitializedToBareOrAccessedRequire(location) then
        contextSpecifier = ast.GetModuleSpecifierOfBareOrAccessedRequire(location)
    else
        local ancestor = ast.FindAncestor(location, ast.IsImportCall)
        if ancestor ~= nil then
            contextSpecifier = ancestor:Arguments()[1]
        end

        if ancestor == nil then
            ancestor = ast.FindAncestor(location, ast.IsImportDeclarationOrJSImportDeclaration)
            if ancestor ~= nil then
                contextSpecifier = ancestor:ModuleSpecifier()
            end
        end
        if ancestor == nil then
            ancestor = ast.FindAncestor(location, ast.IsExportDeclaration)
            if ancestor ~= nil then
                contextSpecifier = ancestor:ModuleSpecifier()
            end
        end
        if ancestor == nil then
            ancestor = ast.FindAncestor(location, ast.IsImportEqualsDeclaration)
            if ancestor ~= nil then
                local moduleRefrence = ancestor:AsImportEqualsDeclaration().moduleReference
                if moduleRefrence.kind == Kind.ExternalModuleReference then
                    contextSpecifier = moduleRefrence:Expression()
                end
            end
        end
    end

    if contextSpecifier ~= nil and ast.IsStringLiteralLike(contextSpecifier) then
        mode = self.program:GetModeForUsageLocation(importingSourceFile, contextSpecifier)
    else
        mode = self.program:GetDefaultResolutionModeForFile(importingSourceFile)
    end

    local resolvedModule = self.program:GetResolvedModule(importingSourceFile, moduleReference, mode)
    local isResolved = module.ResolvedModule.IsResolved(resolvedModule)

    local resolutionDiagnostic
    if errorNode ~= nil and isResolved then
        resolutionDiagnostic = module.GetResolutionDiagnostic(self.compilerOptions, resolvedModule, importingSourceFile)
    end

    local sourceFile
    if isResolved and (resolutionDiagnostic == nil or resolutionDiagnostic == diagnostics.Module_0_was_resolved_to_1_but_jsx_is_not_set) then
        sourceFile = self.program:GetSourceFileForResolvedModule(resolvedModule.resolvedFileName)
    end

    if sourceFile ~= nil then
        -- If there's a resolutionDiagnostic we need to report it even if a sourceFile is found.
        if resolutionDiagnostic ~= nil then
            self:error(errorNode, resolutionDiagnostic, moduleReference, resolvedModule.resolvedFileName)
        end

        if errorNode ~= nil then
            if resolvedModule.resolvedUsingTsExtension and tspath.IsDeclarationFileName(moduleReference) then
                if ast.FindAncestor(location, ast.IsEmittableImport) ~= nil then
                    local tsExtension = tspath.TryExtractTSExtension(moduleReference)
                    if tsExtension == "" then
                        error("should be able to extract TS extension from string that passes IsDeclarationFileName", 0)
                    end
                    self:error(
                        errorNode,
                        diagnostics.A_declaration_file_cannot_be_imported_without_import_type_Did_you_mean_to_import_an_implementation_file_0_instead,
                        self:getSuggestedImportSource(moduleReference, tsExtension, mode)
                    )
                end
            elseif resolvedModule.resolvedUsingTsExtension and not self.compilerOptions:AllowImportingTsExtensionsFrom(importingSourceFile:FileName()) then
                if ast.FindAncestor(location, ast.IsEmittableImport) ~= nil then
                    local tsExtension = tspath.TryExtractTSExtension(moduleReference)
                    if tsExtension == "" then
                        -- Fallback: do a best-effort extraction using strings.Contains.
                        -- This handles cases where a wildcard pattern matches a TS extension that's
                        -- not at the end of the module specifier, e.g., "#/foo.ts.omg" through "#/*.omg": "./src/*"
                        for _, ext in ipairs(tspath.SupportedTSExtensionsFlat) do
                            if string.find(moduleReference, ext, 1, true) ~= nil then
                                tsExtension = ext
                                break
                            end
                        end
                    end
                    if tsExtension == "" then
                        error("should be able to extract TS extension from string when resolvedUsingTsExtension is true", 0)
                    end
                    self:error(
                        errorNode,
                        diagnostics.An_import_path_can_only_end_with_a_0_extension_when_allowImportingTsExtensions_is_enabled,
                        tsExtension
                    )
                end
            elseif core.Tristate_IsTrue(self.compilerOptions.rewriteRelativeImportExtensions) and
                location.flags & NodeFlags.Ambient == 0 and
                not tspath.IsDeclarationFileName(moduleReference) and
                not ast.IsLiteralImportTypeNode(location) and
                not ast.IsPartOfTypeOnlyImportOrExportDeclaration(location) then
                local shouldRewrite = core.ShouldRewriteModuleSpecifier(moduleReference, self.compilerOptions)
                if not resolvedModule.resolvedUsingTsExtension and shouldRewrite then
                    local relativeToSourceFile = tspath.GetRelativePathFromFile(
                        tspath.GetNormalizedAbsolutePath(importingSourceFile:FileName(), self.program:GetCurrentDirectory()),
                        resolvedModule.resolvedFileName,
                        tspath.NewComparePathsOptions(self.program:UseCaseSensitiveFileNames(), self.program:GetCurrentDirectory())
                    )
                    self:error(
                        errorNode,
                        diagnostics.This_relative_import_path_is_unsafe_to_rewrite_because_it_looks_like_a_file_name_but_actually_resolves_to_0,
                        relativeToSourceFile
                    )
                elseif resolvedModule.resolvedUsingTsExtension and not shouldRewrite and self.program:SourceFileMayBeEmitted(sourceFile, false) then
                    self:error(
                        errorNode,
                        diagnostics.This_import_uses_a_0_extension_to_resolve_to_an_input_TypeScript_file_but_will_not_be_rewritten_during_emit_because_it_is_not_a_relative_path,
                        tspath.GetAnyExtensionFromPath(moduleReference, nil, false)
                    )
                elseif resolvedModule.resolvedUsingTsExtension and shouldRewrite then
                    local redirect = self.program:GetRedirectForResolution(sourceFile)
                    if redirect ~= nil then
                        local ownRootDir = self.program:CommonSourceDirectory()
                        local otherRootDir = redirect:CommonSourceDirectory()

                        local compareOptions = tspath.NewComparePathsOptions(self.program:UseCaseSensitiveFileNames(), self.program:GetCurrentDirectory())

                        local rootDirPath = tspath.GetRelativePathFromDirectory(ownRootDir, otherRootDir, compareOptions)

                        -- Get outDir paths, defaulting to root directories if not specified
                        local ownOutDir = self.compilerOptions.outDir
                        if ownOutDir == "" then
                            ownOutDir = ownRootDir
                        end
                        local otherOutDir = redirect:CompilerOptions().outDir
                        if otherOutDir == "" then
                            otherOutDir = otherRootDir
                        end
                        local outDirPath = tspath.GetRelativePathFromDirectory(ownOutDir, otherOutDir, compareOptions)

                        if rootDirPath ~= outDirPath then
                            self:error(
                                errorNode,
                                diagnostics.This_import_path_is_unsafe_to_rewrite_because_it_resolves_to_another_project_and_the_relative_path_between_the_projects_output_files_is_not_the_same_as_the_relative_path_between_its_input_files
                            )
                        end
                    end
                end
            end
        end

        if sourceFile.symbol ~= nil then
            if errorNode ~= nil then
                if resolvedModule.isExternalLibraryImport and not checker.resolutionExtensionIsTSOrJson(resolvedModule.extension) then
                    self:errorOnImplicitAnyModule(false --[[isError]], errorNode, mode, resolvedModule, moduleReference)
                end
                if self.moduleKind == ModuleKind.Node16 or self.moduleKind == ModuleKind.Node18 then
                    local isSyncImport = self.program:GetDefaultResolutionModeForFile(importingSourceFile) == ModuleKind.CommonJS and ast.FindAncestor(location, ast.IsImportCall) == nil or
                        ast.FindAncestor(location, ast.IsImportEqualsDeclaration) ~= nil
                    local overrideHost = ast.FindAncestor(location, ast.IsResolutionModeOverrideHost)
                    if isSyncImport and self.program:GetDefaultResolutionModeForFile(sourceFile) == ModuleKind.ESNext and not ast.HasResolutionModeOverride(overrideHost) then
                        if ast.FindAncestorKind(location, Kind.ImportEqualsDeclaration) ~= nil then
                            -- ImportEquals in an ESM file resolving to another ESM file
                            self:error(errorNode, diagnostics.Module_0_cannot_be_imported_using_this_construct_The_specifier_only_resolves_to_an_ES_module_which_cannot_be_imported_with_require_Use_an_ECMAScript_import_instead, moduleReference)
                        else
                            -- CJS file resolving to an ESM file
                            local diagnosticDetails
                            local ext = tspath.TryGetExtensionFromPath(importingSourceFile:FileName())
                            if ext == tspath.ExtensionTs or ext == tspath.ExtensionJs or ext == tspath.ExtensionTsx or ext == tspath.ExtensionJsx then
                                diagnosticDetails = self:createModeMismatchDetails(importingSourceFile, errorNode)
                            end

                            local message
                            if overrideHost ~= nil and overrideHost.kind == Kind.ImportDeclaration and overrideHost:ImportClause() ~= nil and overrideHost:ImportClause():IsTypeOnly() then
                                message = diagnostics.Type_only_import_of_an_ECMAScript_module_from_a_CommonJS_module_must_have_a_resolution_mode_attribute
                            elseif overrideHost ~= nil and overrideHost.kind == Kind.ImportType then
                                message = diagnostics.Type_import_of_an_ECMAScript_module_from_a_CommonJS_module_must_have_a_resolution_mode_attribute
                            else
                                message = diagnostics.The_current_file_is_a_CommonJS_module_whose_imports_will_produce_require_calls_however_the_referenced_file_is_an_ECMAScript_module_and_cannot_be_imported_with_require_Consider_writing_a_dynamic_import_0_call_instead
                            end

                            self:addDiagnostic(checker.NewDiagnosticChainForNode(diagnosticDetails, errorNode, message, moduleReference))
                        end
                    end
                end
            end
            return self:getMergedSymbol(sourceFile.symbol)
        end
        if errorNode ~= nil and moduleNotFoundError ~= nil and not checker.isSideEffectImport(errorNode) then
            self:error(errorNode, diagnostics.File_0_is_not_a_module, resolvedModule.resolvedFileName)
        end
        return nil
    end

    if core.Len(self.patternAmbientModules) ~= 0 then
        local pattern = core.FindBestPatternMatch(self.patternAmbientModules, function(v)
            return v.pattern
        end, moduleReference)
        if pattern ~= nil then
            local augmentation = (self.patternAmbientModuleAugmentations or {})[moduleReference]
            if augmentation ~= nil then
                return self:getMergedSymbol(augmentation)
            end
            return self:getMergedSymbol(pattern.symbol)
        end
    end

    if errorNode == nil then
        return nil
    end

    if isResolved and not checker.resolutionExtensionIsTSOrJson(resolvedModule.extension) and resolutionDiagnostic == nil or resolutionDiagnostic == diagnostics.Could_not_find_a_declaration_file_for_module_0_1_implicitly_has_an_any_type then
        if isForAugmentation then
            self:error(
                errorNode,
                diagnostics.Invalid_module_name_in_augmentation_Module_0_resolves_to_an_untyped_module_at_1_which_cannot_be_augmented,
                moduleReference,
                resolvedModule.resolvedFileName
            )
        else
            self:errorOnImplicitAnyModule(self.noImplicitAny and moduleNotFoundError ~= nil, errorNode, mode, resolvedModule, moduleReference)
        end
        return nil
    end

    if moduleNotFoundError ~= nil then
        -- See if this was possibly a projectReference redirect
        if isResolved then
            local redirect = self.program:GetProjectReferenceFromSource(tspath.ToPath(resolvedModule.resolvedFileName, self.program:GetCurrentDirectory(), self.program:UseCaseSensitiveFileNames()))
            if redirect ~= nil and redirect.outputDts ~= "" then
                self:error(
                    errorNode,
                    diagnostics.Output_file_0_has_not_been_built_from_source_file_1,
                    redirect.outputDts,
                    resolvedModule.resolvedFileName
                )
                return nil
            end
        end

        if resolutionDiagnostic ~= nil then
            self:error(errorNode, resolutionDiagnostic, moduleReference, resolvedModule.resolvedFileName)
        else
            local isExtensionlessRelativePathImport = tspath.PathIsRelative(moduleReference) and not tspath.HasExtension(moduleReference)
            local resolutionIsNode16OrNext = self.moduleResolutionKind == core.ModuleResolutionKind.Node16 or self.moduleResolutionKind == core.ModuleResolutionKind.NodeNext
            if not self.compilerOptions:GetResolveJsonModule() and tspath.FileExtensionIs(moduleReference, tspath.ExtensionJson) then
                self:error(errorNode, diagnostics.Cannot_find_module_0_Consider_using_resolveJsonModule_to_import_module_with_json_extension, moduleReference)
            elseif mode == ModuleKind.ResolutionModeESM and resolutionIsNode16OrNext and isExtensionlessRelativePathImport then
                local absoluteRef = tspath.GetNormalizedAbsolutePath(moduleReference, tspath.GetDirectoryPath(importingSourceFile:FileName()))
                local suggestedExt = self:getSuggestedImportExtension(absoluteRef)
                if suggestedExt ~= "" then
                    self:error(errorNode, diagnostics.Relative_import_paths_need_explicit_file_extensions_in_ECMAScript_imports_when_moduleResolution_is_node16_or_nodenext_Did_you_mean_0, moduleReference .. suggestedExt)
                else
                    self:error(errorNode, diagnostics.Relative_import_paths_need_explicit_file_extensions_in_ECMAScript_imports_when_moduleResolution_is_node16_or_nodenext_Consider_adding_an_extension_to_the_import_path)
                end
            elseif resolvedModule ~= nil and resolvedModule.alternateResult ~= "" then
                local errorInfo = self:createModuleNotFoundChain(resolvedModule, errorNode, moduleReference, mode, moduleReference)
                self:addDiagnostic(checker.NewDiagnosticChainForNode(errorInfo, errorNode, moduleNotFoundError, moduleReference))
            else
                self:error(errorNode, moduleNotFoundError, moduleReference)
            end
        end
    end

    return nil
end

function checker.resolutionExtensionIsTSOrJson(ext)
    return tspath.ExtensionIsTs(ext) or ext == tspath.ExtensionJson
end

function Checker:getSuggestedImportSource(moduleReference, tsExtension, mode)
    local importSourceWithoutExtension = tspath.RemoveExtension(moduleReference, tsExtension)

    -- Direct users to import source with .js extension if outputting an ES module.
    -- @see https://github.com/microsoft/TypeScript/issues/42151
    if core.ModuleKind_IsNonNodeESM(self.moduleKind) or mode == ModuleKind.ESNext then
        local preferTs = tspath.IsDeclarationFileName(moduleReference) and self.compilerOptions:GetAllowImportingTsExtensions()
        local ext
        if tsExtension == tspath.ExtensionMts or tsExtension == tspath.ExtensionDmts then
            ext = core.IfElse(preferTs, ".mts", ".mjs")
        elseif tsExtension == tspath.ExtensionCts or tsExtension == tspath.ExtensionDcts then
            ext = core.IfElse(preferTs, ".cts", ".cjs")
        else
            ext = core.IfElse(preferTs, ".ts", ".js")
        end

        return importSourceWithoutExtension .. ext
    end

    return importSourceWithoutExtension
end

function Checker:getSuggestedImportExtension(extensionlessImportPath)
    if self.program:FileExists(extensionlessImportPath .. ".mts") then
        return ".mjs"
    elseif self.program:FileExists(extensionlessImportPath .. ".ts") then
        return ".js"
    elseif self.program:FileExists(extensionlessImportPath .. ".cts") then
        return ".cjs"
    elseif self.program:FileExists(extensionlessImportPath .. ".mjs") then
        return ".mjs"
    elseif self.program:FileExists(extensionlessImportPath .. ".js") then
        return ".js"
    elseif self.program:FileExists(extensionlessImportPath .. ".cjs") then
        return ".cjs"
    elseif self.program:FileExists(extensionlessImportPath .. ".tsx") then
        return core.IfElse(self.compilerOptions.jsx == core.JsxEmit.Preserve, ".jsx", ".js")
    elseif self.program:FileExists(extensionlessImportPath .. ".jsx") then
        return ".jsx"
    elseif self.program:FileExists(extensionlessImportPath .. ".json") then
        return ".json"
    end
    return ""
end

function Checker:errorOnImplicitAnyModule(isError, errorNode, mode, resolvedModule, moduleReference)
    if checker.isSideEffectImport(errorNode) then
        return
    end

    local errorInfo
    if not tspath.IsExternalModuleNameRelative(moduleReference) and resolvedModule.packageId.name ~= "" then
        errorInfo = self:createModuleNotFoundChain(resolvedModule, errorNode, moduleReference, mode, resolvedModule.packageId.name)
    end
    self:addErrorOrSuggestion(
        isError,
        checker.NewDiagnosticChainForNode(
            errorInfo,
            errorNode,
            diagnostics.Could_not_find_a_declaration_file_for_module_0_1_implicitly_has_an_any_type,
            moduleReference,
            resolvedModule.resolvedFileName
        )
    )
end

function Checker:createModuleNotFoundChain(resolvedModule, errorNode, moduleReference, mode, packageName) -- luacheck: ignore resolvedModule
    -- Store the original packageName for repopulateInfo before any modifications
    local storedPackageName = packageName
    if storedPackageName == moduleReference then
        storedPackageName = ""
    end

    local details = checker.CreateModuleNotFoundChain(self.program, ast.GetSourceFileOfNode(errorNode), moduleReference, mode, packageName)
    local result = checker.NewDiagnosticForNode(errorNode, details.message, table.unpack(details.args or {}))
    result:SetRepopulateInfo({
        kind = ast.RepopulateDiagnosticKind.RepopulateModuleNotFound,
        moduleReference = moduleReference,
        mode = mode,
        packageName = storedPackageName,
    })
    return result
end

function Checker:createModeMismatchDetails(sourceFile, errorNode)
    local details = checker.CreateModeMismatchDetails(self.program, sourceFile)
    local result = checker.NewDiagnosticForNode(errorNode, details.message, table.unpack(details.args or {}))
    result:SetRepopulateInfo({
        kind = ast.RepopulateDiagnosticKind.RepopulateModeMismatch,
        moduleReference = "",
        mode = ModuleKind.None,
        packageName = "",
    })
    return result
end

function Checker:tryFindAmbientModule(moduleName, withAugmentations)
    if tspath.IsExternalModuleNameRelative(moduleName) then
        return nil
    end
    local symbol = self:getSymbol(self.globals, "\"" .. moduleName .. "\"", SymbolFlags.ValueModule)
    -- merged symbol is module declaration symbol combined with all augmentations
    if withAugmentations then
        return self:getMergedSymbol(symbol)
    end
    return symbol
end

function Checker:GetAmbientModules()
    self.ambientModulesOnce:Do(function()
        for sym, global in pairs(self.globals) do
            if string.sub(sym, 1, 1) == "\"" and #sym >= 1 and string.sub(sym, -1) == "\"" then
                self.ambientModules = core.Append(self.ambientModules, global)
            end
        end
    end)
    return self.ambientModules
end

function Checker:resolveExternalModuleSymbol(moduleSymbol, dontResolveAlias)
    if moduleSymbol ~= nil then
        local exportEquals = self:resolveSymbolEx(mapGet(moduleSymbol.exports, ast.InternalSymbolNameExportEquals), dontResolveAlias)
        if exportEquals ~= nil then
            return self:getMergedSymbol(exportEquals)
        end
    end
    return moduleSymbol
end

-- Resolves the given external module symbol, possibly removing call and construct signatures or creating a
-- wrapper module with a synthetic default.
function Checker:resolveESModuleSymbol(moduleSymbol, node, moduleSpecifier)
    local symbol = self:resolveExternalModuleSymbol(moduleSymbol, true --[[dontResolveAlias]])
    if ast.IsNonLocalAlias(symbol, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace) then
        -- When the module has an export= with a pure alias, we transitively resolve and propagate any typeOnlyDeclaration
        symbol = self:getMergedSymbol(self:resolveIndirectionAlias(self:getSymbolOfDeclaration(node), symbol))
    end
    if symbol ~= nil then
        local referenceParent = moduleSpecifier.parent
        local namespaceImport
        if ast.IsImportDeclaration(referenceParent) then
            namespaceImport = ast.GetNamespaceDeclarationNode(referenceParent)
        end
        if namespaceImport ~= nil or ast.IsImportCall(referenceParent) then
            local reference
            if ast.IsImportCall(referenceParent) then
                reference = referenceParent:Arguments()[1]
            else
                reference = referenceParent:ModuleSpecifier()
            end
            local typ = self:getTypeOfSymbol(symbol)
            local defaultOnlyType = self:getTypeWithSyntheticDefaultOnly(typ, symbol, moduleSymbol, reference)
            if defaultOnlyType ~= nil then
                return self:cloneTypeAsModuleType(symbol, defaultOnlyType, referenceParent)
            end

            local targetFile = core.Find(moduleSymbol.declarations, ast.IsSourceFile)
            local usageMode = self:getEmitSyntaxForModuleSpecifierExpression(reference)
            local exportModuleDotExportsSymbol
            if namespaceImport ~= nil and targetFile ~= nil and
                ModuleKind.Node20 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext and
                usageMode == ModuleKind.CommonJS and
                self.program:GetImpliedNodeFormatForEmit(targetFile:AsSourceFile()) == ModuleKind.ESNext then
                exportModuleDotExportsSymbol = self:getExportOfModule(symbol, ast.InternalSymbolNameModuleExports, namespaceImport, true --[[dontResolveAlias]])
            end
            if exportModuleDotExportsSymbol ~= nil then
                if self:hasSignatures(typ) then
                    return self:cloneTypeAsModuleType(exportModuleDotExportsSymbol, typ, referenceParent)
                end
                return exportModuleDotExportsSymbol
            end

            local isEsmCjsRef = targetFile ~= nil and checker.isESMFormatImportImportingCommonjsFormatFile(usageMode, self.program:GetImpliedNodeFormatForEmit(targetFile:AsSourceFile()))
            if self:hasSignatures(typ) or self:getPropertyOfTypeEx(typ, ast.InternalSymbolNameDefault, true --[[skipObjectFunctionPropertyAugment]], false --[[includeTypeOnlyMembers]]) ~= nil or isEsmCjsRef then
                local moduleType
                if typ:Flags() & TypeFlags.StructuredType ~= 0 then
                    moduleType = self:getTypeWithSyntheticDefaultImportType(typ, symbol, moduleSymbol, reference)
                else
                    moduleType = self:createDefaultPropertyWrapperForModule(symbol, symbol.parent, nil)
                end
                return self:cloneTypeAsModuleType(symbol, moduleType, referenceParent)
            end
        end
    end
    return symbol
end

function Checker:hasSignatures(t)
    return core.Len(self:getSignaturesOfStructuredType(t, SignatureKind.Call)) > 0 or core.Len(self:getSignaturesOfStructuredType(t, SignatureKind.Construct)) > 0
end

function checker.isESMFormatImportImportingCommonjsFormatFile(usageMode, targetMode)
    return usageMode == ModuleKind.ESNext and targetMode == ModuleKind.CommonJS
end

function Checker:getTypeWithSyntheticDefaultOnly(t, symbol, originalSymbol, moduleSpecifier)
    local hasDefaultOnly = self:isOnlyImportableAsDefault(moduleSpecifier, nil)
    if hasDefaultOnly and t ~= nil and not self:isErrorType(t) then
        local key = checker.CachedTypeKey(checker.CachedTypeKind.DefaultOnlyType, t.id)
        local cached = self.cachedTypes[key]
        if cached ~= nil then
            return cached
        end
        local result = self:createDefaultPropertyWrapperForModule(symbol, originalSymbol, nil)
        self.cachedTypes[key] = result
        return result
    end
    return nil
end

function Checker:getTypeWithSyntheticDefaultImportType(t, symbol, originalSymbol, moduleSpecifier)
    if t ~= nil and not self:isErrorType(t) then
        local key = checker.CachedTypeKey(checker.CachedTypeKind.SyntheticType, t.id)
        local cached = self.cachedTypes[key]
        if cached ~= nil then
            return cached
        end
        local file = core.Find(originalSymbol.declarations, ast.IsSourceFile)
        local hasSyntheticDefault = self:canHaveSyntheticDefault(file, originalSymbol, false --[[dontResolveAlias]], moduleSpecifier)
        local syntheticType
        if hasSyntheticDefault then
            local anonymousSymbol = self:newSymbol(SymbolFlags.TypeLiteral, ast.InternalSymbolNameType)
            anonymousSymbol.declarations = originalSymbol.declarations
            local defaultContainingObject = self:createDefaultPropertyWrapperForModule(symbol, originalSymbol, anonymousSymbol)
            self.valueSymbolLinks:Get(anonymousSymbol).resolvedType = defaultContainingObject
            if self:isValidSpreadType(t) then
                syntheticType = self:getSpreadType(t, defaultContainingObject, anonymousSymbol, 0 --[[objectFlags]], false --[[readonly]])
            else
                syntheticType = defaultContainingObject
            end
        else
            syntheticType = t
        end
        self.cachedTypes[key] = syntheticType
        return syntheticType
    end
    return t
end

function Checker:isCommonJSRequire(node)
    if not ast.IsRequireCall(node, true --[[requireStringLiteralLikeArgument]]) then
        return false
    end
    if not ast.IsIdentifier(node:Expression()) then
        error("Expected identifier for require call", 0)
    end
    -- Make sure require is not a local function
    local resolvedRequire = self.resolveName(node:Expression(), node:Expression():Text(), SymbolFlags.Value, nil --[[nameNotFoundMessage]], true --[[isUse]], false --[[excludeGlobals]])
    if resolvedRequire == self.requireSymbol then
        return true
    end
    -- project includes symbol named 'require' - make sure that it is ambient and local non-alias
    if resolvedRequire == nil or resolvedRequire.flags & SymbolFlags.Alias ~= 0 then
        return false
    end

    local targetDeclarationKind
    if resolvedRequire.flags & SymbolFlags.Function ~= 0 then
        targetDeclarationKind = Kind.FunctionDeclaration
    elseif resolvedRequire.flags & SymbolFlags.Variable ~= 0 then
        targetDeclarationKind = Kind.VariableDeclaration
    else
        targetDeclarationKind = Kind.Unknown
    end
    if targetDeclarationKind ~= Kind.Unknown then
        local decl = ast.GetDeclarationOfKind(resolvedRequire, targetDeclarationKind)
        -- function/variable declaration should be ambient
        return decl ~= nil and decl.flags & NodeFlags.Ambient ~= 0
    end
    return false
end

function Checker:createDefaultPropertyWrapperForModule(symbol, originalSymbol, anonymousSymbol)
    local memberTable = {}
    local newSymbol = self:newSymbol(SymbolFlags.Alias, ast.InternalSymbolNameDefault)
    newSymbol.parent = originalSymbol
    self.valueSymbolLinks:Get(newSymbol).nameType = self:getStringLiteralType("default")
    self.aliasSymbolLinks:Get(newSymbol).aliasTarget = self:resolveSymbol(symbol)
    memberTable[ast.InternalSymbolNameDefault] = newSymbol
    if anonymousSymbol == nil and originalSymbol ~= nil then
        anonymousSymbol = self:newSymbol(SymbolFlags.ObjectLiteral, ast.InternalSymbolNameObject)
        anonymousSymbol.declarations = originalSymbol.declarations
    end
    return self:newAnonymousType(anonymousSymbol, memberTable, nil, nil, nil)
end

function Checker:cloneTypeAsModuleType(symbol, moduleType, referenceParent)
    local result = self:newSymbol(symbol.flags, symbol.name)
    if symbol.declarations ~= nil then
        result.declarations = core.Slice(symbol.declarations, 0, #symbol.declarations)
    end
    result.valueDeclaration = symbol.valueDeclaration
    result.members = cloneMap(symbol.members)
    result.exports = cloneMap(symbol.exports)
    result.parent = symbol.parent
    local links = self.exportTypeLinks:Get(result)
    links.target = symbol
    links.originatingImport = referenceParent
    local resolvedModuleType = self:resolveStructuredTypeMembers(moduleType)
    self.valueSymbolLinks:Get(result).resolvedType = self:newAnonymousType(result, resolvedModuleType.members, nil, nil, resolvedModuleType.indexInfos)
    return result
end

function Checker:getTargetOfAliasDeclaration(node)
    if node == nil then
        return nil
    end
    local kind = node.kind
    if kind == Kind.ImportEqualsDeclaration or kind == Kind.VariableDeclaration then
        return self:getTargetOfImportEqualsDeclaration(node)
    elseif kind == Kind.ImportClause then
        return self:getTargetOfImportClause(node)
    elseif kind == Kind.NamespaceImport then
        return self:getTargetOfNamespaceImport(node)
    elseif kind == Kind.NamespaceExport then
        return self:getTargetOfNamespaceExport(node)
    elseif kind == Kind.ImportSpecifier or kind == Kind.BindingElement then
        return self:getTargetOfImportSpecifier(node)
    elseif kind == Kind.ExportSpecifier then
        return self:getTargetOfExportSpecifier(node, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace, true --[[dontRecursivelyResolve]])
    elseif kind == Kind.ExportAssignment then
        return self:getTargetOfExportAssignment(node)
    elseif kind == Kind.BinaryExpression then
        return self:getTargetOfBinaryExpression(node)
    elseif kind == Kind.NamespaceExportDeclaration then
        return self:getTargetOfNamespaceExportDeclaration(node)
    elseif kind == Kind.ShorthandPropertyAssignment then
        return self:resolveEntityName(node:AsShorthandPropertyAssignment():Name(), SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace, true --[[ignoreErrors]], true --[[dontRecursivelyResolve]], nil --[[location]])
    elseif kind == Kind.PropertyAssignment then
        return self:getTargetOfAliasLikeExpression(node:Initializer())
    elseif kind == Kind.ElementAccessExpression or kind == Kind.PropertyAccessExpression then
        return self:getTargetOfAccessExpression(node)
    end
    error("Unhandled case in getTargetOfAliasDeclaration: " .. ast.Kind_String(node.kind), 0)
end

--[[
 * Resolves a qualified name and any involved aliases.
]]
function Checker:resolveEntityName(name, meaning, ignoreErrors, dontResolveAlias, location)
    if ast.NodeIsMissing(name) then
        return nil
    end
    local symbol
    local kind = name.kind
    if kind == Kind.Identifier then
        local message
        if not ignoreErrors then
            if meaning == SymbolFlags.Namespace or ast.NodeIsSynthesized(name) then
                message = diagnostics.Cannot_find_namespace_0
            else
                message = self:getCannotFindNameDiagnosticForName(ast.GetFirstIdentifier(name))
            end
        end
        local resolveLocation = location
        if resolveLocation == nil then
            resolveLocation = name
        end
        if meaning == SymbolFlags.Namespace then
            symbol = self:getMergedSymbol(self.resolveName(resolveLocation, name:Text(), meaning, nil, true --[[isUse]], false --[[excludeGlobals]]))
            if symbol == nil then
                local alias = self:getMergedSymbol(self.resolveName(resolveLocation, name:Text(), SymbolFlags.Alias, nil, true --[[isUse]], false --[[excludeGlobals]]))
                if alias ~= nil and alias.name == ast.InternalSymbolNameExportEquals then
                    -- resolve typedefs exported from commonjs, stored on the module symbol
                    symbol = alias.parent
                end
            end
            if symbol == nil and message ~= nil then
                self.resolveName(resolveLocation, name:Text(), meaning, message, true --[[isUse]], false --[[excludeGlobals]])
            end
        else
            symbol = self:getMergedSymbol(self.resolveName(resolveLocation, name:Text(), meaning, message, true --[[isUse]], false --[[excludeGlobals]]))
        end
    elseif kind == Kind.QualifiedName then
        local qualified = name:AsQualifiedName()
        symbol = self:resolveQualifiedName(name, qualified.left, qualified.right, meaning, ignoreErrors, location)
    elseif kind == Kind.PropertyAccessExpression then
        local access = name:AsPropertyAccessExpression()
        symbol = self:resolveQualifiedName(name, access.expression, access:Name(), meaning, ignoreErrors, location)
    else
        error("Unknown entity name kind", 0)
    end
    if symbol ~= nil and symbol ~= self.unknownSymbol then
        if not ast.NodeIsSynthesized(name) and ast.IsEntityName(name) and
            (symbol.flags & SymbolFlags.Alias ~= 0 or name.parent ~= nil and name.parent.kind == Kind.ExportAssignment) then
            self:markSymbolOfAliasDeclarationIfTypeOnly(checker.getAliasDeclarationFromName(name), nil)
        end
        -- We know a symbol with the given meaning exists along the alias chain, so resolve until we find it.
        while symbol.flags & meaning == 0 and not dontResolveAlias and symbol.flags & SymbolFlags.Alias ~= 0 do
            symbol = self:resolveAlias(symbol)
        end
    end
    return symbol
end

function Checker:resolveQualifiedName(name, left, right, meaning, ignoreErrors, location)
    local namespace = self:resolveEntityName(left, SymbolFlags.Namespace, ignoreErrors, false --[[dontResolveAlias]], location)
    if namespace == nil or ast.NodeIsMissing(right) then
        return nil
    end
    if namespace == self.unknownSymbol then
        return namespace
    end
    if namespace.valueDeclaration ~= nil and
        ast.IsInJSFile(namespace.valueDeclaration) and
        self.compilerOptions:GetModuleResolutionKind() ~= core.ModuleResolutionKind.Bundler and
        ast.IsVariableDeclaration(namespace.valueDeclaration) and
        namespace.valueDeclaration:Initializer() ~= nil and
        self:isCommonJSRequire(namespace.valueDeclaration:Initializer()) then
        local moduleName = namespace.valueDeclaration:Initializer():Arguments()[1]
        local moduleSym = self:resolveExternalModuleName(moduleName, moduleName, false --[[ignoreErrors]])
        if moduleSym ~= nil then
            local resolvedModuleSymbol = self:resolveExternalModuleSymbol(moduleSym, false --[[dontResolveAlias]])
            if resolvedModuleSymbol ~= nil then
                namespace = resolvedModuleSymbol
            end
        end
    end
    local text = right:Text()
    local symbol = self:getMergedSymbol(self:getSymbol(self:getExportsOfSymbol(namespace), text, meaning))
    if symbol == nil and namespace.flags & SymbolFlags.Alias ~= 0 then
        -- `namespace` can be resolved further if there was a symbol merge with a re-export
        symbol = self:getMergedSymbol(self:getSymbol(self:getExportsOfSymbol(self:resolveAlias(namespace)), text, meaning))
    end
    if symbol == nil then
        if not ignoreErrors then
            local namespaceName = self:getFullyQualifiedName(namespace, nil --[[containingLocation]])
            local declarationName = scanner.DeclarationNameToString(right)
            local suggestionForNonexistentModule = self:getSuggestedSymbolForNonexistentModule(right, namespace)
            if suggestionForNonexistentModule ~= nil then
                self:error(right, diagnostics.X_0_has_no_exported_member_named_1_Did_you_mean_2, namespaceName, declarationName, self:symbolToString(suggestionForNonexistentModule))
                return nil
            end
            local containingQualifiedName
            if ast.IsQualifiedName(name) then
                containingQualifiedName = checker.getContainingQualifiedNameNode(name)
            end
            local canSuggestTypeof = self.globalObjectType ~= nil and meaning & SymbolFlags.Type ~= 0 and containingQualifiedName ~= nil and not ast.IsTypeOfExpression(containingQualifiedName.parent) and self:tryGetQualifiedNameAsValue(containingQualifiedName) ~= nil
            if canSuggestTypeof then
                self:error(containingQualifiedName, diagnostics.X_0_refers_to_a_value_but_is_being_used_as_a_type_here_Did_you_mean_typeof_0, checker.entityNameToString(containingQualifiedName))
                return nil
            end
            if meaning & SymbolFlags.Namespace ~= 0 then
                if ast.IsQualifiedName(name.parent) then
                    local exportedTypeSymbol = self:getMergedSymbol(self:getSymbol(self:getExportsOfSymbol(namespace), text, SymbolFlags.Type))
                    if exportedTypeSymbol ~= nil then
                        local qualified = name.parent:AsQualifiedName()
                        self:error(qualified.right, diagnostics.Cannot_access_0_1_because_0_is_a_type_but_not_a_namespace_Did_you_mean_to_retrieve_the_type_of_the_property_1_in_0_with_0_1, self:symbolToString(exportedTypeSymbol), qualified.right:Text())
                        return nil
                    end
                end
            end
            self:error(right, diagnostics.Namespace_0_has_no_exported_member_1, namespaceName, declarationName)
        end
    end
    return symbol
end

function Checker:tryGetQualifiedNameAsValue(node)
    local id = ast.GetFirstIdentifier(node)
    local symbol = self.resolveName(id, id:Text(), SymbolFlags.Value, nil --[[nameNotFoundMessage]], true --[[isUse]], false --[[excludeGlobals]])
    if symbol == nil then
        return nil
    end
    local n = id
    while ast.IsQualifiedName(n.parent) do
        local t = self:getTypeOfSymbol(symbol)
        symbol = self:getPropertyOfType(t, n.parent:AsQualifiedName().right:Text())
        if symbol == nil then
            return nil
        end
        n = n.parent
    end
    return symbol
end

function Checker:getSuggestedSymbolForNonexistentModule(name, targetModule)
    -- Go: maps.Values(...), materialized as an array.
    local candidates = {}
    for _, s in pairs(self:getExportsOfModule(targetModule) or {}) do
        candidates[#candidates + 1] = s
    end
    return self:getSpellingSuggestionForName(name:Text(), candidates, SymbolFlags.ModuleMember)
end

function Checker:getFullyQualifiedName(symbol, containingLocation)
    if symbol.parent ~= nil then
        return self:getFullyQualifiedName(symbol.parent, containingLocation) .. "." .. self:symbolToString(symbol)
    end
    return self:symbolToStringEx(symbol, containingLocation, SymbolFlags.All, checker.SymbolFormatFlags.DoNotIncludeSymbolChain | checker.SymbolFormatFlags.AllowAnyNodeKind)
end

function Checker:getExportsOfSymbol(symbol)
    if symbol.flags & SymbolFlags.LateBindingContainer ~= 0 then
        return self:getResolvedMembersOrExportsOfSymbol(symbol, MembersOrExportsResolutionKind.ResolvedExports)
    end
    if symbol.flags & SymbolFlags.Module ~= 0 then
        return self:getExportsOfModule(symbol)
    end
    return symbol.exports
end

function Checker:getResolvedMembersOrExportsOfSymbol(symbol, resolutionKind)
    local links = self.membersAndExportsLinks:Get(symbol)
    if links[resolutionKind + 1] == nil then
        local isStatic = resolutionKind == MembersOrExportsResolutionKind.ResolvedExports
        local earlySymbols = symbol.exports
        if not isStatic then
            earlySymbols = symbol.members
        elseif symbol.flags & SymbolFlags.Module ~= 0 then
            earlySymbols = self:getExportsOfModuleWorker(symbol)
        end
        links[resolutionKind + 1] = earlySymbols
        -- fill in any as-yet-unresolved late-bound members.
        local lateSymbols
        for _, decl in ipairs(symbol.declarations or {}) do
            for _, member in ipairs(checker.getMembersOfDeclaration(decl) or {}) do
                if isStatic == ast.HasStaticModifier(member) then
                    if self:hasLateBindableName(member) then
                        if lateSymbols == nil then
                            lateSymbols = {}
                        end
                        self:lateBindMember(symbol, earlySymbols, lateSymbols, member)
                    elseif self:hasLateBindableIndexSignature(member) then
                        if lateSymbols == nil then
                            lateSymbols = {}
                        end
                        self:lateBindIndexSignature(symbol, earlySymbols, lateSymbols, member --[[ as LateBoundDeclaration | LateBoundBinaryExpressionDeclaration ]])
                    end
                end
            end
        end
        if isStatic then
            local assignmentSymbol = mapGet(symbol.exports, ast.InternalSymbolNameAssignmentDeclaration)
            if assignmentSymbol ~= nil then
                for _, member in ipairs(assignmentSymbol.declarations or {}) do
                    if self:hasLateBindableName(member) then
                        if lateSymbols == nil then
                            lateSymbols = {}
                        end
                        self:lateBindMember(symbol, earlySymbols, lateSymbols, member)
                    end
                end
            end
        end
        links[resolutionKind + 1] = self:combineSymbolTables(earlySymbols, lateSymbols)
    end
    return links[resolutionKind + 1]
end

-- Performs late-binding of a dynamic member. This performs the same function for
-- late-bound members that `declareSymbol` in binder.ts performs for early-bound
-- members.
--
-- If a symbol is a dynamic name from a computed property, we perform an additional "late"
-- binding phase to attempt to resolve the name for the symbol from the type of the computed
-- property's expression. If the type of the expression is a string-literal, numeric-literal,
-- or unique symbol type, we can use that type as the name of the symbol.
--
-- For example, given:
--
--	const x = Symbol();
--
--	interface I {
--	  [x]: number;
--	}
--
-- The binder gives the property `[x]: number` a special symbol with the name "__computed".
-- In the late-binding phase we can type-check the expression `x` and see that it has a
-- unique symbol type which we can then use as the name of the member. This allows users
-- to define custom symbols that can be used in the members of an object type.
--
-- @param parent The containing symbol for the member.
-- @param earlySymbols The early-bound symbols of the parent.
-- @param lateSymbols The late-bound symbols of the parent.
-- @param decl The member to bind.
function Checker:lateBindMember(parent, earlySymbols, lateSymbols, decl)
    debug.Assert(decl:Symbol() ~= nil, "The member is expected to have a symbol.")
    local links = self.symbolNodeLinks:Get(decl)
    if links.resolvedSymbol == nil then
        -- In the event we attempt to resolve the late-bound name of this member recursively,
        -- fall back to the early-bound name of this member.
        links.resolvedSymbol = decl:Symbol()
        local declName
        if ast.IsBinaryExpression(decl) then
            declName = decl:AsBinaryExpression().left
        else
            declName = decl:Name()
        end
        local t
        if ast.IsElementAccessExpression(declName) then
            t = self:checkExpressionCached(declName:AsElementAccessExpression().argumentExpression)
        else
            t = self:checkComputedPropertyName(declName)
        end
        if checker.isTypeUsableAsPropertyName(t) then
            local memberName = checker.getPropertyNameFromType(t)
            local symbolFlags = decl:Symbol().flags
            -- Get or add a late-bound symbol for the member. This allows us to merge late-bound accessor declarations.
            local lateSymbol = lateSymbols[memberName]
            if lateSymbol == nil then
                lateSymbol = self:newSymbolEx(SymbolFlags.None, memberName, CheckFlags.Late)
                lateSymbols[memberName] = lateSymbol
            end
            -- Report an error if there's a symbol declaration with the same name and conflicting flags.
            local earlySymbol = mapGet(earlySymbols, memberName)
            if lateSymbol.flags & checker.getExcludedSymbolFlags(symbolFlags) ~= 0 then
                -- If we have an existing early-bound member, combine its declarations so that we can
                -- report an error at each declaration.
                local declarations
                if earlySymbol ~= nil then
                    declarations = core.Concatenate(earlySymbol.declarations, lateSymbol.declarations)
                else
                    declarations = lateSymbol.declarations
                end
                local name = memberName
                if t.flags & TypeFlags.UniqueESSymbol ~= 0 then
                    name = scanner.DeclarationNameToString(declName)
                end
                for _, d in ipairs(declarations or {}) do
                    self:error(core.OrElse(ast.GetNameOfDeclaration(d), d), diagnostics.Duplicate_identifier_0, name)
                end
                self:error(core.OrElse(declName, decl), diagnostics.Duplicate_identifier_0, name)
                if lateSymbol.flags & SymbolFlags.Accessor ~= 0 and lateSymbol.flags & SymbolFlags.Accessor ~= symbolFlags & SymbolFlags.Accessor then
                    lateSymbol.flags = lateSymbol.flags | SymbolFlags.Accessor
                end
                lateSymbol = self:newSymbolEx(SymbolFlags.None, memberName, CheckFlags.Late)
            end
            self.valueSymbolLinks:Get(lateSymbol).nameType = t
            self:addDeclarationToLateBoundSymbol(lateSymbol, decl, symbolFlags)
            if lateSymbol.parent == nil then
                lateSymbol.parent = parent
            end
            links.resolvedSymbol = lateSymbol
        end
    end
    return links.resolvedSymbol
end

function Checker:lateBindIndexSignature(parent, earlySymbols, lateSymbols, decl) -- luacheck: ignore parent
    -- First, late bind the index symbol itself, if needed
    local indexSymbol = lateSymbols[ast.InternalSymbolNameIndex]
    if indexSymbol == nil then
        local early = mapGet(earlySymbols, ast.InternalSymbolNameIndex)
        if early == nil then
            indexSymbol = self:newSymbolEx(SymbolFlags.None, ast.InternalSymbolNameIndex, CheckFlags.Late)
        else
            indexSymbol = self:cloneSymbol(early)
            indexSymbol.checkFlags = indexSymbol.checkFlags | CheckFlags.Late
        end
        lateSymbols[ast.InternalSymbolNameIndex] = indexSymbol
    end
    -- Then just add the computed name as a late bound declaration
    -- (note: unlike `addDeclarationToLateBoundSymbol` we do not set up a `.lateSymbol` on `decl`'s links,
    -- since that would point at an index symbol and not a single property symbol, like most consumers would expect)
    if core.Len(indexSymbol.declarations) == 0 or decl:Symbol().flags & SymbolFlags.ReplaceableByMethod == 0 then
        indexSymbol.declarations = core.Append(indexSymbol.declarations, decl)
    end
end

function checker.isNotReplacableByMethod(decl)
    return decl:Symbol().flags & SymbolFlags.ReplaceableByMethod == 0
end

-- Adds a declaration to a late-bound dynamic member. This performs the same function for
-- late-bound members that `addDeclarationToSymbol` in binder.ts performs for early-bound
-- members.
function Checker:addDeclarationToLateBoundSymbol(symbol, member, symbolFlags)
    debug.Assert(symbol.checkFlags & CheckFlags.Late ~= 0, "Expected a late-bound symbol.")
    self.lateBoundLinks:Get(member:Symbol()).lateSymbol = symbol
    if core.Len(symbol.declarations) == 0 or member:Symbol().flags & SymbolFlags.ReplaceableByMethod == 0 then
        symbol.flags = symbol.flags | symbolFlags
        symbol.declarations = core.Append(symbol.declarations, member)
    elseif symbol.flags & SymbolFlags.ReplaceableByMethod ~= 0 and member:Symbol().flags & SymbolFlags.Method ~= 0 then
        -- Remove all replacable-by-method members, along with their flags.
        symbol.declarations = core.Append(core.Filter(symbol.declarations, checker.isNotReplacableByMethod), member)
        local oldFlags = symbol.flags
        symbol.flags = SymbolFlags.None
        for _, d in ipairs(symbol.declarations) do
            symbol.flags = symbol.flags | d:Symbol().flags
        end
        if oldFlags & SymbolFlags.Accessor ~= 0 then
            symbol.flags = symbol.flags | SymbolFlags.Accessor
        end
    end
    if symbolFlags & SymbolFlags.Value ~= 0 then
        binder.SetValueDeclaration(symbol, member)
    end
end

--[[
 * Gets a SymbolTable containing both the early- and late-bound members of a symbol.
 *
 * For a description of late-binding, see `lateBindMember`.
]]
function Checker:getMembersOfSymbol(symbol)
    if symbol.flags & SymbolFlags.LateBindingContainer ~= 0 then
        return self:getResolvedMembersOrExportsOfSymbol(symbol, MembersOrExportsResolutionKind.ResolvedMembers)
    end
    return symbol.members
end

function Checker:getExportsOfModule(moduleSymbol)
    local links = self.moduleSymbolLinks:Get(moduleSymbol)
    if links.resolvedExports == nil then
        local exports, typeOnlyExportStarMap = self:getExportsOfModuleWorker(moduleSymbol)
        links.resolvedExports = exports
        links.typeOnlyExportStarMap = typeOnlyExportStarMap
    end
    return links.resolvedExports
end

checker.defineStruct("ExportCollision", nil, { specifierText = "" })

-- ExportCollisionTable = map[string]*ExportCollision

function Checker:getExportsOfModuleWorker(moduleSymbol)
    local exports
    local typeOnlyExportStarMap
    local visitedSymbols = {}
    local nonTypeOnlyNames = collections.NewSetWithSizeHint(0)
    -- The ES6 spec permits export * declarations in a module to circularly reference the module itself. For example,
    -- module 'a' can 'export * from "b"' and 'b' can 'export * from "a"' without error.
    local visit
    visit = function(symbol, exportStar, isTypeOnly)
        if not isTypeOnly and symbol ~= nil then
            -- Add non-type-only names before checking if we've visited this module,
            -- because we might have visited it via an 'export type *', and visiting
            -- again with 'export *' will override the type-onlyness of its exports.
            for name in pairs(symbol.exports or {}) do
                nonTypeOnlyNames:Add(name)
            end
        end
        if symbol == nil or symbol.exports == nil or core.Some(visitedSymbols, function(s)
            return s == symbol
        end) then
            return nil
        end
        visitedSymbols[#visitedSymbols + 1] = symbol
        local symbols = cloneMap(symbol.exports)
        -- All export * declarations are collected in an __export symbol by the binder
        local exportStars = symbol.exports[ast.InternalSymbolNameExportStar]
        if exportStars ~= nil then
            local nestedSymbols = {}
            local lookupTable = {}
            for _, node in ipairs(exportStars.declarations or {}) do
                local resolvedModule = self:resolveExternalModuleName(node, node:ModuleSpecifier(), false --[[ignoreErrors]])
                local exportedSymbols = visit(resolvedModule, node, isTypeOnly or node:IsTypeOnly())
                self:extendExportSymbols(nestedSymbols, exportedSymbols, lookupTable, node)
            end
            for id, s in pairs(lookupTable) do
                -- It's not an error if the file with multiple `export *`s with duplicate names exports a member with that name itself
                if not (id == ast.InternalSymbolNameExportEquals or core.Len(s.exportsWithDuplicate) == 0 or symbols[id] ~= nil) then
                    for _, node in ipairs(s.exportsWithDuplicate) do
                        self:addDiagnostic(checker.createDiagnosticForNode(node, diagnostics.Module_0_has_already_exported_a_member_named_1_Consider_explicitly_re_exporting_to_resolve_the_ambiguity, s.specifierText, id))
                    end
                end
            end
            self:extendExportSymbols(symbols, nestedSymbols, nil, nil)
        end
        if exportStar ~= nil and exportStar:IsTypeOnly() then
            if typeOnlyExportStarMap == nil then
                typeOnlyExportStarMap = {}
            end
            for name in pairs(symbols) do
                typeOnlyExportStarMap[name] = exportStar
            end
        end
        return symbols
    end
    local originalModule
    if moduleSymbol ~= nil then
        if self:resolveSymbolEx(mapGet(moduleSymbol.exports, ast.InternalSymbolNameExportEquals), false --[[dontResolveAlias]]) ~= nil then
            originalModule = moduleSymbol
        end
    end
    -- A module defined by an 'export=' consists of one export that needs to be resolved
    moduleSymbol = self:resolveExternalModuleSymbol(moduleSymbol, false --[[dontResolveAlias]])
    exports = visit(moduleSymbol, nil, false)
    if exports == nil then
        exports = {}
    end
    -- A CommonJS module defined by an 'export=' might also export typedefs, stored on the original module
    if originalModule ~= nil and mapLen(originalModule.exports) > 1 then
        for _, symbol in pairs(originalModule.exports) do
            if not (symbol.name == ast.InternalSymbolNameExportEquals or symbol.name == ast.InternalSymbolNameExportStar) then
                local flags = self:getSymbolFlags(symbol)
                if flags & (SymbolFlags.Type | SymbolFlags.Namespace) ~= 0 and
                    flags & SymbolFlags.Value == 0 and
                    exports[symbol.name] == nil then
                    exports[symbol.name] = symbol
                end
            end
        end
    end
    if typeOnlyExportStarMap ~= nil then
        for name in pairs(nonTypeOnlyNames:Keys() or {}) do
            typeOnlyExportStarMap[name] = nil
        end
    end
    return exports, typeOnlyExportStarMap
end

--[[
 * Extends one symbol table with another while collecting information on name collisions for error message generation into the `lookupTable` argument
 * Not passing `lookupTable` and `exportNode` disables this collection, and just extends the tables
]]
function Checker:extendExportSymbols(target, source, lookupTable, exportNode)
    for id, sourceSymbol in pairs(source or {}) do
        if id ~= ast.InternalSymbolNameDefault then
            local targetSymbol = target[id]
            if targetSymbol == nil then
                target[id] = sourceSymbol
                if lookupTable ~= nil and exportNode ~= nil then
                    lookupTable[id] = checker.ExportCollision_new({
                        specifierText = scanner.GetTextOfNode(exportNode:ModuleSpecifier()),
                    })
                end
            elseif lookupTable ~= nil and exportNode ~= nil and self:resolveSymbol(targetSymbol) ~= self:resolveSymbol(sourceSymbol) then
                local s = lookupTable[id]
                s.exportsWithDuplicate = core.Append(s.exportsWithDuplicate, exportNode)
            end
        end
    end
end

function Checker:ResolveAlias(symbol)
    if symbol == nil then
        return nil, false
    end
    local resolved = self:resolveAlias(symbol)
    return resolved, resolved ~= self.unknownSymbol
end

-- Resolve an alias symbol to the first target symbol in the resolution chain that includes some other
-- meaning. Pure aliases are eagerly resolved and any type-only markers are back-propagated to the original
-- symbol. The function panics if the argument is not a symbol with an alias meaning.
function Checker:resolveAlias(symbol)
    if symbol.flags & SymbolFlags.Alias == 0 then
        error("Should only get alias here", 0)
    end
    local links = self.aliasSymbolLinks:Get(symbol)
    if links.aliasTarget == nil then
        if not self:pushTypeResolution(symbol, TypeSystemPropertyName.AliasTarget) then
            return self.unknownSymbol
        end
        local node = self:getDeclarationOfAliasSymbol(symbol)
        if node == nil then
            error("Unexpected nil in resolveAlias for symbol: " .. self:symbolToString(symbol), 0)
        end
        local target = self:getTargetOfAliasDeclaration(node)
        if ast.IsNonLocalAlias(target, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace) then
            -- When the target is a pure alias, we transitively resolve and propagate any typeOnlyDeclaration
            target = self:resolveIndirectionAlias(symbol, target)
        end
        links.aliasTarget = core.OrElse(target, self.unknownSymbol)
        if not self:popTypeResolution() then
            self:error(node, diagnostics.Circular_definition_of_import_alias_0, self:symbolToString(symbol))
            links.aliasTarget = self.unknownSymbol
        end
    end
    return links.aliasTarget
end

function Checker:resolveIndirectionAlias(source, target)
    local result = self:getMergedSymbol(self:resolveAlias(target))
    local targetLinks = self.aliasSymbolLinks:Get(target)
    if targetLinks.typeOnlyDeclaration ~= nil then
        local sourceLinks = self.aliasSymbolLinks:Get(source)
        if sourceLinks.typeOnlyDeclaration == nil then
            sourceLinks.typeOnlyDeclaration = targetLinks.typeOnlyDeclaration
        end
    end
    return result
end

function Checker:tryResolveAlias(symbol)
    local links = self.aliasSymbolLinks:Get(symbol)
    if links.aliasTarget ~= nil or self:findResolutionCycleStartIndex(symbol, TypeSystemPropertyName.AliasTarget) < 0 then
        return self:resolveAlias(symbol)
    end
    return nil
end

function Checker:resolveAliasWithDeprecationCheck(symbol, location)
    if symbol.flags & SymbolFlags.Alias == 0 or self:isDeprecatedSymbol(symbol) or self:getDeclarationOfAliasSymbol(symbol) == nil then
        return symbol
    end
    local targetSymbol = self:resolveAlias(symbol)
    if targetSymbol == self.unknownSymbol then
        return targetSymbol
    end
    while symbol.flags & SymbolFlags.Alias ~= 0 do
        local target = self:getImmediateAliasedSymbol(symbol)
        if target ~= nil then
            if target == targetSymbol then
                break
            end
            if core.Len(target.declarations) ~= 0 then
                if self:isDeprecatedSymbol(target) then
                    self:addDeprecatedSuggestion(location, target.declarations, target.name)
                    break
                else
                    if symbol == targetSymbol then
                        break
                    end
                    symbol = target
                end
            end
        else
            break
        end
    end
    return targetSymbol
end

--[[
 * Gets combined flags of a `symbol` and all alias targets it resolves to. `resolveAlias`
 * is typically recursive over chains of aliases, but stops mid-chain if an alias is merged
 * with another exported symbol, e.g.
 * ```ts
 * // a.ts
 * export const a = 0;
 * // b.ts
 * export { a } from "./a";
 * export type a = number;
 * // c.ts
 * import { a } from "./b";
 * ```
 * Calling `resolveAlias` on the `a` in c.ts would stop at the merged symbol exported
 * from b.ts, even though there is still more alias to resolve. Consequently, if we were
 * trying to determine if the `a` in c.ts has a value meaning, looking at the flags on
 * the local symbol and on the symbol returned by `resolveAlias` is not enough.
 * @returns SymbolFlags.All if `symbol` is an alias that ultimately resolves to `unknown`;
 * combined flags of all alias targets otherwise.
]]
function Checker:getSymbolFlags(symbol)
    return self:getSymbolFlagsEx(symbol, false --[[excludeTypeOnlyMeanings]], false --[[excludeLocalMeanings]])
end

function Checker:getSymbolFlagsEx(symbol, excludeTypeOnlyMeanings, excludeLocalMeanings)
    local seenSymbols = collections.NewSet()
    local flags = 0
    if not excludeLocalMeanings then
        flags = symbol.flags
    end
    while symbol.flags & SymbolFlags.Alias ~= 0 do
        if excludeTypeOnlyMeanings and self:getTypeOnlyAliasDeclaration(symbol) ~= nil then
            break
        end
        local target = self:getExportSymbolOfValueSymbolIfExported(self:resolveAlias(symbol))
        if target == self.unknownSymbol then
            return SymbolFlags.All
        end
        if target.flags & SymbolFlags.Alias ~= 0 then
            -- Optimization - try to avoid creating or adding to `seenSymbols` if possible
            if target == symbol or seenSymbols:Has(target) then
                break
            end
            if seenSymbols:Len() == 0 then
                seenSymbols:Add(symbol)
            end
            seenSymbols:Add(target)
        end
        flags = flags | target.flags
        symbol = target
    end
    return flags
end

function Checker:getDeclarationOfAliasSymbol(symbol)
    return core.FindLast(symbol.declarations, ast.IsAliasSymbolDeclaration)
end

function Checker:getTypeOfSymbolWithDeferredType(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        local deferred = self.deferredSymbolLinks:Get(symbol)
        if deferred.parent.flags & TypeFlags.Union ~= 0 then
            links.resolvedType = self:getUnionType(deferred.constituents)
        else
            links.resolvedType = self:getIntersectionType(deferred.constituents)
        end
    end
    return links.resolvedType
end

function Checker:getWriteTypeOfSymbolWithDeferredType(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.writeType == nil then
        local deferred = self.deferredSymbolLinks:Get(symbol)
        if core.Len(deferred.writeConstituents) ~= 0 then
            if deferred.parent.flags & TypeFlags.Union ~= 0 then
                links.writeType = self:getUnionType(deferred.writeConstituents)
            else
                links.writeType = self:getIntersectionType(deferred.writeConstituents)
            end
        else
            links.writeType = self:getTypeOfSymbolWithDeferredType(symbol)
        end
    end
    return links.writeType
end

-- Distinct write types come only from set accessors, but synthetic union and intersection
-- properties deriving from set accessors will either pre-compute or defer the union or
-- intersection of the writeTypes of their constituents.
function Checker:getWriteTypeOfSymbol(symbol)
    if symbol.checkFlags & CheckFlags.SyntheticProperty ~= 0 then
        if symbol.checkFlags & CheckFlags.DeferredType ~= 0 then
            return self:getWriteTypeOfSymbolWithDeferredType(symbol)
        end
        local links = self.valueSymbolLinks:Get(symbol)
        return core.OrElse(links.writeType, links.resolvedType)
    end
    if symbol.flags & SymbolFlags.Property ~= 0 then
        return self:removeMissingType(self:getTypeOfSymbol(symbol), symbol.flags & SymbolFlags.Optional ~= 0)
    end
    if symbol.flags & SymbolFlags.Accessor ~= 0 then
        if symbol.checkFlags & CheckFlags.Instantiated ~= 0 then
            return self:getWriteTypeOfInstantiatedSymbol(symbol)
        end
        return self:getWriteTypeOfAccessors(symbol)
    end
    return self:getTypeOfSymbol(symbol)
end

function Checker:GetTypeOfSymbolAtLocation(symbol, location)
    symbol = self:getExportSymbolOfValueSymbolIfExported(symbol)
    if location ~= nil then
        -- If we have an identifier or a property access at the given location, if the location is
        -- an dotted name expression, and if the location is not an assignment target, obtain the type
        -- of the expression (which will reflect control flow analysis). If the expression indeed
        -- resolved to the given symbol, return the narrowed type.
        if (ast.IsIdentifier(location) or ast.IsPrivateIdentifier(location)) and
            not (ast.IsJsxTagName(location) or ast.IsJsxAttribute(location.parent) or ast.IsJsxNamespacedName(location.parent)) then
            if ast.IsRightSideOfQualifiedNameOrPropertyAccess(location) then
                location = location.parent
            end
            if ast.IsExpressionNode(location) and (not ast.IsAssignmentTarget(location) or ast.IsWriteAccess(location)) then
                local t
                if ast.IsWriteAccess(location) and location.kind == Kind.PropertyAccessExpression then
                    t = self:checkPropertyAccessExpression(location, CheckMode.Normal, true --[[writeOnly]])
                else
                    t = self:getTypeOfExpression(location)
                end
                if self:getExportSymbolOfValueSymbolIfExported(self.symbolNodeLinks:Get(location).resolvedSymbol) == symbol then
                    return self:removeOptionalTypeMarker(t)
                end
            end
        end
        if ast.IsDeclarationName(location) and ast.IsSetAccessorDeclaration(location.parent) and self:getAnnotatedAccessorTypeNode(location.parent) ~= nil then
            return self:getWriteTypeOfAccessors(location.parent:Symbol())
        end
        -- The location isn't a reference to the given symbol, meaning we're being asked
        -- a hypothetical question of what type the symbol would have if there was a reference
        -- to it at the given location. Since we have no control flow information for the
        -- hypothetical reference (control flow information is created and attached by the
        -- binder), we simply return the declared type of the symbol.
        if checker.isRightSideOfAccessExpression(location) and ast.IsWriteAccess(location.parent) then
            return self:getWriteTypeOfSymbol(symbol)
        end
    end
    return self:getNonMissingTypeOfSymbol(symbol)
end

function Checker:getTypeOfSymbol(symbol)
    if symbol.checkFlags & CheckFlags.DeferredType ~= 0 then
        return self:getTypeOfSymbolWithDeferredType(symbol)
    end
    if symbol.checkFlags & CheckFlags.Instantiated ~= 0 then
        return self:getTypeOfInstantiatedSymbol(symbol)
    end
    if symbol.checkFlags & CheckFlags.Mapped ~= 0 then
        return self:getTypeOfMappedSymbol(symbol)
    end
    if symbol.checkFlags & CheckFlags.ReverseMapped ~= 0 then
        return self:getTypeOfReverseMappedSymbol(symbol)
    end
    if symbol.flags & SymbolFlags.Accessor ~= 0 then
        return self:getTypeOfAccessors(symbol)
    end
    if symbol.flags & (SymbolFlags.Variable | SymbolFlags.Property) ~= 0 then
        return self:getTypeOfVariableOrParameterOrProperty(symbol)
    end
    if symbol.flags & (SymbolFlags.Function | SymbolFlags.Method | SymbolFlags.Class | SymbolFlags.Enum | SymbolFlags.ValueModule) ~= 0 then
        return self:getTypeOfFuncClassEnumModule(symbol)
    end
    if symbol.flags & SymbolFlags.EnumMember ~= 0 then
        return self:getTypeOfEnumMember(symbol)
    end
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        return self:getTypeOfAlias(symbol)
    end
    return self.errorType
end

function Checker:getNonMissingTypeOfSymbol(symbol)
    return self:removeMissingType(self:getTypeOfSymbol(symbol), symbol.flags & SymbolFlags.Optional ~= 0)
end

function Checker:getTypeOfInstantiatedSymbol(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        links.resolvedType = self:instantiateType(self:getTypeOfSymbol(links.target), links.mapper)
    end
    return links.resolvedType
end

function Checker:getWriteTypeOfInstantiatedSymbol(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.writeType == nil then
        links.writeType = self:instantiateType(self:getWriteTypeOfSymbol(links.target), links.mapper)
    end
    return links.writeType
end

function Checker:getTypeOfVariableOrParameterOrProperty(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        local t = self:getTypeOfVariableOrParameterOrPropertyWorker(symbol)
        if t == nil then
            error("Unexpected nil type", 0)
        end
        -- For a contextually typed parameter it is possible that a type has already
        -- been assigned (in assignTypeToParameterAndFixTypeParameters), and we want
        -- to preserve this type. In fact, we need to _prefer_ that type, but it won't
        -- be assigned until contextual typing is complete, so we need to defer in
        -- cases where contextual typing may take place.
        if links.resolvedType == nil and not self:isParameterOfContextSensitiveSignature(symbol) then
            links.resolvedType = t
        end
        return t
    end
    return links.resolvedType
end

function Checker:isParameterOfContextSensitiveSignature(symbol)
    local decl = symbol.valueDeclaration
    if decl == nil then
        return false
    end
    if ast.IsBindingElement(decl) then
        decl = ast.WalkUpBindingElementsAndPatterns(decl)
    end
    if ast.IsParameterDeclaration(decl) then
        return self:isContextSensitiveFunctionOrObjectLiteralMethod(decl.parent)
    end
    return false
end

function Checker:getTypeOfVariableOrParameterOrPropertyWorker(symbol)
    -- Handle prototype property
    if symbol.flags & SymbolFlags.Prototype ~= 0 then
        return self:getTypeOfPrototypeProperty(symbol)
    end
    -- CommonsJS require and module both have type any.
    if symbol == self.requireSymbol then
        return self.anyType
    end
    debug.Assert(symbol.valueDeclaration ~= nil)
    local declaration = symbol.valueDeclaration
    if ast.IsSourceFile(declaration) and ast.IsJsonSourceFile(declaration:AsSourceFile()) then
        local statements = declaration:Statements()
        if core.Len(statements) == 0 then
            return self.emptyObjectType
        end
        return self:getWidenedType(self:getWidenedLiteralType(self:checkExpression(statements[1]:Expression())))
    end
    -- Handle variable, parameter or property
    if not self:pushTypeResolution(symbol, TypeSystemPropertyName.Type) then
        return self:reportCircularityError(symbol)
    end
    if symbol.flags & SymbolFlags.ModuleExports ~= 0 then
        if symbol.name == "exports" then
            return self:getTypeOfSymbol(self:resolveExternalModuleSymbol(symbol.valueDeclaration:Symbol(), false --[[dontResolveAlias]]))
        end
        return self:newAnonymousType(symbol, symbol.members, nil, nil, nil)
    end
    local result
    local kind = declaration.kind
    if kind == Kind.Parameter or kind == Kind.PropertyDeclaration or kind == Kind.PropertySignature or kind == Kind.VariableDeclaration or
        kind == Kind.BindingElement then
        result = self:getWidenedTypeForVariableLikeDeclaration(declaration, not self:isParameterOfContextSensitiveSignature(symbol)) -- only report diagnostics for context-insensitive parameters - context-sensitive ones may have their type fixed to something else
    elseif kind == Kind.PropertyAssignment then
        result = self:checkPropertyAssignment(declaration, CheckMode.Normal)
    elseif kind == Kind.ShorthandPropertyAssignment then
        result = self:checkShorthandPropertyAssignment(declaration, true --[[inDestructuringPattern]], CheckMode.Normal)
    elseif kind == Kind.MethodDeclaration then
        result = self:checkObjectLiteralMethod(declaration, CheckMode.Normal)
    elseif kind == Kind.ExportAssignment then
        if declaration:Type() ~= nil then
            result = self:getTypeFromTypeNode(declaration:Type())
        else
            result = self:widenTypeForVariableLikeDeclaration(self:checkExpressionCached(declaration:Expression()), declaration, false --[[reportErrors]])
        end
    elseif kind == Kind.BinaryExpression or kind == Kind.CallExpression then
        result = self:getWidenedTypeForAssignmentDeclaration(symbol)
    elseif kind == Kind.JsxAttribute then
        result = self:checkJsxAttribute(declaration, CheckMode.Normal)
    elseif kind == Kind.EnumMember then
        result = self:getTypeOfEnumMember(symbol)
    else
        error("Unhandled case in getTypeOfVariableOrParameterOrPropertyWorker: " .. ast.Kind_String(declaration.kind), 0)
    end
    if not self:popTypeResolution() then
        return self:reportCircularityError(symbol)
    end
    return result
end

-- Return the type associated with a variable, parameter, or property declaration. In the simple case this is the type
-- specified in a type annotation or inferred from an initializer. However, in the case of a destructuring declaration it
-- is a bit more involved. For example:
--
--	var [x, s = ""] = [1, "one"];
--
-- Here, the array literal [1, "one"] is contextually typed by the type [any, string], which is the implied type of the
-- binding pattern [x, s = ""]. Because the contextual type is a tuple type, the resulting type of [1, "one"] is the
-- tuple type [number, string]. Thus, the type inferred for 'x' is number and the type inferred for 's' is string.
function Checker:getWidenedTypeForVariableLikeDeclaration(declaration, reportErrors)
    return self:widenTypeForVariableLikeDeclaration(self:getTypeForVariableLikeDeclaration(declaration --[[includeOptionality]], true, CheckMode.Normal), declaration, reportErrors)
end

-- Return the inferred type for a variable, parameter, or property declaration
function Checker:getTypeForVariableLikeDeclaration(declaration, includeOptionality, checkMode)
    -- A variable declared in a for..in statement is of type string, or of type keyof T when the
    -- right hand expression is of a type parameter type.
    if ast.IsVariableDeclaration(declaration) then
        local grandParent = declaration.parent.parent
        if grandParent.kind == Kind.ForInStatement then
            local indexType = self:getIndexType(self:getNonNullableTypeIfNeeded(self:checkExpressionEx(grandParent:Expression(), checkMode --[[checkMode]])))
            if indexType.flags & (TypeFlags.TypeParameter | TypeFlags.Index) ~= 0 then
                return self:getExtractStringType(indexType)
            end
            return self.stringType
        elseif grandParent.kind == Kind.ForOfStatement then
            -- checkRightHandSideOfForOf will return undefined if the for-of expression type was
            -- missing properties/signatures required to get its iteratedType (like
            -- [Symbol.iterator] or next). This may be because we accessed properties from anyType,
            -- or it may have led to an error inside getElementTypeOfIterable.
            return self:checkRightHandSideOfForOf(grandParent)
        end
    elseif ast.IsBindingElement(declaration) then
        return self:getTypeForBindingElement(declaration)
    end
    local isProperty = ast.IsPropertyDeclaration(declaration) and not ast.HasAccessorModifier(declaration) or ast.IsPropertySignatureDeclaration(declaration)
    local isOptional = includeOptionality and checker.isOptionalDeclaration(declaration)
    -- Use type from type annotation if one is present
    local declaredType = self:tryGetTypeFromTypeNode(declaration)
    if ast.IsCatchClauseVariableDeclarationOrBindingElement(declaration) then
        if declaredType ~= nil then
            -- If the catch clause is explicitly annotated with any or unknown, accept it, otherwise error.
            if declaredType.flags & TypeFlags.AnyOrUnknown ~= 0 then
                return declaredType
            end
            return self.errorType
        end
        -- If the catch clause is not explicitly annotated, treat it as though it were explicitly
        -- annotated with unknown or any, depending on useUnknownInCatchVariables.
        if self.useUnknownInCatchVariables then
            return self.unknownType
        else
            return self.anyType
        end
    end
    if declaredType ~= nil then
        return self:addOptionalityEx(declaredType, isProperty, isOptional)
    end
    if self.noImplicitAny and ast.IsVariableDeclaration(declaration) and not ast.IsBindingPattern(declaration:Name()) and
        self:getCombinedModifierFlagsCached(declaration) & ModifierFlags.Export == 0 and declaration.flags & NodeFlags.Ambient == 0 then
        -- If --noImplicitAny is on or the declaration is in a Javascript file,
        -- use control flow tracked 'any' type for non-ambient, non-exported var or let variables with no
        -- initializer or a 'null' or 'undefined' initializer.
        local initializer = declaration:Initializer()
        if self:getCombinedNodeFlagsCached(declaration) & NodeFlags.Constant == 0 and (initializer == nil or self:isNullOrUndefined(initializer)) then
            return self.autoType
        end
        -- Use control flow tracked 'any[]' type for non-ambient, non-exported variables with an empty array
        -- literal initializer.
        if initializer ~= nil and checker.isEmptyArrayLiteral(initializer) then
            return self.autoArrayType
        end
    end
    if ast.IsParameterDeclaration(declaration) then
        if declaration:Symbol() == nil then
            -- parameters of function types defined in JSDoc in TS files don't have symbols
            return nil
        end
        local fn = declaration.parent
        -- For a parameter of a set accessor, use the type of the get accessor if one is present
        if ast.IsSetAccessorDeclaration(fn) and self:hasBindableName(fn) then
            local getter = ast.GetDeclarationOfKind(self:getSymbolOfDeclaration(declaration.parent), Kind.GetAccessor)
            if getter ~= nil then
                local getterSignature = self:getSignatureFromDeclaration(getter)
                local thisParameter = self:getAccessorThisParameter(fn)
                if thisParameter ~= nil and declaration == thisParameter then
                    -- Use the type from the *getter*
                    debug.Assert(thisParameter:Type() == nil)
                    return self:getTypeOfSymbol(getterSignature.thisParameter)
                end
                return self:getReturnTypeOfSignature(getterSignature)
            end
        end
        do
            local t = self:getParameterTypeOfFullSignature(fn, declaration)
            if t ~= nil then
                return t
            end
        end
        -- Use contextual parameter type if one is available
        local t
        if declaration:Symbol().name == ast.InternalSymbolNameThis then
            t = self:getContextualThisParameterType(fn)
        else
            t = self:getContextuallyTypedParameterType(declaration)
        end
        if t ~= nil then
            return self:addOptionalityEx(t, false --[[isProperty]], isOptional)
        end
    end
    -- Use the type of the initializer expression if one is present and the declaration is
    -- not a parameter of a contextually typed function
    if declaration:Initializer() ~= nil then
        local t = self:widenTypeInferredFromInitializer(declaration, self:checkDeclarationInitializer(declaration, checkMode, nil --[[contextualType]]))
        return self:addOptionalityEx(t, isProperty, isOptional)
    end
    if self.noImplicitAny and ast.IsPropertyDeclaration(declaration) then
        -- We have a property declaration with no type annotation or initializer, in noImplicitAny mode or a .js file.
        -- Use control flow analysis of this.xxx assignments in the constructor or static block to determine the type of the property.
        if not ast.HasStaticModifier(declaration) then
            local constructor = ast.FindConstructorDeclaration(declaration.parent)
            local t
            if constructor ~= nil then
                t = self:getFlowTypeInConstructor(declaration:Symbol(), constructor)
            elseif declaration:ModifierFlags() & ModifierFlags.Ambient ~= 0 then
                t = self:getTypeOfPropertyInBaseClass(declaration:Symbol())
            end
            if t == nil then
                return nil
            end
            return self:addOptionalityEx(t, true --[[isProperty]], isOptional)
        else
            local staticBlocks = core.Filter(declaration.parent:Members(), ast.IsClassStaticBlockDeclaration)
            local t
            if core.Len(staticBlocks) ~= 0 then
                t = self:getFlowTypeInStaticBlocks(declaration:Symbol(), staticBlocks)
            elseif declaration:ModifierFlags() & ModifierFlags.Ambient ~= 0 then
                t = self:getTypeOfPropertyInBaseClass(declaration:Symbol())
            end
            if t == nil then
                return nil
            end
            return self:addOptionalityEx(t, true --[[isProperty]], isOptional)
        end
    end
    if ast.IsJsxAttribute(declaration) then
        -- if JSX attribute doesn't have initializer, by default the attribute will have boolean value of true.
        -- I.e <Elem attr /> is sugar for <Elem attr={true} />
        return self.trueType
    end
    -- If the declaration specifies a binding pattern and is not a parameter of a contextually
    -- typed function, use the type implied by the binding pattern
    if ast.IsBindingPattern(declaration:Name()) then
        return self:getTypeFromBindingPattern(declaration:Name() --[[includePatternInType]], false --[[reportErrors]], true)
    end
    -- No type specified and nothing can be inferred
    return nil
end

function Checker:checkDeclarationInitializer(declaration, checkMode, contextualType)
    local initializer = declaration:Initializer()
    local t = self:getQuickTypeOfExpression(initializer)
    if t == nil then
        if contextualType ~= nil then
            t = self:checkExpressionWithContextualType(initializer, contextualType, nil --[[inferenceContext]], checkMode)
        else
            t = self:checkExpressionCachedEx(initializer, checkMode)
        end
    end
    if ast.IsParameterDeclaration(ast.GetRootDeclaration(declaration)) then
        local name = declaration:Name()
        if name.kind == Kind.ObjectBindingPattern then
            if checker.isObjectLiteralType(t) then
                return self:padObjectLiteralType(t, name)
            end
        elseif name.kind == Kind.ArrayBindingPattern then
            if checker.isTupleType(t) then
                return self:padTupleType(t, name)
            end
        end
    end
    return t
end

function Checker:padObjectLiteralType(t, pattern)
    local missingElements = {}
    for _, e in ipairs(pattern:Elements() or {}) do
        if e:Initializer() ~= nil then
            local name = self:getPropertyNameFromBindingElement(e)
            if name ~= ast.InternalSymbolNameMissing and self:getPropertyOfType(t, name) == nil then
                missingElements[#missingElements + 1] = e
            end
        end
    end
    if #missingElements == 0 then
        return t
    end
    local members = {}
    for _, prop in ipairs(self:getPropertiesOfObjectType(t) or {}) do
        members[prop.name] = prop
    end
    for _, e in ipairs(missingElements) do
        local symbol = self:newSymbol(SymbolFlags.Property | SymbolFlags.Optional, self:getPropertyNameFromBindingElement(e))
        self.valueSymbolLinks:Get(symbol).resolvedType = self:getTypeFromBindingElement(e, false --[[includePatternInType]], false --[[reportErrors]])
        members[symbol.name] = symbol
    end
    local result = self:newAnonymousType(t.symbol, members, nil, nil, self:getIndexInfosOfType(t))
    result.objectFlags = t.objectFlags
    return result
end

function Checker:getPropertyNameFromBindingElement(e)
    local exprType = self:getLiteralTypeFromPropertyName(e:PropertyNameOrName())
    if checker.isTypeUsableAsPropertyName(exprType) then
        return checker.getPropertyNameFromType(exprType)
    end
    return ast.InternalSymbolNameMissing
end

function Checker:padTupleType(t, pattern)
    local patternElements = pattern:Elements() or {}
    if t:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0 or self:getTypeReferenceArity(t) >= #patternElements then
        return t
    end
    local elementTypes = core.Slice(self:getElementTypes(t), 0, core.Len(self:getElementTypes(t)))
    local elementInfos = core.Slice(t:TargetTupleType().elementInfos, 0, core.Len(t:TargetTupleType().elementInfos))
    for i = self:getTypeReferenceArity(t), #patternElements - 1 do
        local e = patternElements[i + 1]
        if i < #patternElements - 1 or not (ast.IsBindingElement(e) and checker.hasDotDotDotToken(e)) then
            local elementType = self.anyType
            if not ast.IsOmittedExpression(e) and self:hasDefaultValue(e) then
                elementType = self:getTypeFromBindingElement(e, false --[[includePatternInType]], false --[[reportErrors]])
            end
            elementTypes[#elementTypes + 1] = elementType
            elementInfos[#elementInfos + 1] = checker.TupleElementInfo_new({ flags = ElementFlags.Optional })
            if not ast.IsOmittedExpression(e) and not self:hasDefaultValue(e) then
                self:reportImplicitAny(e, self.anyType, checker.WideningKind.Normal)
            end
        end
    end
    return self:createTupleTypeEx(elementTypes, elementInfos, t:TargetTupleType().readonly)
end

function Checker:widenTypeInferredFromInitializer(declaration, t)
    local widened = self:getWidenedLiteralTypeForInitializer(declaration, t)
    if ast.IsInJSFile(declaration) then
        if self:isEmptyLiteralType(widened) then
            self:reportImplicitAny(declaration, self.anyType, checker.WideningKind.Normal)
            return self.anyType
        end
        if self:isEmptyArrayLiteralType(widened) then
            self:reportImplicitAny(declaration, self.anyArrayType, checker.WideningKind.Normal)
            return self.anyArrayType
        end
    end
    return widened
end

function Checker:getWidenedLiteralTypeForInitializer(declaration, t)
    if self:getCombinedNodeFlagsCached(declaration) & NodeFlags.Constant ~= 0 or checker.isDeclarationReadonly(declaration) then
        return t
    end
    return self:getWidenedLiteralType(t)
end

function Checker:getTypeOfFuncClassEnumModule(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        links.resolvedType = self:getTypeOfFuncClassEnumModuleWorker(symbol)
    end
    return links.resolvedType
end

function Checker:getTypeOfFuncClassEnumModuleWorker(symbol)
    if symbol.flags & SymbolFlags.Module ~= 0 and checker.isShorthandAmbientModuleSymbol(symbol) then
        return self.anyType
    elseif symbol.flags & SymbolFlags.ValueModule ~= 0 and symbol.valueDeclaration ~= nil and
        ast.IsSourceFile(symbol.valueDeclaration) and symbol.valueDeclaration:AsSourceFile().commonJSModuleIndicator ~= nil then
        local resolvedModule = self:resolveExternalModuleSymbol(symbol, false --[[dontResolveAlias]])
        if resolvedModule ~= symbol then
            return self:getTypeOfSymbol(resolvedModule)
        end
    end
    local t = self:newObjectType(ObjectFlags.Anonymous, symbol)
    if symbol.flags & SymbolFlags.Class ~= 0 then
        local baseTypeVariable = self:getBaseTypeVariableOfClass(symbol)
        if baseTypeVariable ~= nil then
            return self:getIntersectionType({ t, baseTypeVariable })
        end
        return t
    end
    if self.strictNullChecks and symbol.flags & SymbolFlags.Optional ~= 0 then
        return self:getOptionalType(t --[[isProperty]], true)
    end
    return t
end

function Checker:getBaseTypeVariableOfClass(symbol)
    local baseConstructorType = self:getBaseConstructorTypeOfClass(self:getDeclaredTypeOfClassOrInterface(symbol))
    if baseConstructorType.flags & TypeFlags.TypeVariable ~= 0 then
        return baseConstructorType
    elseif baseConstructorType.flags & TypeFlags.Intersection ~= 0 then
        return core.Find(baseConstructorType:Types(), function(t)
            return t.flags & TypeFlags.TypeVariable ~= 0
        end)
    end
    return nil
end

--[[
 * The base constructor of a class can resolve to
 * * undefinedType if the class has no extends clause,
 * * errorType if an error occurred during resolution of the extends expression,
 * * nullType if the extends expression is the null value,
 * * anyType if the extends expression has type any, or
 * * an object type with at least one construct signature.
]]
function Checker:getBaseConstructorTypeOfClass(t)
    local data = t:AsInterfaceType()
    if data.resolvedBaseConstructorType ~= nil then
        return data.resolvedBaseConstructorType
    end
    local baseTypeNode = checker.getBaseTypeNodeOfClass(t)
    if baseTypeNode == nil then
        data.resolvedBaseConstructorType = self.undefinedType
        return data.resolvedBaseConstructorType
    end
    if not self:pushTypeResolution(t, TypeSystemPropertyName.ResolvedBaseConstructorType) then
        return self.errorType
    end
    local baseConstructorType = self:checkExpression(baseTypeNode:Expression())
    if baseConstructorType.flags & (TypeFlags.Object | TypeFlags.Intersection) ~= 0 then
        -- Resolving the members of a class requires us to resolve the base class of that class.
        -- We force resolution here such that we catch circularities now.
        self:resolveStructuredTypeMembers(baseConstructorType)
    end
    if not self:popTypeResolution() then
        self:error(t.symbol.valueDeclaration, diagnostics.X_0_is_referenced_directly_or_indirectly_in_its_own_base_expression, self:symbolToString(t.symbol))
        if data.resolvedBaseConstructorType == nil then
            data.resolvedBaseConstructorType = self.errorType
        end
        return data.resolvedBaseConstructorType
    end
    if baseConstructorType.flags & TypeFlags.Any == 0 and baseConstructorType ~= self.nullWideningType and not self:isConstructorType(baseConstructorType) then
        local err = self:error(baseTypeNode:Expression(), diagnostics.Type_0_is_not_a_constructor_function_type, self:TypeToString(baseConstructorType))
        if baseConstructorType.flags & TypeFlags.TypeParameter ~= 0 then
            local constraint = self:getConstraintFromTypeParameter(baseConstructorType)
            local ctorReturn = self.unknownType
            if constraint ~= nil then
                local ctorSigs = self:getSignaturesOfType(constraint, SignatureKind.Construct)
                if core.Len(ctorSigs) ~= 0 then
                    ctorReturn = self:getReturnTypeOfSignature(ctorSigs[1])
                end
            end
            if baseConstructorType.symbol.declarations ~= nil then
                err:AddRelatedInfo(checker.createDiagnosticForNode(baseConstructorType.symbol.declarations[1], diagnostics.Did_you_mean_for_0_to_be_constrained_to_type_new_args_Colon_any_1, self:symbolToString(baseConstructorType.symbol), self:TypeToString(ctorReturn)))
            end
        end
        if data.resolvedBaseConstructorType == nil then
            data.resolvedBaseConstructorType = self.errorType
        end
        return data.resolvedBaseConstructorType
    end
    if data.resolvedBaseConstructorType == nil then
        data.resolvedBaseConstructorType = baseConstructorType
    end
    return data.resolvedBaseConstructorType
end

function Checker:isFunctionType(t)
    return t.flags & TypeFlags.Object ~= 0 and core.Len(self:getSignaturesOfType(t, SignatureKind.Call)) > 0
end

function Checker:isConstructorType(t)
    if core.Len(self:getSignaturesOfType(t, SignatureKind.Construct)) > 0 then
        return true
    end
    if t.flags & TypeFlags.TypeVariable ~= 0 then
        local constraint = self:getBaseConstraintOfType(t)
        return constraint ~= nil and self:isMixinConstructorType(constraint)
    end
    return false
end

-- A type is a mixin constructor if it has a single construct signature taking no type parameters and a single
-- rest parameter of type any[].
function Checker:isMixinConstructorType(t)
    local signatures = self:getSignaturesOfType(t, SignatureKind.Construct)
    if core.Len(signatures) == 1 then
        local s = signatures[1]
        if core.Len(s.typeParameters) == 0 and core.Len(s.parameters) == 1 and checker.signatureHasRestParameter(s) then
            local paramType = self:getTypeOfParameter(s.parameters[1])
            return checker.IsTypeAny(paramType) or self:getElementTypeOfArrayType(paramType) == self.anyType
        end
    end
    return false
end

function checker.signatureHasRestParameter(sig)
    return sig.flags & SignatureFlags.HasRestParameter ~= 0
end

function Checker:getTypeOfParameter(symbol)
    local declaration = symbol.valueDeclaration
    return self:addOptionalityEx(self:getTypeOfSymbol(symbol), false, declaration ~= nil and (declaration:Initializer() ~= nil or checker.isOptionalDeclaration(declaration)))
end

function Checker:getConstraintOfType(t)
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        return self:getConstraintOfTypeParameter(t)
    elseif t.flags & TypeFlags.IndexedAccess ~= 0 then
        return self:getConstraintOfIndexedAccess(t)
    elseif t.flags & TypeFlags.Conditional ~= 0 then
        return self:getConstraintOfConditionalType(t)
    end
    return self:getBaseConstraintOfType(t)
end

function Checker:getConstraintOfTypeParameter(typeParameter)
    if self:hasNonCircularBaseConstraint(typeParameter) then
        return self:getConstraintFromTypeParameter(typeParameter)
    end
    return nil
end

function Checker:hasNonCircularBaseConstraint(t)
    return self:getResolvedBaseConstraint(t, nil) ~= self.circularConstraintType
end

-- This is a worker function. Use getConstraintOfTypeParameter which guards against circular constraints
function Checker:getConstraintFromTypeParameter(t)
    if t.flags & TypeFlags.TypeParameter == 0 then
        return nil
    end

    local tp = t:AsTypeParameter()
    if tp.constraint == nil then
        local constraint
        if tp.target ~= nil then
            constraint = self:instantiateType(self:getConstraintOfTypeParameter(tp.target), tp.mapper)
        else
            local constraintDeclaration = self:getConstraintDeclaration(t)
            if constraintDeclaration ~= nil then
                constraint = self:getTypeFromTypeNode(constraintDeclaration)
                if constraint.flags & TypeFlags.Any ~= 0 and not self:isErrorType(constraint) then
                    -- use stringNumberSymbolType as the base constraint for mapped type key constraints (unknown isn;t assignable to that, but `any` was),
                    -- use unknown otherwise
                    if ast.IsMappedTypeNode(constraintDeclaration.parent.parent) then
                        constraint = self.stringNumberSymbolType
                    else
                        constraint = self.unknownType
                    end
                end
            else
                constraint = self:getInferredTypeParameterConstraint(t, false)
            end
        end
        if constraint == nil then
            constraint = self.noConstraintType
        end
        tp.constraint = constraint
    end
    if tp.constraint ~= self.noConstraintType then
        return tp.constraint
    end
    return nil
end

function Checker:getConstraintOrUnknownFromTypeParameter(t)
    local result = self:getConstraintFromTypeParameter(t)
    return core.IfElse(result ~= nil, result, self.unknownType)
end

function Checker:getInferredTypeParameterConstraint(t, omitTypeReferences)
    local inferences
    if t.symbol ~= nil and core.Len(t.symbol.declarations) ~= 0 then
        for _, declaration in ipairs(t.symbol.declarations) do
            if ast.IsInferTypeNode(declaration.parent) then
                -- When an 'infer T' declaration is immediately contained in a type reference node
                -- (such as 'Foo<infer T>'), T's constraint is inferred from the constraint of the
                -- corresponding type parameter in 'Foo'. When multiple 'infer T' declarations are
                -- present, we form an intersection of the inferred constraint types.
                local child = declaration.parent
                local parent = child.parent
                while parent ~= nil and ast.IsParenthesizedTypeNode(parent) do
                    child = parent
                    parent = child.parent
                end
                if ast.IsTypeReferenceNode(parent) and not omitTypeReferences then
                    local typeParameters = self:getTypeParametersForTypeReferenceOrImport(parent)
                    if typeParameters ~= nil then
                        local index = core.FindIndex(parent:TypeArguments(), function(n)
                            return n == child
                        end)
                        if index >= 0 and index < #typeParameters then
                            local declaredConstraint = self:getConstraintOfTypeParameter(typeParameters[index + 1])
                            if declaredConstraint ~= nil then
                                -- Type parameter constraints can reference other type parameters so
                                -- constraints need to be instantiated. If instantiation produces the
                                -- type parameter itself, we discard that inference. For example, in
                                --   type Foo<T extends string, U extends T> = [T, U];
                                --   type Bar<T> = T extends Foo<infer X, infer X> ? Foo<X, X> : T;
                                -- the instantiated constraint for U is X, so we discard that inference.
                                local mapper = checker.newDeferredTypeMapper(typeParameters, core.MapIndex(typeParameters, function(_, index_)
                                    return function()
                                        return self:getEffectiveTypeArgumentAtIndex(parent, typeParameters, index_)
                                    end
                                end))
                                local constraint = self:instantiateType(declaredConstraint, mapper)
                                if constraint ~= t then
                                    inferences = core.Append(inferences, constraint)
                                end
                            end
                        end
                    end
                elseif ast.IsParameterDeclaration(parent) and parent:AsParameterDeclaration().dotDotDotToken ~= nil or
                    ast.IsRestTypeNode(parent) or
                    ast.IsNamedTupleMember(parent) and parent:AsNamedTupleMember().dotDotDotToken ~= nil then
                    inferences = core.Append(inferences, self:createArrayType(self.unknownType))
                elseif ast.IsTemplateLiteralTypeSpan(parent) then
                    inferences = core.Append(inferences, self.stringType)
                elseif ast.IsTypeParameterDeclaration(parent) and ast.IsMappedTypeNode(parent.parent) then
                    inferences = core.Append(inferences, self.stringNumberSymbolType)
                elseif ast.IsMappedTypeNode(parent) and parent:Type() ~= nil and
                    ast.SkipParentheses(parent:Type()) == declaration.parent and
                    ast.IsConditionalTypeNode(parent.parent) and
                    parent.parent:AsConditionalTypeNode().extendsType == parent and
                    ast.IsMappedTypeNode(parent.parent:AsConditionalTypeNode().checkType) and
                    parent.parent:AsConditionalTypeNode().checkType:Type() ~= nil then
                    local checkMappedType = parent.parent:AsConditionalTypeNode().checkType
                    local nodeType = self:getTypeFromTypeNode(checkMappedType:Type())
                    local checkMappedTypeParameter = checkMappedType:AsMappedTypeNode().typeParameter
                    local mapper = checker.newSimpleTypeMapper(self:getDeclaredTypeOfTypeParameter(self:getSymbolOfDeclaration(checkMappedTypeParameter)),
                        core.IfElse(checkMappedTypeParameter:AsTypeParameterDeclaration().constraint ~= nil,
                            self:getTypeFromTypeNode(checkMappedTypeParameter:AsTypeParameterDeclaration().constraint),
                            self.stringNumberSymbolType))
                    inferences = core.Append(inferences, self:instantiateType(nodeType, mapper))
                end
            end
        end
    end
    if core.Len(inferences) ~= 0 then
        return self:getIntersectionType(inferences)
    end
    return nil
end

function Checker:getTypeParametersForTypeReferenceOrImport(node)
    local t = self:getTypeFromTypeNode(node)
    if not self:isErrorType(t) then
        local symbol = self:getResolvedSymbolOrNil(node)
        if symbol ~= nil then
            return self:getTypeParametersForTypeAndSymbol(t, symbol)
        end
    end
    return nil
end

function Checker:getTypeParametersForTypeAndSymbol(t, symbol)
    if not self:isErrorType(t) then
        if symbol.flags & SymbolFlags.TypeAlias ~= 0 then
            local typeParameters = self.typeAliasLinks:Get(symbol).typeParameters
            if core.Len(typeParameters) ~= 0 then
                return typeParameters
            end
        end
        if t.objectFlags & ObjectFlags.Reference ~= 0 then
            return t:Target():AsInterfaceType():LocalTypeParameters()
        end
    end
    return nil
end

function Checker:getEffectiveTypeArgumentAtIndex(node, typeParameters, index)
    local typeArguments = node:TypeArguments()
    if index < core.Len(typeArguments) then
        return self:getTypeFromTypeNode(typeArguments[index + 1])
    end
    return self:getEffectiveTypeArguments(node, typeParameters)[index + 1]
end

function Checker:getConstraintOfIndexedAccess(t)
    if self:hasNonCircularBaseConstraint(t) then
        return self:getConstraintFromIndexedAccess(t)
    end
    return nil
end

function Checker:getConstraintFromIndexedAccess(t)
    local d = t:AsIndexedAccessType()
    if self:isMappedTypeGenericIndexedAccess(t) then
        -- For indexed access types of the form { [P in K]: E }[X], where K is non-generic and X is generic,
        -- we substitute an instantiation of E where P is replaced with X.
        return self:substituteIndexedMappedType(d.objectType, d.indexType)
    end
    local indexConstraint = self:getSimplifiedTypeOrConstraint(d.indexType)
    if indexConstraint ~= nil and indexConstraint ~= d.indexType then
        local indexedAccess = self:getIndexedAccessTypeOrUndefined(d.objectType, indexConstraint, d.accessFlags, nil, nil)
        if indexedAccess ~= nil then
            return indexedAccess
        end
    end
    local objectConstraint = self:getSimplifiedTypeOrConstraint(d.objectType)
    if objectConstraint ~= nil and objectConstraint ~= d.objectType then
        return self:getIndexedAccessTypeOrUndefined(objectConstraint, d.indexType, d.accessFlags, nil, nil)
    end
    return nil
end

function Checker:getConstraintOfConditionalType(t)
    if self:hasNonCircularBaseConstraint(t) then
        return self:getConstraintFromConditionalType(t)
    end
    return nil
end

function Checker:getConstraintFromConditionalType(t)
    local constraint = self:getConstraintOfDistributiveConditionalType(t)
    if constraint ~= nil then
        return constraint
    end
    return self:getDefaultConstraintOfConditionalType(t)
end

function Checker:getDefaultConstraintOfConditionalType(t)
    local d = t:AsConditionalType()
    if d.resolvedDefaultConstraint == nil then
        -- An `any` branch of a conditional type would normally be viral - specifically, without special handling here,
        -- a conditional type with a single branch of type `any` would be assignable to anything, since it's constraint would simplify to
        -- just `any`. This result is _usually_ unwanted - so instead here we elide an `any` branch from the constraint type,
        -- in effect treating `any` like `never` rather than `unknown` in this location.
        local trueConstraint = self:getInferredTrueTypeFromConditionalType(t)
        local falseConstraint = self:getFalseTypeFromConditionalType(t)
        if checker.IsTypeAny(trueConstraint) then
            d.resolvedDefaultConstraint = falseConstraint
        elseif checker.IsTypeAny(falseConstraint) then
            d.resolvedDefaultConstraint = trueConstraint
        else
            d.resolvedDefaultConstraint = self:getUnionType({ trueConstraint, falseConstraint })
        end
    end
    return d.resolvedDefaultConstraint
end

function Checker:getConstraintOfDistributiveConditionalType(t)
    local d = t:AsConditionalType()
    if d.resolvedConstraintOfDistributive == nil then
        -- Check if we have a conditional type of the form 'T extends U ? X : Y', where T is a constrained
        -- type parameter. If so, create an instantiation of the conditional type where T is replaced
        -- with its constraint. We do this because if the constraint is a union type it will be distributed
        -- over the conditional type and possibly reduced. For example, 'T extends undefined ? never : T'
        -- removes 'undefined' from T.
        -- We skip returning a distributive constraint for a restrictive instantiation of a conditional type
        -- as the constraint for all type params (check type included) have been replace with `unknown`, which
        -- is going to produce even more false positive/negative results than the distribute constraint already does.
        -- Please note: the distributive constraint is a kludge for emulating what a negated type could to do filter
        -- a union - once negated types exist and are applied to the conditional false branch, this "constraint"
        -- likely doesn't need to exist.
        if d.root.isDistributive and self.cachedTypes[checker.CachedTypeKey(checker.CachedTypeKind.RestrictiveInstantiation, t.id)] ~= t then
            local constraint = self:getSimplifiedType(d.checkType, false --[[writing]])
            if constraint == d.checkType then
                constraint = self:getConstraintOfType(constraint)
            end
            if constraint ~= nil and constraint ~= d.checkType then
                local instantiated = self:getConditionalTypeInstantiation(t, checker.prependTypeMapping(d.root.checkType, constraint, d.mapper), true --[[forConstraint]], nil)
                if instantiated.flags & TypeFlags.Never == 0 then
                    d.resolvedConstraintOfDistributive = instantiated
                    return instantiated
                end
            end
        end
        d.resolvedConstraintOfDistributive = self.noConstraintType
    end
    if d.resolvedConstraintOfDistributive ~= self.noConstraintType then
        return d.resolvedConstraintOfDistributive
    end
    return nil
end

function Checker:getDeclaredTypeOfClassOrInterface(symbol)
    local links = self.declaredTypeLinks:Get(symbol)
    if links.declaredType == nil then
        local kind = core.IfElse(symbol.flags & SymbolFlags.Class ~= 0, ObjectFlags.Class, ObjectFlags.Interface)
        local t = self:newObjectType(kind, symbol)
        links.declaredType = t
        local outerTypeParameters = self:getOuterTypeParametersOfClassOrInterface(symbol)
        -- Go slices keep their length when appended to; the Lua append below works in place.
        local outerTypeParameterCount = core.Len(outerTypeParameters)
        local typeParameters = self:appendLocalTypeParametersOfClassOrInterfaceOrTypeAlias(outerTypeParameters, symbol)
        -- A class or interface is generic if it has type parameters or a "this" type. We always give classes a "this" type
        -- because it is not feasible to analyze all members to determine if the "this" type escapes the class (in particular,
        -- property types inferred from initializers and method return types inferred from return statements are very hard
        -- to exhaustively analyze). We give interfaces a "this" type if we can't definitely determine that they are free of
        -- "this" references.
        if typeParameters ~= nil or kind == ObjectFlags.Class or not self:isThislessInterface(symbol) then
            t.objectFlags = t.objectFlags | ObjectFlags.Reference
            local d = t:AsInterfaceType()
            d.thisType = self:newTypeParameter(symbol)
            d.thisType:AsTypeParameter().isThisType = true
            d.thisType:AsTypeParameter().constraint = t
            -- Go: append(typeParameters, d.thisType) (copy, typeParameters may be shared)
            local all = {}
            for _, tp in ipairs(typeParameters or {}) do
                all[#all + 1] = tp
            end
            all[#all + 1] = d.thisType
            d.allTypeParameters = all
            d.outerTypeParameterCount = outerTypeParameterCount
            d.resolvedTypeArguments = d:TypeParameters()
            d.instantiations = {}
            d.instantiations[checker.getTypeListKey(d.resolvedTypeArguments)] = t
            d.target = t
        end
    end
    return links.declaredType
end

--[[
 * Returns true if the interface given by the symbol is free of "this" references.
 *
 * Specifically, the result is true if the interface itself contains no references
 * to "this" in its body, if all base types are interfaces,
 * and if none of the base interfaces have a "this" type.
]]
function Checker:isThislessInterface(symbol)
    for _, declaration in ipairs(symbol.declarations or {}) do
        if ast.IsInterfaceDeclaration(declaration) then
            if declaration.flags & NodeFlags.ContainsThis ~= 0 then
                return false
            end
            local baseTypeNodes = ast.GetExtendsHeritageClauseElements(declaration)
            for _, node in ipairs(baseTypeNodes or {}) do
                local name = ast.GetHeritageClauseElementName(node)
                if ast.IsEntityName(name) or ast.IsEntityNameExpression(name) then
                    local baseSymbol = self:resolveEntityName(name, SymbolFlags.Type, true --[[ignoreErrors]], false, nil)
                    if baseSymbol == nil or baseSymbol.flags & SymbolFlags.Interface == 0 or self:getDeclaredTypeOfClassOrInterface(baseSymbol):AsInterfaceType().thisType ~= nil then
                        return false
                    end
                end
            end
        end
    end
    return true
end

-- CacheHashKey: in Lua the unhashed key byte string prefixed with "h" (see docs/CHECKER.md and
-- checker.hashString128 in checker_1.lua). The zero CacheHashKey is "".

function checker.CacheHashKey_IsZero(k)
    return k == nil or k == ""
end

-- keyBuilder: Go keeps up to 192 bytes inline and spills the rest into overflowBuffer; the key's byte
-- stream is overflowBuffer followed by the inline bytes. In Lua inlineBuffer is an array of byte strings
-- and overflowBuffer a string.
local inlineBufferLen = 192

checker.defineStruct("keyBuilder", nil, { inlineLength = 0 })

local function newKeyBuilder()
    return checker.keyBuilder_new({ inlineBuffer = {} })
end

function checker.keyBuilder:hash()
    if self.overflowBuffer == nil then
        return checker.hashString128(table.concat(self.inlineBuffer))
    end
    return checker.hashString128(self.overflowBuffer .. table.concat(self.inlineBuffer))
end

-- spill moves the buffered bytes onto the end of overflowBuffer, so the key's byte
-- stream stays overflowBuffer followed by inlineBuffer.
function checker.keyBuilder:spill()
    self.overflowBuffer = (self.overflowBuffer or "") .. table.concat(self.inlineBuffer)
    self.inlineBuffer = {}
    self.inlineLength = 0
end

function checker.keyBuilder:writeByte(c)
    if self.inlineLength == inlineBufferLen then
        self:spill()
    end
    self.inlineBuffer[#self.inlineBuffer + 1] = string.char(c)
    self.inlineLength = self.inlineLength + 1
end

function checker.keyBuilder:writeString(s)
    if self.inlineLength + #s > inlineBufferLen then
        self:spill()
        if #s > inlineBufferLen then
            self.overflowBuffer = self.overflowBuffer .. s
            return
        end
    end
    self.inlineBuffer[#self.inlineBuffer + 1] = s
    self.inlineLength = self.inlineLength + #s
end

function checker.keyBuilder:writeUint32(v)
    if self.inlineLength + 4 > inlineBufferLen then
        self:spill()
    end
    self.inlineBuffer[#self.inlineBuffer + 1] = string.pack("<I4", v & 0xFFFFFFFF)
    self.inlineLength = self.inlineLength + 4
end

function checker.keyBuilder:writeUint64(v)
    if self.inlineLength + 8 > inlineBufferLen then
        self:spill()
    end
    self.inlineBuffer[#self.inlineBuffer + 1] = string.pack("<i8", v)
    self.inlineLength = self.inlineLength + 8
end

function checker.keyBuilder:writeInt(value)
    self:writeUint64(value)
end

function checker.keyBuilder:writeSymbol(s)
    self:writeUint64(ast.GetSymbolId(s))
end

function checker.keyBuilder:writeType(t)
    self:writeUint32(t.id)
end

function checker.keyBuilder:writeTypes(types)
    self:writeInt(core.Len(types))
    for _, t in ipairs(types or {}) do
        self:writeType(t)
    end
end

function checker.keyBuilder:writeAlias(alias)
    if alias ~= nil then
        self:writeByte(1)
        self:writeSymbol(alias.symbol)
        self:writeTypes(alias.typeArguments)
    else
        self:writeByte(0)
    end
end

function checker.keyBuilder:writeGenericTypeReferences(source, target, ignoreConstraints)
    local constrained = false
    local typeParameters = {}
    local writeTypeReference
    writeTypeReference = function(ref, depth)
        self:writeType(ref:Target())
        for _, t in ipairs(ref:AsTypeReference().resolvedTypeArguments or {}) do
            local continue_ = false
            if t.flags & TypeFlags.TypeParameter ~= 0 then
                if ignoreConstraints or t.checker:getConstraintOfTypeParameter(t) == nil then
                    local index = core.FindIndex(typeParameters, function(tp)
                        return tp == t
                    end)
                    if index < 0 then
                        index = #typeParameters
                        typeParameters[#typeParameters + 1] = t
                    end
                    self:writeByte(string.byte("="))
                    self:writeInt(index)
                    continue_ = true
                else
                    constrained = true
                end
            elseif depth < 4 and checker.isTypeReferenceWithGenericArguments(t) then
                self:writeByte(string.byte("<"))
                writeTypeReference(t, depth + 1)
                self:writeByte(string.byte(">"))
                continue_ = true
            end
            if not continue_ then
                self:writeByte(string.byte("-"))
                self:writeType(t)
            end
        end
    end
    writeTypeReference(source, 0)
    self:writeByte(string.byte(","))
    writeTypeReference(target, 0)
    return constrained
end

function checker.keyBuilder:writeNodeId(id)
    self:writeUint64(id)
end

function checker.keyBuilder:writeNode(node)
    if node ~= nil then
        self:writeNodeId(ast.GetNodeId(node))
    end
end

function checker.getTypeListKey(types)
    local b = newKeyBuilder()
    b:writeTypes(types)
    return b:hash()
end

function checker.getAliasKey(alias)
    local b = newKeyBuilder()
    b:writeAlias(alias)
    return b:hash()
end

function checker.getUnionKey(types, origin, alias)
    local b = newKeyBuilder()
    if origin == nil then
        b:writeTypes(types)
    elseif origin.flags & TypeFlags.Union ~= 0 then
        b:writeByte(string.byte("|"))
        b:writeTypes(origin:Types())
    elseif origin.flags & TypeFlags.Intersection ~= 0 then
        b:writeByte(string.byte("&"))
        b:writeTypes(origin:Types())
    elseif origin.flags & TypeFlags.Index ~= 0 then
        -- origin type id alone is insufficient, as `keyof x` may resolve to multiple WIP values while `x` is still resolving
        b:writeByte(string.byte("#"))
        b:writeType(origin)
        b:writeByte(string.byte("|"))
        b:writeTypes(types)
    else
        error("Unhandled case in getUnionKey", 0)
    end
    b:writeAlias(alias)
    return b:hash()
end

function checker.getIntersectionKey(types, flags, alias)
    local b = newKeyBuilder()
    b:writeTypes(types)
    if flags & checker.IntersectionFlags.NoConstraintReduction == 0 then
        b:writeAlias(alias)
    else
        b:writeByte(string.byte("*"))
    end
    return b:hash()
end

function checker.getTupleKey(elementInfos, readonly)
    local b = newKeyBuilder()
    for _, e in ipairs(elementInfos or {}) do
        if e.flags & ElementFlags.Required ~= 0 then
            b:writeByte(string.byte("#"))
        elseif e.flags & ElementFlags.Optional ~= 0 then
            b:writeByte(string.byte("?"))
        elseif e.flags & ElementFlags.Rest ~= 0 then
            b:writeByte(string.byte("."))
        else
            b:writeByte(string.byte("*"))
        end
        if e.labeledDeclaration ~= nil then
            b:writeNode(e.labeledDeclaration)
        end
    end
    if readonly then
        b:writeByte(string.byte("!"))
    end
    return b:hash()
end

function checker.getTypeAliasInstantiationKey(typeArguments, alias)
    return checker.getTypeInstantiationKey(typeArguments, alias, false)
end

function checker.getTypeInstantiationKey(typeArguments, alias, singleSignature)
    local b = newKeyBuilder()
    b:writeTypes(typeArguments)
    b:writeAlias(alias)
    if singleSignature then
        b:writeByte(string.byte("!"))
    end
    return b:hash()
end

function checker.getIndexedAccessKey(objectType, indexType, accessFlags, alias)
    local b = newKeyBuilder()
    b:writeType(objectType)
    b:writeType(indexType)
    b:writeUint32(accessFlags)
    b:writeAlias(alias)
    return b:hash()
end

function checker.getTemplateTypeKey(texts, types)
    local b = newKeyBuilder()
    b:writeTypes(types)
    b:writeByte(string.byte("|"))
    for _, s in ipairs(texts or {}) do
        b:writeInt(#s)
    end
    b:writeByte(string.byte("|"))
    for _, s in ipairs(texts or {}) do
        b:writeString(s)
    end
    return b:hash()
end

function checker.getConditionalTypeKey(typeArguments, alias, forConstraint)
    local b = newKeyBuilder()
    b:writeTypes(typeArguments)
    b:writeAlias(alias)
    if forConstraint then
        b:writeByte(string.byte("!"))
    end
    return b:hash()
end

function checker.getRelationKey(source, target, intersectionState, isIdentity, ignoreConstraints)
    if isIdentity and source.id > target.id then
        source, target = target, source
    end
    local b = newKeyBuilder()
    local constrained = false
    if checker.isTypeReferenceWithGenericArguments(source) and checker.isTypeReferenceWithGenericArguments(target) then
        b:writeByte(string.byte("g"))
        constrained = b:writeGenericTypeReferences(source, target, ignoreConstraints)
    else
        b:writeByte(string.byte("s"))
        b:writeType(source)
        b:writeType(target)
    end
    b:writeUint32(intersectionState)
    return b:hash(), constrained
end

function checker.getNodeListKey(nodes)
    local b = newKeyBuilder()
    b:writeInt(core.Len(nodes))
    for _, n in ipairs(nodes or {}) do
        b:writeNode(n)
    end
    return b:hash()
end

function checker.isTypeReferenceWithGenericArguments(t)
    return checker.isNonDeferredTypeReference(t) and core.Some(t.checker:getTypeArguments(t), function(t_)
        return t_.flags & TypeFlags.TypeParameter ~= 0 or checker.isTypeReferenceWithGenericArguments(t_)
    end)
end

function checker.isNonDeferredTypeReference(t)
    return t.objectFlags & ObjectFlags.Reference ~= 0 and t:AsTypeReference().node == nil
end

-- Return true if type parameter originates in an unconstrained declaration in a type parameter list
function checker.isUnconstrainedTypeParameter(tp)
    local target = tp:Target()
    if target == nil then
        target = tp
    end
    if target.symbol == nil then
        return false
    end
    for _, d in ipairs(target.symbol.declarations or {}) do
        if ast.IsTypeParameterDeclaration(d) and (d:AsTypeParameterDeclaration().constraint ~= nil or ast.IsMappedTypeNode(d.parent) or ast.IsInferTypeNode(d.parent)) then
            return false
        end
    end
    return true
end

function Checker:isNullOrUndefined(node)
    local expr = ast.SkipParentheses(node)
    if expr.kind == Kind.NullKeyword then
        return true
    elseif expr.kind == Kind.Identifier then
        return self:getResolvedSymbol(expr) == self.undefinedSymbol
    end
    return false
end

function Checker:checkRightHandSideOfForOf(statement)
    local use = core.IfElse(statement:AsForInOrOfStatement().awaitModifier ~= nil, IterationUse.ForAwaitOf, IterationUse.ForOf)
    return self:checkIteratedTypeOrElementType(use, self:checkNonNullExpression(statement:Expression()), self.undefinedType, statement:Expression())
end

-- Return the inferred type for a binding element
function Checker:getTypeForBindingElement(declaration)
    local checkMode = core.IfElse(checker.hasDotDotDotToken(declaration), CheckMode.RestBindingElement, CheckMode.Normal)
    local parentType = self:getTypeForBindingElementParent(declaration.parent.parent, checkMode)
    if parentType ~= nil then
        return self:getBindingElementTypeFromParentType(declaration, parentType, false --[[noTupleBoundsCheck]])
    end
    return nil
end

-- Return the type of a binding element parent. We check SymbolLinks first to see if a type has been
-- assigned by contextual typing.
function Checker:getTypeForBindingElementParent(node, checkMode)
    if checkMode == CheckMode.Normal then
        -- We can use a cached resolved type if no optionality was included in that type.
        local symbol = self:getSymbolOfDeclaration(node)
        if symbol ~= nil then
            local resolvedType = self.valueSymbolLinks:Get(symbol).resolvedType
            if resolvedType ~= nil and not (self.strictNullChecks and checker.isOptionalDeclaration(node)) then
                return resolvedType
            end
        end
    end
    return self:getTypeForVariableLikeDeclaration(node, false --[[includeOptionality]], checkMode)
end

function Checker:getBindingElementTypeFromParentType(declaration, parentType, noTupleBoundsCheck)
    -- If an any type was inferred for parent, infer that for the binding element
    if checker.IsTypeAny(parentType) then
        return parentType
    end
    local pattern = declaration.parent
    -- Relax null check on ambient destructuring parameters, since the parameters have no implementation and are just documentation
    if self.strictNullChecks and declaration.flags & NodeFlags.Ambient ~= 0 and ast.IsPartOfParameterDeclaration(declaration) then
        parentType = self:GetNonNullableType(parentType)
    elseif self.strictNullChecks and pattern.parent:Initializer() ~= nil and not self:hasTypeFacts(self:getTypeOfInitializer(pattern.parent:Initializer()), TypeFacts.EQUndefined) then
        parentType = self:getTypeWithFacts(parentType, TypeFacts.NEUndefined)
    end
    local accessFlags = AccessFlags.ExpressionPosition | core.IfElse(noTupleBoundsCheck or self:hasDefaultValue(declaration), AccessFlags.AllowMissing, 0)
    local t
    if pattern.kind == Kind.ObjectBindingPattern then
        if checker.hasDotDotDotToken(declaration) then
            parentType = self:getReducedType(parentType)
            if parentType.flags & TypeFlags.Unknown ~= 0 or not self:isValidSpreadType(parentType) then
                self:error(declaration, diagnostics.Rest_types_may_only_be_created_from_object_types)
                return self.errorType
            end
            local elements = pattern:Elements()
            local literalMembers = {}
            for _, element in ipairs(elements or {}) do
                if not checker.hasDotDotDotToken(element) then
                    local name = element:PropertyNameOrName()
                    literalMembers[#literalMembers + 1] = name
                end
            end
            t = self:getRestType(parentType, literalMembers, declaration:Symbol())
        else
            -- Use explicitly specified property name ({ p: xxx } form), or otherwise the implied name ({ p } form)
            local name = declaration:PropertyNameOrName()
            local indexType = self:getLiteralTypeFromPropertyName(name)
            local declaredType = self:getIndexedAccessTypeEx(parentType, indexType, accessFlags, name, nil)
            t = self:getFlowTypeOfDestructuring(declaration, declaredType)
        end
    elseif pattern.kind == Kind.ArrayBindingPattern then
        -- This elementType will be used if the specific property corresponding to this index is not
        -- present (aka the tuple element property). This call also checks that the parentType is in
        -- fact an iterable or array (depending on target language).
        local elementType = self:checkIteratedTypeOrElementType(IterationUse.Destructuring | core.IfElse(checker.hasDotDotDotToken(declaration), 0, IterationUse.PossiblyOutOfBounds), parentType, self.undefinedType, pattern)
        local index = core.FindIndex(pattern:Elements(), function(e)
            return e == declaration
        end)
        if checker.hasDotDotDotToken(declaration) then
            -- If the parent is a tuple type, the rest element has a tuple type of the
            -- remaining tuple element types. Otherwise, the rest element has an array type with same
            -- element type as the parent type.
            local baseConstraint = self:mapType(parentType, function(t_)
                if t_.flags & TypeFlags.InstantiableNonPrimitive ~= 0 then
                    return self:getBaseConstraintOrType(t_)
                end
                return t_
            end)
            if checker.everyType(baseConstraint, checker.isTupleType) then
                t = self:mapType(baseConstraint, function(t_)
                    return self:sliceTupleType(t_, index, 0)
                end)
            else
                t = self:createArrayType(elementType)
            end
        elseif self:isArrayLikeType(parentType) then
            local indexType = self:getNumberLiteralType(index + 0.0)
            local declaredType = core.OrElse(self:getIndexedAccessTypeOrUndefined(parentType, indexType, accessFlags, declaration:Name(), nil), self.errorType)
            t = self:getFlowTypeOfDestructuring(declaration, declaredType)
        else
            t = elementType
        end
    else
        error("Unhandled case in getBindingElementTypeFromParentType", 0)
    end
    if declaration:Initializer() == nil then
        return t
    end
    if ast.WalkUpBindingElementsAndPatterns(declaration):Type() ~= nil then
        -- In strict null checking mode, if a default value of a non-undefined type is specified, remove
        -- undefined from the final type.
        if self.strictNullChecks and not self:hasTypeFacts(self:checkDeclarationInitializer(declaration, CheckMode.Normal, nil), TypeFacts.IsUndefined) then
            return self:getNonUndefinedType(t)
        end
        return t
    end
    return self:widenTypeInferredFromInitializer(declaration, self:getUnionTypeEx({ self:getNonUndefinedType(t), self:checkDeclarationInitializer(declaration, CheckMode.Normal, nil) }, UnionReduction.Subtype, nil, nil))
end

function Checker:getRestType(source, properties, symbol)
    source = self:filterType(source, function(t)
        return t.flags & TypeFlags.Nullable == 0
    end)
    if source.flags & TypeFlags.Never ~= 0 then
        return self.emptyObjectType
    end
    if source.flags & TypeFlags.Union ~= 0 then
        return self:mapType(source, function(t)
            return self:getRestType(t, properties, symbol)
        end)
    end
    local omitKeyType = self:getUnionType(core.Map(properties, function(p)
        return self:getLiteralTypeFromPropertyName(p)
    end))
    local spreadableProperties = {}
    local unspreadableToRestKeys = {}
    for _, prop in ipairs(self:getPropertiesOfType(source) or {}) do
        local literalTypeFromProperty = self:getLiteralTypeFromProperty(prop, TypeFlags.StringOrNumberLiteralOrUnique, false)
        if not self:isTypeAssignableTo(literalTypeFromProperty, omitKeyType) and checker.getDeclarationModifierFlagsFromSymbol(prop) & (ModifierFlags.Private | ModifierFlags.Protected) == 0 and self:isSpreadableProperty(prop) then
            spreadableProperties[#spreadableProperties + 1] = prop
        else
            unspreadableToRestKeys[#unspreadableToRestKeys + 1] = literalTypeFromProperty
        end
    end
    if self:isGenericObjectType(source) or self:isGenericIndexType(omitKeyType) then
        if #unspreadableToRestKeys ~= 0 then
            -- If the type we're spreading from has properties that cannot
            -- be spread into the rest type (e.g. getters, methods), ensure
            -- they are explicitly omitted, as they would in the non-generic case.
            local keys = { omitKeyType }
            for _, k in ipairs(unspreadableToRestKeys) do
                keys[#keys + 1] = k
            end
            omitKeyType = self:getUnionType(keys)
        end
        if omitKeyType.flags & TypeFlags.Never ~= 0 then
            return source
        end
        local omitTypeAlias = self.getGlobalOmitSymbol()
        if omitTypeAlias == nil then
            return self.errorType
        end
        return self:getTypeAliasInstantiation(omitTypeAlias, { source, omitKeyType }, nil)
    end
    local members = {}
    for _, prop in ipairs(spreadableProperties) do
        members[prop.name] = self:getSpreadSymbol(prop, false --[[readonly]])
    end
    local result = self:newAnonymousType(symbol, members, nil, nil, self:getIndexInfosOfType(source))
    result.objectFlags = result.objectFlags | checker.ObjectFlagsObjectRestType
    return result
end
