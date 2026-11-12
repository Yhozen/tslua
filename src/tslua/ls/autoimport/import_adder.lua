local autoimport = require("tslua.ls.autoimport")
local ast = require("tslua.ast")
local change = require("tslua.ls.change")
local core = require("tslua.core")
local debug = require("tslua.debug")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")
local nodebuilder = require("tslua.nodebuilder")

-- ImportAdder interface: HasFixes(), AddImportFromExportedSymbol(symbol, isValidTypeOnlyUseSite),
-- AddImportFix(fix), Edits().

-- addToExistingState tracks modifications to an existing import clause or binding pattern
-- { importClauseOrBindingPattern, defaultImport, namedImports (map name -> newImportBinding) }

-- importsCollection tracks new imports to be created for a given module specifier
-- { defaultImport, namedImports (map name -> newImportBinding), namespaceLikeImport, useRequire }

function autoimport.newImportsKey(moduleSpecifier, topLevelTypeOnly)
    if topLevelTypeOnly then
        return "1|" .. moduleSpecifier
    end
    return "0|" .. moduleSpecifier
end

-- importAdder fields:
--   Context: ctx, checker, view, formatOptions, converters, preferences
--   State:
--     addToNamespace: Namespace fixes don't conflict, so just build a list
--     importType: JSDoc type import fixes
--     addToExisting: importClauseOrBindingPattern -> default or named bindings
--       (addToExistingOrder keeps insertion order; Go iterates the map in random order)
--     newImports: module specifier + type only -> imports (newImportsOrder keeps insertion order)
--   !!! removeExisting, verbatimImports?
local importAdder = {}
importAdder.__index = importAdder
autoimport.importAdder = importAdder

function autoimport.NewImportAdder(ctx, program, ch, file, view, formatOptions, converters, preferences)
    return setmetatable({
        ctx = ctx,
        checker = ch,
        view = view,
        formatOptions = formatOptions,
        converters = converters,
        preferences = preferences,
        addToNamespace = nil,
        importType = nil,
        addToExisting = {},
        addToExistingOrder = {},
        newImports = {},
        newImportsOrder = {},
    }, importAdder)
end

function importAdder:HasFixes()
    return core.Len(self.addToNamespace) > 0 or
        core.Len(self.importType) > 0 or
        #self.addToExistingOrder > 0 or
        #self.newImportsOrder > 0
end

-- !!! referenceImport
function importAdder:AddImportFromExportedSymbol(exportedSymbol, isValidTypeOnlyUseSite)
    local symbol = self.checker:GetMergedSymbol(self.checker:SkipAlias(exportedSymbol))
    local exportInfos = self:getAllExportsForSymbol(symbol)
    if core.Len(exportInfos) == 0 then
        -- If no exportInfo is found, this means export could not be resolved when we have filtered for autoImportFileExcludePatterns,
        --     so we should not generate an import.
        -- debug.Assert(len(adder.ls.UserPreferences().AutoImportFileExcludePatterns) > 0)
        return
    end
    local fix = self:getImportFixForSymbol(self.view, self.view.importingFile, exportInfos, isValidTypeOnlyUseSite)
    if fix ~= nil then
        -- !!! referenceImport -> propertyName
        self:AddImportFix(fix)
    end
end

function importAdder:Edits()
    -- !!! organize imports?
    local tracker = change.NewTracker(self.ctx, self.view.program:Options(), self.formatOptions, self.converters)
    local quotePreference = lsutil.GetQuotePreference(self.view.importingFile, self.preferences)
    for _, fix in ipairs(self.addToNamespace or {}) do
        autoimport.addNamespaceQualifier(fix, tracker, self.view.importingFile, locale.Default)
    end
    for _, fix in ipairs(self.importType or {}) do
        autoimport.addImportType(fix, self.view.importingFile, self.preferences, tracker, locale.Default)
    end
    for _, clauseOrPattern in ipairs(self.addToExistingOrder) do
        local entry = self.addToExisting[clauseOrPattern]
        autoimport.addToExistingImport(
            tracker,
            self.view.importingFile,
            clauseOrPattern,
            entry.defaultImport,
            autoimport.sortedNamedImports(entry.namedImports),
            self.preferences
        )
    end

    local newDeclarations = {}
    for _, key in ipairs(self.newImportsOrder) do
        local newImport = self.newImports[key]
        local moduleSpecifier = string.sub(key, 3) -- From `${0 | 1}|${moduleSpecifier}` format
        local declarations
        if newImport.useRequire then
            declarations = autoimport.getNewRequires(
                tracker,
                moduleSpecifier,
                quotePreference,
                newImport.defaultImport,
                autoimport.sortedNamedImports(newImport.namedImports),
                newImport.namespaceLikeImport,
                self.view.program:Options()
            )
        else
            declarations = autoimport.getNewImports(
                tracker,
                moduleSpecifier,
                quotePreference,
                newImport.defaultImport,
                autoimport.sortedNamedImports(newImport.namedImports),
                newImport.namespaceLikeImport,
                self.view.program:Options(),
                self.preferences
            )
        end
        for _, d in ipairs(declarations) do
            newDeclarations[#newDeclarations + 1] = d
        end
    end

    if #newDeclarations > 0 then
        autoimport.insertImports(tracker, self.view.importingFile, newDeclarations, true --[[blankLineBetween]], self.preferences)
    end

    -- Unmappable files are dropped by GetChanges, so a content-mapped importing file that cannot be
    -- faithfully rewritten yields no edits rather than a corrupting one.
    local changes = tracker:GetChanges()
    return changes[self.view.importingFile:OriginalFileName()]
end

function autoimport.sortedNamedImports(m)
    local keys = autoimport.sortedKeys(m)
    local result = {}
    for _, k in ipairs(keys) do
        result[#result + 1] = m[k]
    end
    return result
end

-- AddImportFix adds a fix to the import adder, accumulating it with other fixes
-- so that multiple imports from the same module are coalesced into a single import statement.
function importAdder:AddImportFix(fix)
    local symbolName = fix.name
    local compilerOptions = self.view.program:Options()

    local kind = fix.kind
    if kind == lsproto.AutoImportFixKind.UseNamespace then
        self.addToNamespace = self.addToNamespace or {}
        self.addToNamespace[#self.addToNamespace + 1] = fix
    elseif kind == lsproto.AutoImportFixKind.JsdocTypeImport then
        self.importType = self.importType or {}
        self.importType[#self.importType + 1] = fix
    elseif kind == lsproto.AutoImportFixKind.AddToExisting then
        local existingFix = autoimport.getAddToExistingImportFix(self.view.importingFile, fix)
        local entry = self.addToExisting[existingFix.importClauseOrBindingPattern]
        if entry == nil then
            entry = {
                importClauseOrBindingPattern = existingFix.importClauseOrBindingPattern,
                defaultImport = nil,
                namedImports = {},
            }
            self.addToExisting[existingFix.importClauseOrBindingPattern] = entry
            self.addToExistingOrder[#self.addToExistingOrder + 1] = existingFix.importClauseOrBindingPattern
        end

        if fix.importKind == lsproto.ImportKind.Named then
            local prevImport = entry.namedImports[symbolName]
            local prevTypeOnly = 0
            if prevImport ~= nil then
                prevTypeOnly = prevImport.addAsTypeOnly
            end
            entry.namedImports[symbolName] = autoimport.newImportBinding({
                kind = lsproto.ImportKind.Named,
                name = symbolName,
                addAsTypeOnly = autoimport.reduceAddAsTypeOnlyValues(prevTypeOnly, fix.addAsTypeOnly),
                propertyName = existingFix.namedImport.propertyName,
            })
        else
            -- Default import
            debug.Assert(
                entry.defaultImport == nil or entry.defaultImport.name == symbolName,
                "(Add to Existing) Default import should be missing or match symbolName"
            )
            local prevTypeOnly = 0
            if entry.defaultImport ~= nil then
                prevTypeOnly = entry.defaultImport.addAsTypeOnly
            end
            entry.defaultImport = autoimport.newImportBinding({
                kind = lsproto.ImportKind.Default,
                name = symbolName,
                addAsTypeOnly = autoimport.reduceAddAsTypeOnlyValues(prevTypeOnly, fix.addAsTypeOnly),
            })
        end
    elseif kind == lsproto.AutoImportFixKind.AddNew then
        local entry = self:getNewImportEntry(fix.moduleSpecifier, fix.importKind, fix.useRequire, fix.addAsTypeOnly)
        debug.Assert(
            entry.useRequire == fix.useRequire,
            "(Add new) Tried to add an `import` and a `require` for the same module"
        )

        local importKind = fix.importKind
        if importKind == lsproto.ImportKind.Default then
            debug.Assert(
                entry.defaultImport == nil or entry.defaultImport.name == symbolName,
                "(Add new) Default import should be missing or match symbolName"
            )
            local prevTypeOnly = 0
            if entry.defaultImport ~= nil then
                prevTypeOnly = entry.defaultImport.addAsTypeOnly
            end
            entry.defaultImport = autoimport.newImportBinding({
                kind = lsproto.ImportKind.Default,
                name = symbolName,
                addAsTypeOnly = autoimport.reduceAddAsTypeOnlyValues(prevTypeOnly, fix.addAsTypeOnly),
            })
        elseif importKind == lsproto.ImportKind.Named then
            if entry.namedImports == nil then
                entry.namedImports = {}
            end
            local prevImport = entry.namedImports[symbolName]
            local prevTypeOnly = 0
            if prevImport ~= nil then
                prevTypeOnly = prevImport.addAsTypeOnly
            end
            entry.namedImports[symbolName] = autoimport.newImportBinding({
                kind = lsproto.ImportKind.Named,
                name = symbolName,
                addAsTypeOnly = autoimport.reduceAddAsTypeOnlyValues(prevTypeOnly, fix.addAsTypeOnly),
                -- !!! propertyName
            })
        elseif importKind == lsproto.ImportKind.CommonJS then
            if compilerOptions.verbatimModuleSyntax == core.Tristate.TSTrue then
                if entry.namedImports == nil then
                    entry.namedImports = {}
                end
                local prevImport = entry.namedImports[symbolName]
                local prevTypeOnly = 0
                if prevImport ~= nil then
                    prevTypeOnly = prevImport.addAsTypeOnly
                end
                entry.namedImports[symbolName] = autoimport.newImportBinding({
                    kind = lsproto.ImportKind.CommonJS,
                    name = symbolName,
                    addAsTypeOnly = autoimport.reduceAddAsTypeOnlyValues(prevTypeOnly, fix.addAsTypeOnly),
                    -- !!! propertyName
                })
            else
                debug.Assert(
                    entry.namespaceLikeImport == nil or entry.namespaceLikeImport.name == symbolName,
                    "Namespacelike import should be missing or match symbolName"
                )
                entry.namespaceLikeImport = autoimport.newImportBinding({
                    kind = lsproto.ImportKind.CommonJS,
                    name = symbolName,
                    addAsTypeOnly = fix.addAsTypeOnly,
                })
            end
        elseif importKind == lsproto.ImportKind.Namespace then
            debug.Assert(
                entry.namespaceLikeImport == nil or entry.namespaceLikeImport.name == symbolName,
                "Namespacelike import should be missing or match symbolName"
            )
            entry.namespaceLikeImport = autoimport.newImportBinding({
                kind = lsproto.ImportKind.Namespace,
                name = symbolName,
                addAsTypeOnly = fix.addAsTypeOnly,
            })
        end
    elseif kind == lsproto.AutoImportFixKind.PromoteTypeOnly then -- luacheck: ignore 542
        -- Excluding from fix-all
    else
        debug.Fail("Unexpected fix kind: " .. tostring(fix.kind))
    end
end

-- `NotAllowed` overrides `Required` because one addition of a new import might be required to be type-only
-- because of `--importsNotUsedAsValues=error`, but if a second addition of the same import is `NotAllowed`
-- to be type-only, the reason the first one was `Required` - the unused runtime dependency - is now moot.
-- Alternatively, if one addition is `Required` because it has no value meaning under `--preserveValueImports`
-- and `--isolatedModules`, it should be impossible for another addition to be `NotAllowed` since that would
-- mean a type is being referenced in a value location.
function autoimport.reduceAddAsTypeOnlyValues(prevValue, newValue)
    if newValue > prevValue then
        return newValue
    end
    return prevValue
end

function importAdder:getNewImportEntry(moduleSpecifier, importKind, useRequire, addAsTypeOnly)
    -- A default import that requires type-only makes the whole import type-only.
    -- (We could add `default` as a named import, but that style seems undesirable.)
    -- Under `--preserveValueImports` and `--importsNotUsedAsValues=error`, if a
    -- module default-exports a type but named-exports some values (weird), you would
    -- have to use a type-only default import and non-type-only named imports. These
    -- require two separate import declarations, so we build this into the map key.
    local typeOnlyKey = autoimport.newImportsKey(moduleSpecifier, true --[[topLevelTypeOnly]])
    local nonTypeOnlyKey = autoimport.newImportsKey(moduleSpecifier, false --[[topLevelTypeOnly]])
    local typeOnlyEntry = self.newImports[typeOnlyKey]
    local nonTypeOnlyEntry = self.newImports[nonTypeOnlyKey]
    local newEntry = {
        defaultImport = nil,
        namedImports = nil,
        namespaceLikeImport = nil,
        useRequire = useRequire,
    }

    if importKind == lsproto.ImportKind.Default and addAsTypeOnly == lsproto.AddAsTypeOnly.Required then
        if typeOnlyEntry ~= nil then
            return typeOnlyEntry
        end
        self:setNewImport(typeOnlyKey, newEntry)
        return newEntry
    end

    if addAsTypeOnly == lsproto.AddAsTypeOnly.Allowed and (typeOnlyEntry ~= nil or nonTypeOnlyEntry ~= nil) then
        if typeOnlyEntry ~= nil then
            return typeOnlyEntry
        end
        return nonTypeOnlyEntry
    end

    if nonTypeOnlyEntry ~= nil then
        return nonTypeOnlyEntry
    end

    self:setNewImport(nonTypeOnlyKey, newEntry)
    return newEntry
end

-- Go `adder.newImports[key] = entry` (keeping first-insertion order).
function importAdder:setNewImport(key, entry)
    if self.newImports[key] == nil then
        self.newImportsOrder[#self.newImportsOrder + 1] = key
    end
    self.newImports[key] = entry
end

function importAdder:getAllExportsForSymbol(symbol)
    local export = autoimport.SymbolToExport(symbol, self.checker)
    if export ~= nil then
        return self.view:SearchByExportID(export:ExportID())
    end
    return nil
end

function autoimport.TypeToAutoImportableTypeNode(c, importAdder_, t, contextNode --[[ !!! flags ]])
    local idToSymbol = {}
    local typeNode = c:TypeToTypeNode(t, contextNode, nodebuilder.Flags.None, idToSymbol)
    if typeNode == nil then
        return nil
    end
    return autoimport.TypeNodeToAutoImportableTypeNode(typeNode, importAdder_, idToSymbol)
end

-- TypeNodeToAutoImportableTypeNode converts import type references in a type node to
-- simple type references and registers needed imports with the import adder.
function autoimport.TypeNodeToAutoImportableTypeNode(typeNode, importAdder_, idToSymbol)
    local referenceTypeNode, importableSymbols = autoimport.TryGetAutoImportableReferenceFromTypeNode(typeNode, idToSymbol)
    if referenceTypeNode ~= nil then
        if importAdder_ ~= nil then
            autoimport.importSymbols(importAdder_, importableSymbols)
        end
        typeNode = referenceTypeNode
    end

    -- !!! handle type node reuse: nodes needs to be fresh here but also preserve symbols
    return typeNode
end

function autoimport.importSymbols(importAdder_, symbols)
    for _, symbol in ipairs(symbols or {}) do
        importAdder_:AddImportFromExportedSymbol(symbol, true --[[isValidTypeOnlyUseSite]])
    end
end

-- Given a type node containing 'import("./a").SomeType<import("./b").OtherType<...>>',
-- returns an equivalent type reference node with any nested ImportTypeNodes also replaced
-- with type references, and a list of symbols that must be imported to use the type reference.
-- TryGetAutoImportableReferenceFromTypeNode converts import type references in a type node
-- to simple type references and returns the transformed type node and the symbols that need
-- to be imported.
-- idToSymbol maps identifier nodes to symbols (Go map[*ast.IdentifierNode]*ast.Symbol).
function autoimport.TryGetAutoImportableReferenceFromTypeNode(importTypeNode, idToSymbol)
    local symbols = nil
    local visitor
    local factory = ast.NewNodeFactory({})
    local visit = function(node)
        if ast.IsLiteralImportTypeNode(node) and node:AsImportTypeNode().qualifier ~= nil then
            local importTypeNodeData = node:AsImportTypeNode()
            -- Symbol for the left-most thing after the dot
            local firstIdentifier = ast.GetFirstIdentifier(importTypeNodeData.qualifier)
            local symbol = idToSymbol and idToSymbol[firstIdentifier]
            if symbol == nil then
                -- if symbol is missing then this doesn't come from a synthesized import type node
                -- it has to be an import type node authored by the user and thus it has to be valid
                -- it can't refer to reserved internal symbol names and such
                return node:VisitEachChild(visitor)
            end
            local name = autoimport.getNameForExportedSymbol(symbol, false --[[preferCapitalized]])
            local qualifier
            if name ~= firstIdentifier:Text() then
                qualifier = autoimport.replaceFirstIdentifierOfEntityName(factory, importTypeNodeData.qualifier, factory:NewIdentifier(name))
            else
                qualifier = importTypeNodeData.qualifier
            end
            symbols = symbols or {}
            symbols[#symbols + 1] = symbol
            local typeArguments = visitor:VisitNodes(importTypeNodeData.typeArguments)
            return factory:NewTypeReferenceNode(qualifier, typeArguments)
        end
        return visitor:VisitEachChild(node)
    end
    visitor = ast.NewNodeVisitor(visit, factory, {})

    local typeNode = visitor:VisitNode(importTypeNode)
    debug.Assert(typeNode == nil or ast.IsTypeNode(typeNode), "expected a type node")
    return typeNode, symbols
end

-- If a type checker and multiple files are available, consider using `forEachNameOfDefaultExport`
-- instead, which searches for names of re-exported defaults/namespaces in target files.
function autoimport.getNameForExportedSymbol(symbol, preferCapitalized)
    if symbol.name == ast.InternalSymbolNameExportEquals or symbol.name == ast.InternalSymbolNameDefault then
        -- Names for default exports:
        -- - export default foo => foo
        -- - export { foo as default } => foo
        -- - export default 0 => filename converted to camelCase
        local name = autoimport.getDefaultLikeExportNameFromDeclaration(symbol)
        if name ~= "" then
            return name
        end
        debug.Assert(symbol.parent ~= nil, "Expected exported symbol to have module symbol as parent")
        return lsutil.ModuleSymbolToValidIdentifier(symbol.parent, preferCapitalized)
    end
    return symbol.name
end

function autoimport.replaceFirstIdentifierOfEntityName(factory, name, newIdentifier)
    if name.kind == ast.Kind.Identifier then
        return newIdentifier
    end
    return factory:NewQualifiedName(
        autoimport.replaceFirstIdentifierOfEntityName(factory, name:AsQualifiedName().left, newIdentifier),
        name:AsQualifiedName().right
    )
end

function importAdder:getImportFixForSymbol(view, file, exports, isValidTypeOnlyUseSite)
    local fixes = core.FlatMap(exports, function(export)
        return view:GetFixes(self.ctx, export, false --[[forJSX]], isValidTypeOnlyUseSite, nil --[[usagePosition]])
    end) or {}
    core.SortFunc(fixes, function(a, b)
        return view:CompareFixesForRanking(a, b)
    end)
    if #fixes > 0 then
        return fixes[1]
    end
    return nil
end
