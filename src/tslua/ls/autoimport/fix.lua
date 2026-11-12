local autoimport = require("tslua.ls.autoimport")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local change = require("tslua.ls.change")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")
local modulespecifiers = require("tslua.modulespecifiers")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ExportSyntax = autoimport.ExportSyntax
local ResultKind = modulespecifiers.ResultKind

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function strcmp(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- newImportBinding { kind, propertyName, name, addAsTypeOnly }
function autoimport.newImportBinding(init)
    local b = {
        kind = lsproto.ImportKind.Named,
        propertyName = "",
        name = "",
        addAsTypeOnly = 0,
    }
    for k, v in pairs(init or {}) do
        b[k] = v
    end
    return b
end

-- Fix embeds *lsproto.AutoImportFix (the field autoImportFix); the embedded fields (kind, name,
-- importKind, useRequire, addAsTypeOnly, moduleSpecifier, importIndex, usagePosition,
-- namespacePrefix) are promoted: reading fix.kind reads fix.autoImportFix.kind.
-- Other fields: moduleSpecifierKind, isReExport, moduleFileName, typeOnlyAliasDeclaration.
-- Build with autoimport.NewFix({ autoImportFix = ..., ... }) or
-- setmetatable({ autoImportFix = ... }, autoimport.Fix) (Go `&autoimport.Fix{AutoImportFix: x}`).
local Fix = {}
autoimport.Fix = Fix
Fix.__index = function(self, k)
    local method = Fix[k]
    if method ~= nil then
        return method
    end
    local embedded = rawget(self, "autoImportFix")
    if embedded ~= nil then
        return embedded[k]
    end
    return nil
end

function autoimport.NewFix(init)
    local f = setmetatable({
        moduleSpecifierKind = ResultKind.None,
        isReExport = false,
        moduleFileName = "",
        typeOnlyAliasDeclaration = nil,
    }, Fix)
    for k, v in pairs(init or {}) do
        rawset(f, k, v)
    end
    return f
end

-- Go `&lsproto.AutoImportFix{...}` with zero values filled in.
function autoimport.newAutoImportFix(init)
    local f = {
        kind = lsproto.AutoImportFixKind.UseNamespace,
        name = "",
        importKind = lsproto.ImportKind.Named,
        useRequire = false,
        addAsTypeOnly = 0,
        moduleSpecifier = "",
        importIndex = 0,
        usagePosition = nil,
        namespacePrefix = "",
    }
    for k, v in pairs(init or {}) do
        f[k] = v
    end
    return lsproto.AutoImportFix(f)
end

-- addToExistingImportFix { importClauseOrBindingPattern, defaultImport, namedImport }
-- (One of `defaultImport` or `namedImports` will be present.)

local function trackerFactory(tracker)
    return tracker.nodeFactory
end

-- Edits produces the text edits and a human-readable description for the fix. The returned bool is false
-- when the fix targets a content-mapped file and any edit could not be placed within a single verbatim
-- span, meaning it cannot be safely applied to the original text and the caller should discard it.
-- Returns (edits, description, ok).
function Fix:Edits(ctx, file, compilerOptions, formatOptions, converters, preferences)
    local loc = locale.FromContext(ctx)
    local tracker = change.NewTracker(ctx, compilerOptions, formatOptions, converters)
    local kind = self.kind
    if kind == lsproto.AutoImportFixKind.UseNamespace then
        local description = autoimport.addNamespaceQualifier(self, tracker, file, loc)
        local edits, safe = autoimport.fileEdits(tracker, file)
        return edits, description, safe
    elseif kind == lsproto.AutoImportFixKind.AddToExisting then
        if core.Len(file:Imports()) <= self.importIndex then
            error("import index out of range", 0)
        end
        local existingFix = autoimport.getAddToExistingImportFix(file, self)
        autoimport.addToExistingImport(tracker, file, existingFix.importClauseOrBindingPattern, existingFix.defaultImport, core.SingleElementSlice(existingFix.namedImport), preferences)
        local edits, safe = autoimport.fileEdits(tracker, file)
        return edits, diagnostics.Update_import_from_0:Localize(loc, self.moduleSpecifier), safe
    elseif kind == lsproto.AutoImportFixKind.AddNew then
        local declarations
        local defaultImport = nil
        if self.importKind == lsproto.ImportKind.Default then
            defaultImport = autoimport.newImportBinding({ name = self.name, addAsTypeOnly = self.addAsTypeOnly })
        end
        local namedImports = nil
        if self.importKind == lsproto.ImportKind.Named then
            namedImports = { autoimport.newImportBinding({ name = self.name, addAsTypeOnly = self.addAsTypeOnly }) }
        end
        local namespaceLikeImport = nil
        -- qualification := f.qualification()
        if self.importKind == lsproto.ImportKind.Namespace or self.importKind == lsproto.ImportKind.CommonJS then
            namespaceLikeImport = autoimport.newImportBinding({ kind = self.importKind, name = self.name })
            -- if qualification != nil && qualification.namespacePref != "" {
            -- 	namespaceLikeImport.name = qualification.namespacePref
            -- }
        end

        local quotePreference = lsutil.GetQuotePreference(file, preferences)
        if self.useRequire then
            declarations = autoimport.getNewRequires(tracker, self.moduleSpecifier, quotePreference, defaultImport, namedImports, namespaceLikeImport, compilerOptions)
        else
            declarations = autoimport.getNewImports(tracker, self.moduleSpecifier, quotePreference, defaultImport, namedImports, namespaceLikeImport, compilerOptions, preferences)
        end

        autoimport.insertImports(
            tracker,
            file,
            declarations,
            true, --[[blankLineBetween]]
            preferences
        )
        -- if qualification != nil {
        -- 	addNamespaceQualifier(tracker, file, qualification)
        -- }
        local edits, safe = autoimport.fileEdits(tracker, file)
        return edits, diagnostics.Add_import_from_0:Localize(loc, self.moduleSpecifier), safe
    elseif kind == lsproto.AutoImportFixKind.PromoteTypeOnly then
        local promotedDeclaration = autoimport.promoteFromTypeOnly(tracker, self.typeOnlyAliasDeclaration, compilerOptions, file, preferences)
        if promotedDeclaration.kind == Kind.ImportSpecifier then
            local moduleSpec = autoimport.getModuleSpecifierText(promotedDeclaration.parent.parent)
            local edits, safe = autoimport.fileEdits(tracker, file)
            return edits, diagnostics.Remove_type_from_import_of_0_from_1:Localize(loc, self.name, moduleSpec), safe
        end
        local moduleSpec = autoimport.getModuleSpecifierText(promotedDeclaration)
        local edits, safe = autoimport.fileEdits(tracker, file)
        return edits, diagnostics.Remove_type_from_import_declaration_from_0:Localize(loc, moduleSpec), safe
    elseif kind == lsproto.AutoImportFixKind.JsdocTypeImport then
        local description = autoimport.addImportType(self, file, preferences, tracker, loc)
        local edits, safe = autoimport.fileEdits(tracker, file)
        return edits, description, safe
    else
        error("unimplemented fix edit", 0)
    end
end

-- fileEdits returns the edits recorded for file, along with whether they are safe to apply. GetChanges
-- drops the edits of any content-mapped file that cannot be faithfully mapped back to the original text,
-- so an empty result with safe == false means the fix could not be represented and must be discarded.
function autoimport.fileEdits(tracker, file)
    local changes, unmappable = tracker:GetChanges()
    return changes[file:OriginalFileName()], core.Len(unmappable) == 0
end

function autoimport.addImportType(f, file, preferences, tracker, loc)
    if f.usagePosition == nil then
        error("UsagePosition must be set for JSDoc type import fix", 0)
    end
    local quotePreference = lsutil.GetQuotePreference(file, preferences)
    local quoteChar = "\""
    if quotePreference == lsutil.QuotePreference.Single then
        quoteChar = "'"
    end
    local importTypePrefix = "import(" .. quoteChar .. f.moduleSpecifier .. quoteChar .. ")."
    tracker:InsertText(file, f.usagePosition, importTypePrefix)
    return diagnostics.Change_0_to_1:Localize(loc, f.name, importTypePrefix .. f.name)
end

function autoimport.addNamespaceQualifier(f, tracker, file, loc)
    if f.usagePosition == nil or f.namespacePrefix == "" then
        error("namespace fix requires usage position and prefix", 0)
    end
    local qualified = f.namespacePrefix .. "." .. f.name
    tracker:InsertText(file, f.usagePosition, f.namespacePrefix .. ".")
    return diagnostics.Change_0_to_1:Localize(loc, f.name, qualified)
end

function autoimport.getAddToExistingImportFix(file, fix)
    if fix.kind ~= lsproto.AutoImportFixKind.AddToExisting then
        error("expected add to existing import fix", 0)
    end
    local moduleSpecifier = file:Imports()[fix.importIndex + 1]
    local importNode = ast.TryGetImportFromModuleSpecifier(moduleSpecifier)
    if importNode == nil then
        error("expected import declaration", 0)
    end
    local importClauseOrBindingPattern
    if importNode.kind == Kind.ImportDeclaration then
        importClauseOrBindingPattern = importNode:ImportClause()
        if importClauseOrBindingPattern == nil then
            error("expected import clause", 0)
        end
    elseif importNode.kind == Kind.CallExpression then
        if not ast.IsVariableDeclarationInitializedToRequire(importNode.parent) then
            error("expected require call expression to be in variable declaration", 0)
        end
        importClauseOrBindingPattern = importNode.parent:Name()
        if importClauseOrBindingPattern == nil or not ast.IsObjectBindingPattern(importClauseOrBindingPattern) then
            error("expected object binding pattern in variable declaration", 0)
        end
    else
        error("expected import declaration or require call expression", 0)
    end

    local defaultImport = nil
    if fix.importKind == lsproto.ImportKind.Default then
        defaultImport = autoimport.newImportBinding({ kind = lsproto.ImportKind.Default, name = fix.name, addAsTypeOnly = fix.addAsTypeOnly })
    end
    local namedImports = nil
    if fix.importKind == lsproto.ImportKind.Named then
        namedImports = autoimport.newImportBinding({ kind = lsproto.ImportKind.Named, name = fix.name, addAsTypeOnly = fix.addAsTypeOnly })
    end
    return {
        importClauseOrBindingPattern = importClauseOrBindingPattern,
        defaultImport = defaultImport,
        namedImport = namedImports,
    }
end

function autoimport.addToExistingImport(ct, file, importClauseOrBindingPattern, defaultImport, namedImports, preferences)
    local factory = trackerFactory(ct)
    local kind = importClauseOrBindingPattern.kind
    if kind == Kind.ObjectBindingPattern then
        local bindingPattern = importClauseOrBindingPattern:AsBindingPattern()
        if defaultImport ~= nil then
            autoimport.addElementToBindingPattern(ct, file, bindingPattern, defaultImport.name, "default")
        end
        for _, namedImport in ipairs(namedImports or {}) do
            autoimport.addElementToBindingPattern(ct, file, bindingPattern, namedImport.name, "")
        end
        return
    elseif kind == Kind.ImportClause then
        local importClause = importClauseOrBindingPattern:AsImportClause()

        -- promoteFromTypeOnly = true if we need to promote the entire original clause from type only
        local candidates = {}
        for _, i in ipairs(namedImports or {}) do
            candidates[#candidates + 1] = i
        end
        local promoteFromTypeOnly = importClause:IsTypeOnly() and (core.Some(candidates, function(i)
            return i.addAsTypeOnly == lsproto.AddAsTypeOnly.NotAllowed
        end) or (defaultImport ~= nil and defaultImport.addAsTypeOnly == lsproto.AddAsTypeOnly.NotAllowed))

        local existingSpecifiers = nil
        if importClause.namedBindings ~= nil and importClause.namedBindings.kind == Kind.NamedImports then
            existingSpecifiers = importClause.namedBindings:Elements()
        end

        if defaultImport ~= nil then
            debug.Assert(importClause:Name() == nil, "Cannot add a default import to an import clause that already has one")
            ct:InsertNodeAt(file, astnav.GetStartOfNode(importClause:AsNode(), file, false), factory:NewIdentifier(defaultImport.name), autoimport.newNodeOptions({ suffix = ", " }))
        end

        if core.Len(namedImports) > 0 then
            local specifierComparer, isSorted = lsutil.GetNamedImportSpecifierComparerWithDetection(importClause.parent, file, preferences)
            local newSpecifiers = core.Map(namedImports, function(namedImport)
                local identifier = nil
                if namedImport.propertyName ~= "" then
                    identifier = factory:NewIdentifier(namedImport.propertyName)
                end
                return factory:NewImportSpecifier(
                    (not importClause:IsTypeOnly() or promoteFromTypeOnly) and autoimport.shouldUseTypeOnly(namedImport.addAsTypeOnly, preferences),
                    identifier,
                    factory:NewIdentifier(namedImport.name)
                )
            end)
            core.SortFunc(newSpecifiers, specifierComparer)
            if core.Len(existingSpecifiers) > 0 and isSorted ~= core.Tristate.TSFalse then
                -- The sorting preference computed earlier may or may not have validated that these particular
                -- import specifiers are sorted. If they aren't, `getImportSpecifierInsertionIndex` will return
                -- nonsense. So if there are existing specifiers, even if we know the sorting preference, we
                -- need to ensure that the existing specifiers are sorted according to the preference in order
                -- to do a sorted insertion.

                -- If we're promoting the clause from type-only, we need to transform the existing imports
                -- before attempting to insert the new named imports (for comparison purposes only)
                local specsToCompareAgainst = existingSpecifiers
                if promoteFromTypeOnly and core.Len(existingSpecifiers) > 0 then
                    specsToCompareAgainst = core.Map(existingSpecifiers, function(e)
                        local spec = e:AsImportSpecifier()
                        local propertyName = nil
                        if spec.propertyName ~= nil then
                            propertyName = spec.propertyName
                        end
                        local syntheticSpec = factory:NewImportSpecifier(
                            true, -- isTypeOnly
                            propertyName,
                            spec:Name()
                        )
                        return syntheticSpec
                    end)
                end

                for _, spec in ipairs(newSpecifiers) do
                    local insertionIndex = lsutil.GetImportSpecifierInsertionIndex(specsToCompareAgainst, spec, specifierComparer)
                    ct:InsertImportSpecifierAtIndex(file, spec, importClause.namedBindings, insertionIndex)
                end
            elseif core.Len(existingSpecifiers) > 0 then
                for _, spec in ipairs(newSpecifiers) do
                    ct:InsertNodeInListAfter(file, existingSpecifiers[#existingSpecifiers], spec:AsNode(), nil)
                end
            else
                if #newSpecifiers > 0 then
                    local newNamedImports = factory:NewNamedImports(factory:NewNodeList(newSpecifiers))
                    if importClause.namedBindings ~= nil then
                        ct:ReplaceNode(file, importClause.namedBindings, newNamedImports, nil)
                    else
                        if importClause:Name() == nil then
                            error("Import clause must have either named imports or a default import", 0)
                        end
                        ct:InsertNodeAfter(file, importClause:Name(), newNamedImports)
                    end
                end
            end
        end

        if promoteFromTypeOnly then
            -- Delete the 'type' keyword from the import clause
            local typeKeyword = autoimport.getTypeKeywordOfTypeOnlyImport(importClause, file)
            ct:Delete(file, typeKeyword)

            -- Add 'type' modifier to existing specifiers (not newly added ones)
            -- We preserve the type-onlyness of existing specifiers regardless of whether
            -- it would make a difference in emit (user preference).
            if core.Len(existingSpecifiers) > 0 then
                for _, specifier in ipairs(existingSpecifiers) do
                    if not specifier:AsImportSpecifier().isTypeOnly then
                        ct:InsertModifierBefore(file, Kind.TypeKeyword, specifier)
                    end
                end
            end
        end
    else
        error("Unsupported clause kind: " .. importClauseOrBindingPattern:KindString() .. " for addToExistingImport", 0)
    end
end

-- Go change.NodeOptions value struct with zero values filled in.
function autoimport.newNodeOptions(init)
    local o = {
        prefix = "",
        suffix = "",
        indentation = nil,
        delta = nil,
        leadingTriviaOption = change.LeadingTriviaOption.None,
        trailingTriviaOption = change.TrailingTriviaOption.None,
        joiner = "",
    }
    for k, v in pairs(init or {}) do
        o[k] = v
    end
    return o
end

function autoimport.getTypeKeywordOfTypeOnlyImport(importClause, sourceFile)
    debug.Assert(importClause:IsTypeOnly(), "import clause must be type-only")
    -- The first child of a type-only import clause is the 'type' keyword
    -- import type { foo } from './bar'
    --        ^^^^
    local typeKeyword = astnav.FindChildOfKind(importClause:AsNode(), Kind.TypeKeyword, sourceFile)
    debug.Assert(typeKeyword ~= nil, "type-only import clause should have a type keyword")
    return typeKeyword
end

function autoimport.addElementToBindingPattern(ct, file, bindingPattern, name, propertyName)
    local factory = trackerFactory(ct)
    local element = factory:NewBindingElement(nil, nil, factory:NewIdentifier(name), core.IfElse(propertyName == "", nil, propertyName ~= "" and factory:NewIdentifier(propertyName) or nil))
    local elements = bindingPattern.elements.nodes
    if #elements > 0 then
        ct:InsertNodeInListAfter(file, elements[#elements], element, bindingPattern.elements)
    else
        ct:ReplaceNode(file, bindingPattern:AsNode(), factory:NewBindingPattern(Kind.ObjectBindingPattern, factory:NewNodeList({ element })), nil)
    end
end

function autoimport.getNewImports(ct, moduleSpecifier, quotePreference, defaultImport, namedImports, namespaceLikeImport, compilerOptions, preferences)
    local factory = trackerFactory(ct)
    local tokenFlags = core.IfElse(quotePreference == lsutil.QuotePreference.Single, ast.TokenFlags.SingleQuote, ast.TokenFlags.None)
    local moduleSpecifierStringLiteral = factory:NewStringLiteral(moduleSpecifier, tokenFlags)
    local statements = {}
    if defaultImport ~= nil or core.Len(namedImports) > 0 then
        -- `verbatimModuleSyntax` should prefer top-level `import type` -
        -- even though it's not an error, it would add unnecessary runtime emit.
        local topLevelTypeOnly = (defaultImport == nil or autoimport.needsTypeOnly(defaultImport.addAsTypeOnly)) and
            core.Every(namedImports, function(i) return autoimport.needsTypeOnly(i.addAsTypeOnly) end) or
            (core.Tristate_IsTrue(compilerOptions.verbatimModuleSyntax) or core.Tristate_IsTrue(preferences.preferTypeOnlyAutoImports)) and
            (defaultImport == nil or defaultImport.addAsTypeOnly ~= lsproto.AddAsTypeOnly.NotAllowed) and
            not core.Some(namedImports, function(i) return i.addAsTypeOnly == lsproto.AddAsTypeOnly.NotAllowed end)

        local defaultImportNode = nil
        if defaultImport ~= nil then
            defaultImportNode = factory:NewIdentifier(defaultImport.name)
        end

        statements[#statements + 1] = autoimport.makeImport(ct, defaultImportNode, core.Map(namedImports, function(namedImport)
            local namedImportPropertyName = nil
            if namedImport.propertyName ~= "" then
                namedImportPropertyName = factory:NewIdentifier(namedImport.propertyName)
            end
            return factory:NewImportSpecifier(
                not topLevelTypeOnly and autoimport.shouldUseTypeOnly(namedImport.addAsTypeOnly, preferences),
                namedImportPropertyName,
                factory:NewIdentifier(namedImport.name)
            )
        end), moduleSpecifierStringLiteral, topLevelTypeOnly)
    end

    if namespaceLikeImport ~= nil then
        local declaration
        if namespaceLikeImport.kind == lsproto.ImportKind.CommonJS then
            declaration = factory:NewImportEqualsDeclaration(
                nil, --[[modifiers]]
                autoimport.shouldUseTypeOnly(namespaceLikeImport.addAsTypeOnly, preferences),
                factory:NewIdentifier(namespaceLikeImport.name),
                factory:NewExternalModuleReference(moduleSpecifierStringLiteral)
            )
        else
            declaration = factory:NewImportDeclaration(
                nil, --[[modifiers]]
                factory:NewImportClause(
                    core.IfElse(autoimport.shouldUseTypeOnly(namespaceLikeImport.addAsTypeOnly, preferences), Kind.TypeKeyword, Kind.Unknown), --[[phaseModifier]]
                    nil, --[[name]]
                    factory:NewNamespaceImport(factory:NewIdentifier(namespaceLikeImport.name))
                ),
                moduleSpecifierStringLiteral,
                nil --[[attributes]]
            )
        end
        statements[#statements + 1] = declaration
    end
    if #statements == 0 then
        error("No statements to insert for new imports", 0)
    end
    return statements
end

function autoimport.getNewRequires(changeTracker, moduleSpecifier, quotePreference, defaultImport, namedImports, namespaceLikeImport, compilerOptions)
    local factory = trackerFactory(changeTracker)
    local quotedModuleSpecifier = factory:NewStringLiteral(
        moduleSpecifier,
        core.IfElse(quotePreference == lsutil.QuotePreference.Single, ast.TokenFlags.SingleQuote, ast.TokenFlags.None)
    )
    local statements = nil

    -- const { default: foo, bar, etc } = require('./mod');
    if defaultImport ~= nil or core.Len(namedImports) > 0 then
        local bindingElements = {}
        for _, namedImport in ipairs(namedImports or {}) do
            local propertyName = nil
            if namedImport.propertyName ~= "" then
                propertyName = factory:NewIdentifier(namedImport.propertyName)
            end
            bindingElements[#bindingElements + 1] = factory:NewBindingElement(
                nil, --[[dotDotDotToken]]
                propertyName,
                factory:NewIdentifier(namedImport.name),
                nil --[[initializer]]
            )
        end
        if defaultImport ~= nil then
            table.insert(bindingElements, 1,
                factory:NewBindingElement(
                    nil, --[[dotDotDotToken]]
                    factory:NewIdentifier("default"),
                    factory:NewIdentifier(defaultImport.name),
                    nil --[[initializer]]
                ))
        end
        local declaration = autoimport.createConstEqualsRequireDeclaration(
            changeTracker,
            factory:NewBindingPattern(
                Kind.ObjectBindingPattern,
                factory:NewNodeList(bindingElements)
            ),
            quotedModuleSpecifier
        )
        statements = statements or {}
        statements[#statements + 1] = declaration
    end

    -- const foo = require('./mod');
    if namespaceLikeImport ~= nil then
        local declaration = autoimport.createConstEqualsRequireDeclaration(
            changeTracker,
            factory:NewIdentifier(namespaceLikeImport.name),
            quotedModuleSpecifier
        )
        statements = statements or {}
        statements[#statements + 1] = declaration
    end

    debug.Assert(statements ~= nil)
    return statements
end

function autoimport.createConstEqualsRequireDeclaration(changeTracker, name, quotedModuleSpecifier)
    local factory = trackerFactory(changeTracker)
    return factory:NewVariableStatement(
        nil, --[[modifiers]]
        factory:NewVariableDeclarationList(
            factory:NewNodeList({
                factory:NewVariableDeclaration(
                    name,
                    nil, --[[exclamationToken]]
                    nil, --[[type]]
                    factory:NewCallExpression(
                        factory:NewIdentifier("require"),
                        nil, --[[questionDotToken]]
                        nil, --[[typeArguments]]
                        factory:NewNodeList({ quotedModuleSpecifier }),
                        ast.NodeFlags.None
                    )
                ),
            }),
            ast.NodeFlags.Const
        )
    )
end

function autoimport.insertImports(ct, sourceFile, imports, blankLineBetween, preferences)
    local existingImportStatements

    if imports[1].kind == Kind.VariableStatement then
        existingImportStatements = core.Filter(sourceFile.statements.nodes, ast.IsRequireVariableStatement)
    else
        existingImportStatements = core.Filter(sourceFile.statements.nodes, ast.IsAnyImportSyntax)
    end
    existingImportStatements = existingImportStatements or {}
    local comparer, isSorted = lsutil.GetOrganizeImportsStringComparerWithDetection(existingImportStatements, preferences)
    local sortedNewImports = {}
    for i, imp in ipairs(imports) do
        sortedNewImports[i] = imp
    end
    core.SortFunc(sortedNewImports, function(a, b)
        return lsutil.CompareImportsOrRequireStatements(a, b, comparer)
    end)

    if #existingImportStatements > 0 and isSorted then
        -- Existing imports are sorted, insert each new import at the correct position
        for _, newImport in ipairs(sortedNewImports) do
            local insertionIndex = lsutil.GetImportDeclarationInsertIndex(existingImportStatements, newImport, function(a, b)
                return lsutil.CompareImportsOrRequireStatements(a, b, comparer)
            end)
            if insertionIndex == 0 then
                -- If the first import is top-of-file, insert after the leading comment which is likely the header.
                local leadingTriviaOption = change.LeadingTriviaOption.None
                if existingImportStatements[1] == sourceFile.statements.nodes[1] then
                    leadingTriviaOption = change.LeadingTriviaOption.Exclude
                end
                ct:InsertNodeBefore(sourceFile, existingImportStatements[1]:AsNode(), newImport:AsNode(), false --[[blankLineBetween]], leadingTriviaOption)
            else
                local prevImport = existingImportStatements[insertionIndex]
                ct:InsertNodeAfter(sourceFile, prevImport:AsNode(), newImport:AsNode())
            end
        end
    elseif #existingImportStatements > 0 then
        ct:InsertNodesAfter(sourceFile, existingImportStatements[#existingImportStatements], sortedNewImports)
    else
        ct:InsertAtTopOfFile(sourceFile, sortedNewImports, blankLineBetween)
    end
end

function autoimport.makeImport(ct, defaultImport, namedImports, moduleSpecifier, isTypeOnly)
    local factory = trackerFactory(ct)
    local newNamedImports = nil
    if core.Len(namedImports) > 0 then
        newNamedImports = factory:NewNamedImports(factory:NewNodeList(namedImports))
    end
    local importClause = nil
    if defaultImport ~= nil or newNamedImports ~= nil then
        importClause = factory:NewImportClause(core.IfElse(isTypeOnly, Kind.TypeKeyword, Kind.Unknown), defaultImport, newNamedImports)
    end
    return factory:NewImportDeclaration(nil --[[modifiers]], importClause, moduleSpecifier, nil --[[attributes]])
end

local View = autoimport.View

-- usagePosition is an lsproto.Position or nil.
function View:GetFixes(ctx, export, forJSX, isValidTypeOnlyUseSite, usagePosition)
    local fixes = nil
    local namespaceFix = self:tryUseExistingNamespaceImport(ctx, export, usagePosition)
    if namespaceFix ~= nil then
        fixes = { namespaceFix }
    end

    local fix = self:tryAddToExistingImport(ctx, export, isValidTypeOnlyUseSite)
    if fix ~= nil then
        fixes = fixes or {}
        fixes[#fixes + 1] = fix
        return fixes
    end

    -- !!! getNewImportFromExistingSpecifier - even worth it?

    local moduleSpecifier, moduleSpecifierKind = self:GetModuleSpecifier(export, self.preferences)
    if moduleSpecifier == "" then
        if core.Len(fixes) > 0 then
            return fixes
        end
        return nil
    end

    -- Check if we need a JSDoc import type fix (for JS files with type-only imports)
    local isJs = tspath.HasJSFileExtension(self.importingFile:FileName())
    local importedSymbolHasValueMeaning = export.flags & SymbolFlags.Value ~= 0 or export:IsUnresolvedAlias()
    if not importedSymbolHasValueMeaning and isJs and usagePosition ~= nil then
        -- For pure types in JS files, use JSDoc import type syntax
        return {
            autoimport.NewFix({
                autoImportFix = autoimport.newAutoImportFix({
                    kind = lsproto.AutoImportFixKind.JsdocTypeImport,
                    moduleSpecifier = moduleSpecifier,
                    name = export:Name(),
                    usagePosition = usagePosition,
                }),
                moduleSpecifierKind = moduleSpecifierKind,
                isReExport = export.target.moduleID ~= export.moduleID,
                moduleFileName = export.moduleFileName,
            }),
        }
    end

    local importKind = autoimport.getImportKind(self.importingFile, export, self.program, false --[[forceImportKeyword]])
    local addAsTypeOnly = autoimport.getAddAsTypeOnly(isValidTypeOnlyUseSite, export, self.program:Options())

    local name = export:Name()
    local startsWithUpper = stringutil.UnicodeIsUpper(string.byte(name, 1))
    if forJSX and not startsWithUpper then
        if export:IsRenameable() then
            name = stringutil.EncodeRune(stringutil.UnicodeToUpper(string.byte(name, 1))) .. string.sub(name, 2)
        else
            return nil
        end
    end

    fixes = fixes or {}
    fixes[#fixes + 1] = autoimport.NewFix({
        autoImportFix = autoimport.newAutoImportFix({
            kind = lsproto.AutoImportFixKind.AddNew,
            importKind = importKind,
            moduleSpecifier = moduleSpecifier,
            name = name,
            useRequire = self:shouldUseRequire(),
            addAsTypeOnly = addAsTypeOnly,
        }),
        moduleSpecifierKind = moduleSpecifierKind,
        isReExport = export.target.moduleID ~= export.moduleID,
        moduleFileName = export.moduleFileName,
    })
    return fixes
end

-- getAddAsTypeOnly determines if an import should be type-only based on usage context
function autoimport.getAddAsTypeOnly(isValidTypeOnlyUseSite, export, compilerOptions)
    if not isValidTypeOnlyUseSite then
        -- Can't use a type-only import if the usage is an emitting position
        return lsproto.AddAsTypeOnly.NotAllowed
    end
    if core.Tristate_IsTrue(compilerOptions.verbatimModuleSyntax) and (export.isTypeOnly or export.flags & SymbolFlags.Value == 0) or
        export.isTypeOnly and export.flags & SymbolFlags.Value ~= 0 then
        -- A type-only import is required for this symbol if under verbatimModuleSyntax and it's purely a type
        return lsproto.AddAsTypeOnly.Required
    end
    return lsproto.AddAsTypeOnly.Allowed
end

function View:tryUseExistingNamespaceImport(ctx, export, usagePosition)
    if usagePosition == nil then
        return nil
    end

    if autoimport.getImportKind(self.importingFile, export, self.program, false --[[forceImportKeyword]]) ~= lsproto.ImportKind.Named then
        return nil
    end

    local existingImports = self:getExistingImports(ctx)
    local matchingDeclarations = existingImports:Get(export.moduleID)
    for _, existingImport in ipairs(matchingDeclarations or {}) do
        local namespacePrefix = autoimport.getNamespaceLikeImportText(existingImport.node)
        if namespacePrefix == "" or existingImport.moduleSpecifier == "" then
            goto continue
        end
        do
            return autoimport.NewFix({
                autoImportFix = autoimport.newAutoImportFix({
                    kind = lsproto.AutoImportFixKind.UseNamespace,
                    name = export:Name(),
                    moduleSpecifier = existingImport.moduleSpecifier,
                    importKind = lsproto.ImportKind.Namespace,
                    addAsTypeOnly = lsproto.AddAsTypeOnly.Allowed,
                    importIndex = existingImport.index,
                    usagePosition = usagePosition,
                    namespacePrefix = namespacePrefix,
                }),
            })
        end
        ::continue::
    end

    return nil
end

function autoimport.getNamespaceLikeImportText(declaration)
    local kind = declaration.kind
    if kind == Kind.VariableDeclaration then
        local name = declaration:Name()
        if name ~= nil and name.kind == Kind.Identifier then
            return name:Text()
        end
        return ""
    elseif kind == Kind.ImportEqualsDeclaration then
        return declaration:Name():Text()
    elseif kind == Kind.JSDocImportTag or kind == Kind.ImportDeclaration then
        local importClause = declaration:ImportClause()
        if importClause ~= nil and importClause:AsImportClause().namedBindings ~= nil and importClause:AsImportClause().namedBindings.kind == Kind.NamespaceImport then
            return importClause:AsImportClause().namedBindings:Name():Text()
        end
        return ""
    else
        return ""
    end
end

function View:tryAddToExistingImport(ctx, export, isValidTypeOnlyUseSite)
    local existingImports = self:getExistingImports(ctx)
    local matchingDeclarations = existingImports:Get(export.moduleID)
    if core.Len(matchingDeclarations) == 0 then
        return nil
    end

    -- Can't use an es6 import for a type in JS.
    if ast.IsSourceFileJS(self.importingFile) and export.flags & SymbolFlags.Value == 0 and not core.Every(matchingDeclarations, function(i)
        return ast.IsJSDocImportTag(i.node)
    end) then
        return nil
    end

    local importKind = autoimport.getImportKind(self.importingFile, export, self.program, false --[[forceImportKeyword]])
    if importKind == lsproto.ImportKind.CommonJS or importKind == lsproto.ImportKind.Namespace then
        return nil
    end

    local addAsTypeOnly = autoimport.getAddAsTypeOnly(isValidTypeOnlyUseSite, export, self.program:Options())

    local best = nil
    for _, existingImport in ipairs(matchingDeclarations) do
        if existingImport.node.kind == Kind.ImportEqualsDeclaration then
            goto continue
        end

        if existingImport.node.kind == Kind.VariableDeclaration then
            if (importKind == lsproto.ImportKind.Named or importKind == lsproto.ImportKind.Default) and existingImport.node:Name().kind == Kind.ObjectBindingPattern then
                local fix = autoimport.NewFix({
                    autoImportFix = autoimport.newAutoImportFix({
                        kind = lsproto.AutoImportFixKind.AddToExisting,
                        name = export:Name(),
                        importKind = importKind,
                        importIndex = existingImport.index,
                        moduleSpecifier = existingImport.moduleSpecifier,
                        addAsTypeOnly = addAsTypeOnly,
                    }),
                })
                -- Variable declarations are never type-only.
                -- Give preference to putting types in existing type-only imports and avoiding conversions
                -- of import statements to/from type-only.
                if addAsTypeOnly == lsproto.AddAsTypeOnly.NotAllowed then
                    return fix
                end
                if best == nil then
                    best = fix
                end
            end
            goto continue
        end

        do
            local importClauseNode = existingImport.node:ImportClause()
            if importClauseNode == nil or not ast.IsStringLiteralLike(existingImport.node:ModuleSpecifier()) then
                -- Side-effect import (no import clause) - can't add to it
                goto continue
            end
            local importClause = importClauseNode:AsImportClause()

            local namedBindings = importClause.namedBindings
            -- A type-only import may not have both a default and named imports, so the only way a name can
            -- be added to an existing type-only import is adding a named import to existing named bindings.
            if importClause:IsTypeOnly() and not (importKind == lsproto.ImportKind.Named and namedBindings ~= nil) then
                goto continue
            end

            if importKind == lsproto.ImportKind.Default and (importClause:Name() ~= nil or
                -- Cannot add a default import as type-only if the import already has named bindings
                addAsTypeOnly == lsproto.AddAsTypeOnly.Required and namedBindings ~= nil) then
                goto continue
            end

            -- Cannot add a named import to a declaration that has a namespace import
            if importKind == lsproto.ImportKind.Named and namedBindings ~= nil and namedBindings.kind == Kind.NamespaceImport then
                goto continue
            end

            local fix = autoimport.NewFix({
                autoImportFix = autoimport.newAutoImportFix({
                    kind = lsproto.AutoImportFixKind.AddToExisting,
                    name = export:Name(),
                    importKind = importKind,
                    importIndex = existingImport.index,
                    moduleSpecifier = existingImport.moduleSpecifier,
                    addAsTypeOnly = addAsTypeOnly,
                }),
            })

            local isTypeOnly = importClause:IsTypeOnly()
            -- Give preference to putting types in existing type-only imports and avoiding conversions
            -- of import statements to/from type-only.
            if (addAsTypeOnly ~= lsproto.AddAsTypeOnly.NotAllowed and isTypeOnly) or
                (addAsTypeOnly == lsproto.AddAsTypeOnly.NotAllowed and not isTypeOnly) then
                return fix
            end
            if best == nil then
                best = fix
            end
        end
        ::continue::
    end

    return best
end

function autoimport.GetImportKindForImportStatement(importingFile, export, program)
    return autoimport.getImportKind(importingFile, export, program, true --[[forceImportKeyword]])
end

function autoimport.getImportKind(importingFile, export, program, forceImportKeyword)
    if core.Tristate_IsTrue(program:Options().verbatimModuleSyntax) and program:GetEmitModuleFormatOfFile(importingFile) == core.ModuleKind.CommonJS then
        return lsproto.ImportKind.CommonJS
    end
    local syntax = export.syntax
    if syntax == ExportSyntax.DefaultModifier or syntax == ExportSyntax.DefaultDeclaration then
        return lsproto.ImportKind.Default
    elseif syntax == ExportSyntax.Named or syntax == ExportSyntax.Modifier or syntax == ExportSyntax.Star or syntax == ExportSyntax.CommonJSExportsProperty then
        if syntax == ExportSyntax.Named and export.exportName == ast.InternalSymbolNameDefault then
            return lsproto.ImportKind.Default
        end
        return lsproto.ImportKind.Named
    elseif syntax == ExportSyntax.Equals or syntax == ExportSyntax.CommonJSModuleExports or syntax == ExportSyntax.UMD then
        -- export.Syntax will be ExportSyntaxEquals for named exports/properties of an export='s target.
        if export.exportName ~= ast.InternalSymbolNameExportEquals then
            return lsproto.ImportKind.Named
        end
        -- !!! cache this?
        for _, statement in ipairs(importingFile.statements.nodes) do
            -- `import foo` parses as an ImportEqualsDeclaration even though it could be an ImportDeclaration
            if ast.IsImportEqualsDeclaration(statement) and not ast.NodeIsMissing(statement:AsImportEqualsDeclaration().moduleReference) then
                return lsproto.ImportKind.CommonJS
            end
        end
        -- !!! this logic feels weird; we're basically trying to predict if shouldUseRequire is going to
        --     be true. The meaning of "default import" is different depending on whether we write it as
        --     a require or an es6 import. The latter, compiled to CJS, has interop built in that will
        --     avoid accessing .default, but if we write a require directly and call it a default import,
        --     we emit an unconditional .default access.
        if importingFile.externalModuleIndicator ~= nil or forceImportKeyword or not ast.IsSourceFileJS(importingFile) then
            return lsproto.ImportKind.Default
        end
        return lsproto.ImportKind.CommonJS
    else
        error("unhandled export syntax kind: " .. autoimport.ExportSyntax_String(export.syntax), 0)
    end
end

-- existingImport { node, moduleSpecifier, index }

function View:getExistingImports(ctx)
    if self.existingImports ~= nil then
        return self.existingImports
    end

    local result = collections.NewMultiMapWithSizeHint(core.Len(self.importingFile:Imports()))
    local ch, done = self.program:GetTypeChecker(ctx)

    for i1, moduleSpecifier in ipairs(self.importingFile:Imports() or {}) do
        local i = i1 - 1
        local node = ast.TryGetImportFromModuleSpecifier(moduleSpecifier)
        if node == nil then
            if done ~= nil then
                done()
            end
            error("error: did not expect node kind " .. ast.Kind_String(moduleSpecifier.kind), 0)
        elseif ast.IsVariableDeclarationInitializedToRequire(node.parent) then
            local moduleSymbol = ch:ResolveExternalModuleName(moduleSpecifier)
            if moduleSymbol ~= nil then
                local moduleID, _, ok = autoimport.tryGetModuleIDAndFileNameOfModuleSymbol(moduleSymbol)
                if ok then
                    result:Add(moduleID, { node = node.parent, moduleSpecifier = moduleSpecifier:Text(), index = i })
                end
            end
        elseif node.kind == Kind.ImportDeclaration or node.kind == Kind.ImportEqualsDeclaration or node.kind == Kind.JSDocImportTag then
            local moduleSymbol = ch:GetSymbolAtLocation(moduleSpecifier)
            if moduleSymbol ~= nil then
                local moduleID, _, ok = autoimport.tryGetModuleIDAndFileNameOfModuleSymbol(moduleSymbol)
                if ok then
                    result:Add(moduleID, { node = node, moduleSpecifier = moduleSpecifier:Text(), index = i })
                end
            end
        end
    end
    if done ~= nil then
        done()
    end
    self.existingImports = result
    return result
end

function View:shouldUseRequire()
    if self.shouldUseRequireForFixes ~= nil then
        return self.shouldUseRequireForFixes
    end
    local shouldUseRequire = self:computeShouldUseRequire()
    self.shouldUseRequireForFixes = shouldUseRequire
    return shouldUseRequire
end

-- fileSyntaxKind represents the detected module syntax of a source file.
-- (Unexported Go enum; iota values.)
autoimport.fileSyntaxKind = {
    Ambiguous = 0,
    ESM = 1,
    CJS = 2,
}
local fileSyntaxKind = autoimport.fileSyntaxKind

-- detectSyntax returns whether a source file has unambiguous ESM or CJS syntax.
-- When moduleDetection is "force", ExternalModuleIndicator may be set to the
-- source file node itself rather than a genuine syntax indicator, so we fall back
-- to inspecting the file's Imports() to find actual import/export declarations.
function autoimport.detectSyntax(file, options)
    local hasESM, hasCJS = autoimport.detectSyntaxIndicators(file, options)
    if hasCJS and not hasESM then
        return fileSyntaxKind.CJS
    elseif hasESM and not hasCJS then
        return fileSyntaxKind.ESM
    else
        return fileSyntaxKind.Ambiguous
    end
end

-- detectSyntaxIndicators checks whether a source file contains genuine ESM
-- and/or CJS syntax. Under moduleDetection "force", the cached
-- ExternalModuleIndicator may be the source file itself rather than a real
-- statement, so we look at Imports() for actual import/export declarations.
-- Returns (hasESM, hasCJS).
function autoimport.detectSyntaxIndicators(file, options)
    local hasESM = false
    local hasCJS = file.commonJSModuleIndicator ~= nil
    if options:GetEmitModuleDetectionKind() ~= core.ModuleDetectionKind.Force then
        -- ExternalModuleIndicator is reliable when moduleDetection is not "force"
        hasESM = file.externalModuleIndicator ~= nil
        return hasESM, hasCJS
    end
    -- Under moduleDetection "force", ExternalModuleIndicator is set to
    -- file.AsNode() when there is no genuine ESM syntax, so only trust it
    -- when it points to a real statement node.
    if file.externalModuleIndicator ~= nil and file.externalModuleIndicator ~= file:AsNode() then
        return true, hasCJS
    end
    -- Fall back to scanning Imports() for actual import/export declarations
    -- (not require() calls or dynamic imports).
    for _, imp in ipairs(file:Imports() or {}) do
        if imp.flags & ast.NodeFlags.Synthesized ~= 0 then
            goto continue
        end
        do
            local parent = imp.parent
            if parent == nil then
                goto continue
            end
            local k = parent.kind
            if k == Kind.ImportDeclaration or k == Kind.JSImportDeclaration or k == Kind.ExportDeclaration then
                return true, hasCJS
            elseif k == Kind.ExternalModuleReference then
                -- import x = require("...") — this is ESM-ish syntax
                return true, hasCJS
            end
        end
        ::continue::
    end
    return hasESM, hasCJS
end

function View:computeShouldUseRequire()
    -- 1. TypeScript files don't use require variable declarations
    if not tspath.HasJSFileExtension(self.importingFile:FileName()) then
        return false
    end

    -- 2. If the current source file is unambiguously CJS or ESM, go with that
    local syntax = autoimport.detectSyntax(self.importingFile, self.program:Options())
    if syntax == fileSyntaxKind.CJS then
        return true
    elseif syntax == fileSyntaxKind.ESM then
        return false
    end

    -- 3. Use the implied node format to determine CJS vs ESM
    --    TODO: consider removing `impliedNodeFormatForEmit`
    local format = self.program:GetImpliedNodeFormatForEmit(self.importingFile)
    if format == core.ModuleKind.CommonJS then
        return true
    elseif format == core.ModuleKind.ESNext then
        return false
    end

    -- 4. If there's a tsconfig/jsconfig, use its module setting
    if self.program:Options().configFilePath ~= "" then
        return self.program:Options():GetEmitModuleKind() < core.ModuleKind.ES2015
    end

    -- 5. Match the first other JS file in the program that's unambiguously CJS or ESM
    for _, otherFile in ipairs(self.program:GetSourceFiles()) do
        if otherFile == self.importingFile or not ast.IsSourceFileJS(otherFile) or self.program:IsSourceFileFromExternalLibrary(otherFile) then
            goto continue
        end
        do
            local otherSyntax = autoimport.detectSyntax(otherFile, self.program:Options())
            if otherSyntax == fileSyntaxKind.CJS then
                return true
            elseif otherSyntax == fileSyntaxKind.ESM then
                return false
            end
        end
        ::continue::
    end

    -- 6. Literally nothing to go on
    return true
end

function autoimport.needsTypeOnly(addAsTypeOnly)
    return addAsTypeOnly == lsproto.AddAsTypeOnly.Required
end

function autoimport.shouldUseTypeOnly(addAsTypeOnly, preferences)
    return autoimport.needsTypeOnly(addAsTypeOnly) or addAsTypeOnly ~= lsproto.AddAsTypeOnly.NotAllowed and core.Tristate_IsTrue(preferences.preferTypeOnlyAutoImports)
end

-- CompareFixesForSorting returns negative if `a` is better than `b`.
-- Sorting with this comparator will place the best fix first.
-- After rank sorting, fixes will be sorted by arbitrary but stable criteria
-- to ensure a deterministic order.
function View:CompareFixesForSorting(a, b)
    local res = self:CompareFixesForRanking(a, b)
    if res ~= 0 then
        return res
    end
    return self:compareModuleSpecifiersForSorting(a, b)
end

-- CompareFixesForRanking returns negative if `a` is better than `b`.
-- Sorting with this comparator will place the best fix first.
-- Fixes of equal desirability will be considered equal.
function View:CompareFixesForRanking(a, b)
    local res = autoimport.compareFixKinds(a.kind, b.kind)
    if res ~= 0 then
        return res
    end
    return self:compareModuleSpecifiersForRanking(a, b)
end

function autoimport.compareFixKinds(a, b)
    return a - b
end

function View:compareModuleSpecifiersForRanking(a, b)
    local comparison = autoimport.compareModuleSpecifierRelativity(a, b, self.preferences)
    if comparison ~= 0 then
        return comparison
    end
    if a.moduleSpecifierKind == ResultKind.Ambient and b.moduleSpecifierKind == ResultKind.Ambient then
        comparison = self:compareNodeCoreModuleSpecifiers(a.moduleSpecifier, b.moduleSpecifier, self.importingFile, self.program)
        if comparison ~= 0 then
            return comparison
        end
    end
    if a.moduleSpecifierKind == ResultKind.Relative and b.moduleSpecifierKind == ResultKind.Relative then
        comparison = core.CompareBooleans(
            autoimport.isFixPossiblyReExportingImportingFile(a, self.importingFile:FileName()),
            autoimport.isFixPossiblyReExportingImportingFile(b, self.importingFile:FileName())
        )
        if comparison ~= 0 then
            return comparison
        end
    end
    comparison = tspath.CompareNumberOfDirectorySeparators(a.moduleSpecifier, b.moduleSpecifier)
    if comparison ~= 0 then
        return comparison
    end
    return 0
end

function View:compareModuleSpecifiersForSorting(a, b)
    local res = self:compareModuleSpecifiersForRanking(a, b)
    if res ~= 0 then
        return res
    end
    -- Sort ./foo before ../foo for equal-length specifiers
    if hasPrefix(a.moduleSpecifier, "./") and not hasPrefix(b.moduleSpecifier, "./") then
        return -1
    end
    if hasPrefix(b.moduleSpecifier, "./") and not hasPrefix(a.moduleSpecifier, "./") then
        return 1
    end
    local comparison = strcmp(a.moduleSpecifier, b.moduleSpecifier)
    if comparison ~= 0 then
        return comparison
    end
    comparison = strcmp(a.importKind, b.importKind)
    if comparison ~= 0 then
        return comparison
    end
    -- !!! further tie-breakers? In practice this is only called on fixes with the same name
    return 0
end

function View:compareNodeCoreModuleSpecifiers(a, b, importingFile, program)
    if hasPrefix(a, "node:") and not hasPrefix(b, "node:") then
        if core.Tristate_IsTrue(self.shouldUseUriStyleNodeCoreModules) then
            return -1
        elseif core.Tristate_IsFalse(self.shouldUseUriStyleNodeCoreModules) then
            return 1
        end
        return 0
    end
    if hasPrefix(b, "node:") and not hasPrefix(a, "node:") then
        if core.Tristate_IsTrue(self.shouldUseUriStyleNodeCoreModules) then
            return 1
        elseif core.Tristate_IsFalse(self.shouldUseUriStyleNodeCoreModules) then
            return -1
        end
    end
    return 0
end

-- This is a simple heuristic to try to avoid creating an import cycle with a barrel re-export.
-- E.g., do not `import { Foo } from ".."` when you could `import { Foo } from "../Foo"`.
-- This can produce false positives or negatives if re-exports cross into sibling directories
-- (e.g. `export * from "../whatever"`) or are not named "index". Technically this should do
-- a tspath.Path comparison, but it's not worth it to run a heuristic in such a hot path.
function autoimport.isFixPossiblyReExportingImportingFile(fix, importingFileName)
    if fix.isReExport and autoimport.isIndexFileName(fix.moduleFileName) then
        local reExportDir = tspath.GetDirectoryPath(fix.moduleFileName)
        return hasPrefix(importingFileName, reExportDir)
    end
    return false
end

function autoimport.isIndexFileName(fileName)
    local lastSlash = -1
    for i = #fileName, 1, -1 do
        if string.byte(fileName, i) == 0x2F then
            lastSlash = i - 1
            break
        end
    end
    if lastSlash < 0 or #fileName <= lastSlash + 1 then
        return false
    end
    fileName = string.sub(fileName, lastSlash + 2)
    if fileName == "index.js" or fileName == "index.jsx" or fileName == "index.d.ts" or fileName == "index.ts" or fileName == "index.tsx" then
        return true
    end
    return false
end

function autoimport.promoteFromTypeOnly(changes, aliasDeclaration, compilerOptions, sourceFile, preferences)
    local factory = trackerFactory(changes)
    -- See comment in `doAddExistingFix` on constant with the same name.
    local convertExistingToTypeOnly = compilerOptions.verbatimModuleSyntax

    local kind = aliasDeclaration.kind
    if kind == Kind.ImportSpecifier then
        local spec = aliasDeclaration:AsImportSpecifier()
        if spec.isTypeOnly then
            if spec.parent ~= nil and spec.parent.kind == Kind.NamedImports then
                local namedImportsNode = spec.parent:AsNamedImports()
                local elements = namedImportsNode.elements.nodes
                if #elements > 1 then
                    -- Create a synthetic specifier with isTypeOnly=false to compute sorted position
                    local propertyName = nil
                    if spec.propertyName ~= nil then
                        propertyName = factory:NewIdentifier(spec.propertyName:Text())
                    end
                    local newSpecifier = factory:NewImportSpecifier(
                        false, -- isTypeOnly = false
                        propertyName,
                        factory:NewIdentifier(spec:Name():Text())
                    )
                    local specifierComparer = lsutil.GetNamedImportSpecifierComparerWithDetection(
                        spec.parent.parent.parent, -- ImportDeclaration
                        sourceFile,
                        preferences
                    )
                    local insertionIndex = lsutil.GetImportSpecifierInsertionIndex(elements, newSpecifier, specifierComparer)
                    local currentIndex = -1
                    for i, el in ipairs(elements) do
                        if el == aliasDeclaration then
                            currentIndex = i - 1
                            break
                        end
                    end
                    if insertionIndex ~= currentIndex then
                        changes:Delete(sourceFile, aliasDeclaration)
                        changes:InsertImportSpecifierAtIndex(sourceFile, newSpecifier, spec.parent, insertionIndex)
                        return aliasDeclaration
                    end
                end
                -- If no re-sorting needed, just remove the 'type' keyword
                local firstToken = lsutil.GetFirstToken(aliasDeclaration, sourceFile)
                local typeKeywordPos = scanner.GetTokenPosOfNode(firstToken, sourceFile, false)
                local targetNode
                if spec.propertyName ~= nil then
                    targetNode = spec.propertyName
                else
                    targetNode = spec:Name()
                end
                local targetPos = scanner.GetTokenPosOfNode(targetNode:AsNode(), sourceFile, false)
                changes:DeleteRange(sourceFile, core.NewTextRange(typeKeywordPos, targetPos))
            end
            return aliasDeclaration
        else
            -- The parent import clause is type-only
            if spec.parent == nil or spec.parent.kind ~= Kind.NamedImports then
                error("ImportSpecifier parent must be NamedImports", 0)
            end
            if spec.parent.parent == nil or spec.parent.parent.kind ~= Kind.ImportClause then
                error("NamedImports parent must be ImportClause", 0)
            end
            autoimport.promoteImportClause(changes, spec.parent.parent:AsImportClause(), compilerOptions, sourceFile, preferences, convertExistingToTypeOnly, aliasDeclaration)
            return spec.parent.parent
        end
    elseif kind == Kind.ImportClause then
        autoimport.promoteImportClause(changes, aliasDeclaration:AsImportClause(), compilerOptions, sourceFile, preferences, convertExistingToTypeOnly, aliasDeclaration)
        return aliasDeclaration
    elseif kind == Kind.NamespaceImport then
        -- Promote the parent import clause
        if aliasDeclaration.parent == nil or aliasDeclaration.parent.kind ~= Kind.ImportClause then
            error("NamespaceImport parent must be ImportClause", 0)
        end
        autoimport.promoteImportClause(changes, aliasDeclaration.parent:AsImportClause(), compilerOptions, sourceFile, preferences, convertExistingToTypeOnly, aliasDeclaration)
        return aliasDeclaration.parent
    elseif kind == Kind.ImportEqualsDeclaration then
        -- Remove the 'type' keyword (which is the second token: 'import' 'type' name '=' ...)
        local importEqDecl = aliasDeclaration:AsImportEqualsDeclaration()
        -- The type keyword is after 'import' and before the name
        local scan = scanner.GetScannerForSourceFile(sourceFile, importEqDecl:Pos())
        -- Skip 'import' keyword to get to 'type'
        scan:Scan()
        autoimport.deleteTypeKeyword(changes, sourceFile, scan:TokenStart())
        return aliasDeclaration
    else
        error("Unexpected alias declaration kind: " .. ast.Kind_String(aliasDeclaration.kind), 0)
    end
end

-- promoteImportClause removes the type keyword from an import clause
function autoimport.promoteImportClause(changes, importClause, compilerOptions, sourceFile, preferences, convertExistingToTypeOnly, aliasDeclaration)
    -- Delete the 'type' keyword
    if importClause.phaseModifier == Kind.TypeKeyword then
        autoimport.deleteTypeKeyword(changes, sourceFile, importClause:Pos())
    end

    -- Handle .ts extension conversion to .js if necessary
    if core.Tristate_IsFalse(compilerOptions.allowImportingTsExtensions) then
        local moduleSpecifier = checker.TryGetModuleSpecifierFromDeclaration(importClause.parent)
        if moduleSpecifier ~= nil then -- luacheck: ignore 542
            -- Note: We can't check ResolvedUsingTsExtension without program, so we'll skip this optimization
            -- The fix will still work, just might not change .ts to .js extensions in all cases
        end
    end

    -- Handle verbatimModuleSyntax conversion
    -- If convertExistingToTypeOnly is true, we need to add 'type' to other specifiers
    -- in the same import declaration
    if core.Tristate_IsTrue(convertExistingToTypeOnly) then
        local namedImports = importClause.namedBindings
        if namedImports ~= nil and namedImports.kind == Kind.NamedImports then
            local namedImportsData = namedImports:AsNamedImports()
            if #namedImportsData.elements.nodes > 1 then
                -- Check if the list is sorted and if we need to reorder
                local _, isSorted = lsutil.GetNamedImportSpecifierComparerWithDetection(
                    importClause.parent,
                    sourceFile,
                    preferences
                )

                -- If the alias declaration is an ImportSpecifier and the list is sorted,
                -- move it to index 0 (since it will be the only non-type-only import)
                if core.Tristate_IsFalse(isSorted) == false and -- isSorted !== false
                    aliasDeclaration ~= nil and
                    aliasDeclaration.kind == Kind.ImportSpecifier then
                    -- Find the index of the alias declaration
                    local aliasIndex = -1
                    for i, element in ipairs(namedImportsData.elements.nodes) do
                        if element == aliasDeclaration then
                            aliasIndex = i - 1
                            break
                        end
                    end
                    -- If not already at index 0, move it there
                    if aliasIndex > 0 then
                        -- Delete the specifier from its current position
                        changes:Delete(sourceFile, aliasDeclaration)
                        -- Insert it at index 0
                        changes:InsertImportSpecifierAtIndex(sourceFile, aliasDeclaration, namedImports, 0)
                    end
                end

                -- Add 'type' keyword to all other import specifiers that aren't already type-only
                for _, element in ipairs(namedImportsData.elements.nodes) do
                    local spec = element:AsImportSpecifier()
                    -- Skip the specifier being promoted (if aliasDeclaration is an ImportSpecifier)
                    if aliasDeclaration ~= nil and aliasDeclaration.kind == Kind.ImportSpecifier and element == aliasDeclaration then
                        goto continue
                    end
                    -- Skip if already type-only
                    if not spec.isTypeOnly then
                        changes:InsertModifierBefore(sourceFile, Kind.TypeKeyword, element)
                    end
                    ::continue::
                end
            end
        end
    end
end

-- deleteTypeKeyword deletes the 'type' keyword token starting at the given position,
-- including any trailing whitespace.
function autoimport.deleteTypeKeyword(changes, sourceFile, startPos)
    local scan = scanner.GetScannerForSourceFile(sourceFile, startPos)
    if scan:Token() ~= Kind.TypeKeyword then
        return
    end
    local typeStart = scan:TokenStart()
    local typeEnd = scan:TokenEnd()
    -- Skip trailing whitespace
    local text = sourceFile:Text()
    while typeEnd < #text do
        local c = string.byte(text, typeEnd + 1)
        if c ~= 0x20 and c ~= 0x09 then
            break
        end
        typeEnd = typeEnd + 1
    end
    changes:DeleteRange(sourceFile, core.NewTextRange(typeStart, typeEnd))
end

function autoimport.getModuleSpecifierText(promotedDeclaration)
    if promotedDeclaration.kind == Kind.ImportEqualsDeclaration then
        local importEqualsDeclaration = promotedDeclaration:AsImportEqualsDeclaration()
        if ast.IsExternalModuleReference(importEqualsDeclaration.moduleReference) then
            local expr = importEqualsDeclaration.moduleReference:Expression()
            if expr ~= nil then
                if ast.IsStringLiteralLike(expr) then
                    return expr:Text()
                end
                return scanner.GetTextOfNode(expr)
            end
        end
        return scanner.GetTextOfNode(importEqualsDeclaration.moduleReference)
    end
    local moduleSpecifier = promotedDeclaration.parent:ModuleSpecifier()
    if ast.IsStringLiteralLike(moduleSpecifier) then
        return moduleSpecifier:Text()
    end
    return scanner.GetTextOfNode(moduleSpecifier)
end

-- returns `-1` if `a` is better than `b`
function autoimport.compareModuleSpecifierRelativity(a, b, preferences)
    local p = preferences.importModuleSpecifierPreference
    if p == modulespecifiers.ImportModuleSpecifierPreference.NonRelative or p == modulespecifiers.ImportModuleSpecifierPreference.ProjectRelative then
        return core.CompareBooleans(a.moduleSpecifierKind == ResultKind.Relative, b.moduleSpecifierKind == ResultKind.Relative)
    end
    return 0
end
