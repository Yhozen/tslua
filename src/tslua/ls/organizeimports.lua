local ls = require("tslua.ls")
local ast = require("tslua.ast")
local change = require("tslua.ls.change")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local EF = printer.EmitFlags

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

-- OrganizeImports organizes imports by:
--  1. Removing unused imports
--  2. Coalescing imports from the same module
--  3. Sorting imports
function LanguageService:OrganizeImports(ctx, sourceFile, program, kind)
    local changeTracker = change.NewTracker(ctx, program:Options(), self:FormatOptions(), self.converters)
    local shouldSort = kind == lsproto.CodeActionKind.SourceSortImports or kind == lsproto.CodeActionKind.SourceOrganizeImports
    local shouldCombine = shouldSort
    local shouldRemove = kind == lsproto.CodeActionKind.SourceRemoveUnusedImports or kind == lsproto.CodeActionKind.SourceOrganizeImports
    local topLevelImportDecls = lsutil.FilterImportDeclarations(sourceFile.statements.nodes)
    local topLevelImportGroupDecls = ls.groupByNewlineContiguous(sourceFile, topLevelImportDecls)

    local preferences = self:UserPreferences()
    local comparersToTest, typeOrdersToTest = lsutil.GetDetectionLists(preferences)
    local defaultComparer = comparersToTest[1]
    local sort = lsutil.ResolveOrganizeImportsSort(preferences)

    local moduleSpecifierComparer = nil
    local namedImportComparer = nil
    if sort ~= lsutil.OrganizeImportsSort.Auto then
        moduleSpecifierComparer = defaultComparer
        namedImportComparer = defaultComparer
    end
    local typeOrder = preferences.organizeImportsTypeOrder

    if sort == lsutil.OrganizeImportsSort.Auto then
        local result = lsutil.DetectModuleSpecifierCaseBySort(topLevelImportGroupDecls or {}, comparersToTest)
        moduleSpecifierComparer = result
    end

    if typeOrder == lsutil.OrganizeImportsTypeOrder.Auto or sort == lsutil.OrganizeImportsSort.Auto then
        local namedImportComparer2, typeOrder2, found = lsutil.DetectNamedImportOrganizationBySort(topLevelImportDecls or {}, comparersToTest, typeOrdersToTest)
        if found then
            if namedImportComparer == nil or sort == lsutil.OrganizeImportsSort.Auto then
                namedImportComparer = namedImportComparer2
            end
            if typeOrder == lsutil.OrganizeImportsTypeOrder.Auto then
                typeOrder = typeOrder2
            end
        end
    end

    local comparer = {
        moduleSpecifierComparer = moduleSpecifierComparer,
        namedImportComparer = namedImportComparer,
        typeOrder = typeOrder,
    }

    for _, importGroupDecl in ipairs(topLevelImportGroupDecls or {}) do
        ls.organizeImportsWorker(importGroupDecl, comparer, shouldSort, shouldCombine, shouldRemove, sourceFile, program, changeTracker, ctx)
    end

    if kind ~= lsproto.CodeActionKind.SourceRemoveUnusedImports then
        local topLevelExportGroupDecls = ls.getTopLevelExportGroups(sourceFile)
        for _, exportGroupDecl in ipairs(topLevelExportGroupDecls or {}) do
            ls.organizeExportsWorker(exportGroupDecl, comparer, sourceFile, changeTracker)
        end
    end

    for _, stmt in ipairs(sourceFile.statements.nodes or {}) do
        if not ast.IsAmbientModule(stmt) then
            goto continue
        end

        do
            local ambientModule = stmt:AsModuleDeclaration()
            if ambientModule.body == nil then
                goto continue
            end

            local moduleBody = ambientModule.body:AsModuleBlock()

            local ambientModuleImportDecls = lsutil.FilterImportDeclarations(moduleBody.statements.nodes)
            local ambientModuleImportGroupDecls = ls.groupByNewlineContiguous(sourceFile, ambientModuleImportDecls)

            for _, importGroupDecl in ipairs(ambientModuleImportGroupDecls or {}) do
                ls.organizeImportsWorker(importGroupDecl, comparer, shouldSort, shouldCombine, shouldRemove, sourceFile, program, changeTracker, ctx)
            end

            if kind ~= lsproto.CodeActionKind.SourceRemoveUnusedImports then
                local ambientModuleExportDecls = nil
                for _, s in ipairs(moduleBody.statements.nodes or {}) do
                    if s.kind == Kind.ExportDeclaration then
                        ambientModuleExportDecls = core.Append(ambientModuleExportDecls, s)
                    end
                end
                ls.organizeExportsWorker(ambientModuleExportDecls, comparer, sourceFile, changeTracker)
            end
        end

        ::continue::
    end

    -- Unmappable files are dropped by GetChanges, so a content-mapped file whose imports cannot be
    -- faithfully rewritten yields no edits rather than a corrupting one.
    local changes = changeTracker:GetChanges()
    return changes
end

-- organizeImportsComparerSettings: { moduleSpecifierComparer = fn(a, b), namedImportComparer = fn(a, b),
-- typeOrder = lsutil.OrganizeImportsTypeOrder }

function ls.organizeImportsWorker(oldImportDecls, comparer, shouldSort, shouldCombine, shouldRemove, sourceFile, program, changeTracker, ctx)
    if core.Len(oldImportDecls) == 0 then
        return
    end

    -- Header comment preservation is handled via LeadingTriviaOptionExclude in the change tracker below

    local done = nil
    local processedImports = core.Slice(oldImportDecls, 0, #oldImportDecls)
    if shouldRemove then
        local typeChecker
        typeChecker, done = program:GetTypeCheckerForFile(ctx, sourceFile)
        processedImports = ls.removeUnusedImports(processedImports, sourceFile, typeChecker, program, changeTracker)
    end

    local newImportDecls = nil
    if shouldCombine then
        local grouped = ls.groupByModuleSpecifier(processedImports)
        if shouldSort then
            core.SortFunc(grouped, function(a, b)
                if #a == 0 or #b == 0 then
                    return 0
                end
                return lsutil.CompareModuleSpecifiers(
                    a[1]:ModuleSpecifier(),
                    b[1]:ModuleSpecifier(),
                    comparer.moduleSpecifierComparer
                )
            end)
        end

        local specifierComparer = lsutil.GetNamedImportSpecifierComparer(
            lsutil.UserPreferences_new({ organizeImportsTypeOrder = comparer.typeOrder }),
            comparer.namedImportComparer
        )

        for _, importGroup in ipairs(grouped) do
            local coalesced = ls.coalesceImportsWorker(importGroup, comparer.moduleSpecifierComparer, specifierComparer, sourceFile, changeTracker)
            if shouldSort then
                core.SortFunc(coalesced, function(a, b)
                    return lsutil.CompareImportsOrRequireStatements(a, b, comparer.moduleSpecifierComparer)
                end)
            end
            newImportDecls = core.AppendAll(newImportDecls, coalesced)
        end
    else
        newImportDecls = processedImports
    end

    if shouldSort and not shouldCombine then
        core.SortFunc(newImportDecls, function(a, b)
            return lsutil.CompareImportsOrRequireStatements(a, b, comparer.moduleSpecifierComparer)
        end)
    end

    if core.Len(newImportDecls) == 0 then
        changeTracker:DeleteNodeRange(
            sourceFile,
            oldImportDecls[1],
            oldImportDecls[#oldImportDecls],
            change.LeadingTriviaOption.Exclude, -- Preserve header comment
            change.TrailingTriviaOption.Include
        )
    else
        for _, imp in ipairs(newImportDecls) do
            changeTracker.emitContext:SetEmitFlags(imp, EF.EFNoLeadingComments)
        end

        local options = change.NodeOptions_new({
            leadingTriviaOption = change.LeadingTriviaOption.Exclude, -- Preserve header comment
            trailingTriviaOption = change.TrailingTriviaOption.Include,
            suffix = "\n",
        })

        local newNodes = core.Map(newImportDecls, function(s) return s end)
        changeTracker:ReplaceNodeWithNodes(sourceFile, oldImportDecls[1], newNodes, options)

        if #oldImportDecls > 1 then
            for i = 1, #oldImportDecls - 1 do
                changeTracker:Delete(sourceFile, oldImportDecls[i + 1])
            end
        end
    end

    if done ~= nil then
        done()
    end
end

function ls.groupByModuleSpecifier(imports)
    local groups = {}
    local order = {}

    for _, imp in ipairs(imports or {}) do
        local specifier = lsutil.GetExternalModuleName(imp:ModuleSpecifier())
        if groups[specifier] == nil then
            order[#order + 1] = specifier
            groups[specifier] = {}
        end
        local g = groups[specifier]
        g[#g + 1] = imp
    end

    local result = {}
    for _, key in ipairs(order) do
        result[#result + 1] = groups[key]
    end
    return result
end

function ls.removeUnusedImports(oldImports, sourceFile, typeChecker, program, changeTracker)
    local compilerOptions = program:Options()
    local jsxElementsPresent = (sourceFile:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsJsx) ~= 0
    local jsxModeNeedsExplicitImport = compilerOptions.jsx == core.JsxEmit.React or compilerOptions.jsx == core.JsxEmit.ReactNative

    local factory = ast.NewNodeFactory({})
    local usedImports = {}

    for _, importDecl in ipairs(oldImports) do
        local importClause = importDecl:AsImportDeclaration().importClause
        if importClause == nil then
            usedImports[#usedImports + 1] = importDecl
            goto continue
        end

        do
            local clause = importClause:AsImportClause()
            local name = clause:Name()
            local namedBindings = clause.namedBindings

            if name ~= nil and not typeChecker:IsDeclarationUsed(sourceFile, name:AsIdentifier(), jsxElementsPresent, jsxModeNeedsExplicitImport) then
                name = nil
            end

            if namedBindings ~= nil then
                if namedBindings.kind == Kind.NamespaceImport then
                    local nsImport = namedBindings:AsNamespaceImport()
                    if not typeChecker:IsDeclarationUsed(sourceFile, nsImport:Name():AsIdentifier(), jsxElementsPresent, jsxModeNeedsExplicitImport) then
                        namedBindings = nil
                    end
                elseif namedBindings.kind == Kind.NamedImports then
                    local namedImports = namedBindings:AsNamedImports()
                    local originalBindings = namedBindings
                    local newElements = ls.filterUsedImportSpecifiers(namedImports.elements.nodes, typeChecker, sourceFile, jsxElementsPresent, jsxModeNeedsExplicitImport)
                    if core.Len(newElements) == 0 then
                        namedBindings = nil
                    elseif #newElements < core.Len(namedImports.elements.nodes) then
                        local newList = factory:NewNodeList(newElements)
                        local updatedNamedImports = factory:UpdateNamedImports(namedImports, newList)
                        namedBindings = updatedNamedImports
                    end
                    if namedBindings ~= nil and not ast.NodeIsSynthesized(originalBindings) and not printer.RangeIsOnSingleLine(originalBindings.loc, sourceFile) then
                        changeTracker.emitContext:SetEmitFlags(namedBindings, EF.EFMultiLine)
                    end
                end
            end

            if name ~= nil or namedBindings ~= nil then
                local importDeclNode = importDecl:AsImportDeclaration()
                local newClause = factory:UpdateImportClause(clause, clause.phaseModifier, name, namedBindings)
                local newImportDecl = factory:UpdateImportDeclaration(
                    importDeclNode,
                    importDeclNode:Modifiers(),
                    newClause,
                    importDeclNode.moduleSpecifier,
                    importDeclNode.attributes
                )
                usedImports[#usedImports + 1] = newImportDecl
            else
                local moduleSpecifier = importDecl:ModuleSpecifier()
                if ls.hasModuleDeclarationMatchingSpecifier(sourceFile, moduleSpecifier) then
                    if sourceFile.isDeclarationFile then
                        local importDeclNode = importDecl:AsImportDeclaration()
                        local newImportDecl = factory:UpdateImportDeclaration(
                            importDeclNode,
                            importDeclNode:Modifiers(),
                            nil, -- no import clause
                            importDeclNode.moduleSpecifier,
                            importDeclNode.attributes
                        )
                        usedImports[#usedImports + 1] = newImportDecl
                    else
                        usedImports[#usedImports + 1] = importDecl
                    end
                end
            end
        end

        ::continue::
    end

    return usedImports
end

function ls.filterUsedImportSpecifiers(elements, typeChecker, sourceFile, jsxElementsPresent, jsxModeNeedsExplicitImport)
    local result = nil
    for _, elem in ipairs(elements or {}) do
        local spec = elem:AsImportSpecifier()
        if typeChecker:IsDeclarationUsed(sourceFile, spec:Name():AsIdentifier(), jsxElementsPresent, jsxModeNeedsExplicitImport) then
            result = core.Append(result, elem)
        end
    end
    return result
end

function ls.hasModuleDeclarationMatchingSpecifier(sourceFile, moduleSpecifier)
    if moduleSpecifier == nil or not ast.IsStringLiteral(moduleSpecifier) then
        return false
    end
    local moduleSpecifierText = moduleSpecifier:Text()

    for _, moduleName in ipairs(sourceFile.moduleAugmentations or {}) do
        if ast.IsStringLiteral(moduleName) and moduleName:Text() == moduleSpecifierText then
            return true
        end
    end

    return false
end

-- getImportAttributesKey returns a key for grouping imports by their attributes.
function ls.getImportAttributesKey(attributes)
    if attributes == nil then
        return ""
    end

    local importAttrs = attributes:AsImportAttributes()
    local key = core.NewStringBuilder()
    key:WriteString(ast.Kind_String(importAttrs.token))
    key:WriteString(" ")

    local attrNodes = core.Slice(importAttrs.attributes.nodes, 0, core.Len(importAttrs.attributes.nodes))
    core.SortFunc(attrNodes, function(a, b)
        local aName = a:AsImportAttribute():Name():Text()
        local bName = b:AsImportAttribute():Name():Text()
        return stringutil.CompareStringsCaseSensitive(aName, bName)
    end)

    for _, attrNode in ipairs(attrNodes) do
        local attr = attrNode:AsImportAttribute()
        key:WriteString(attr:Name():Text())
        key:WriteString(":")
        if ast.IsStringLiteralLike(attr.value) then
            key:WriteString("\"")
            key:WriteString(attr.value:Text())
            key:WriteString("\"")
        else
            key:WriteString(attr.value:Text())
        end
        key:WriteString(" ")
    end

    return key:String()
end

-- groupByNewlineContiguous groups declarations by blank lines between them.
function ls.groupByNewlineContiguous(sourceFile, decls)
    local s = scanner.NewScanner()
    s:SetSkipTrivia(false) -- Must not skip trivia to detect newlines
    local groups = nil
    local currentGroup = nil

    for _, decl in ipairs(decls or {}) do
        if core.Len(currentGroup) > 0 and ls.isNewGroup(sourceFile, decl, s) then
            groups = core.Append(groups, currentGroup)
            currentGroup = nil
        end
        currentGroup = core.Append(currentGroup, decl)
    end

    if core.Len(currentGroup) > 0 then
        groups = core.Append(groups, currentGroup)
    end

    return groups
end

function ls.isNewGroup(sourceFile, decl, s)
    local fullStart = decl:Pos()
    if fullStart < 0 then
        return false
    end

    local text = sourceFile:Text()
    local textLen = #text

    if fullStart >= textLen then
        return false
    end

    local startPos = scanner.SkipTrivia(text, fullStart)
    if startPos <= fullStart then
        return false
    end

    local triviaLen = startPos - fullStart
    s:SetText(string.sub(text, fullStart + 1, startPos))

    local numberOfNewLines = 0
    while s:TokenStart() < triviaLen do
        local tokenKind = s:Scan()
        if tokenKind == Kind.NewLineTrivia then
            numberOfNewLines = numberOfNewLines + 1
            if numberOfNewLines >= 2 then
                return true
            end
        end
    end

    return false
end

function ls.coalesceImportsWorker(importDecls, comparer, specifierComparer, sourceFile, changeTracker)
    if core.Len(importDecls) == 0 then
        return importDecls
    end

    local importGroupsByAttributes = {}
    local attributeKeys = {}

    for _, importDecl in ipairs(importDecls) do
        local key = ls.getImportAttributesKey(importDecl:AsImportDeclaration().attributes)
        if importGroupsByAttributes[key] == nil then
            attributeKeys[#attributeKeys + 1] = key
            importGroupsByAttributes[key] = {}
        end
        local g = importGroupsByAttributes[key]
        g[#g + 1] = importDecl
    end

    local coalescedImports = {}

    for _, attributeKey in ipairs(attributeKeys) do
        local importGroupSameAttrs = importGroupsByAttributes[attributeKey]
        local categorized = ls.getCategorizedImports(importGroupSameAttrs)

        if categorized.importWithoutClause ~= nil then
            coalescedImports[#coalescedImports + 1] = categorized.importWithoutClause
        end

        local factory = ast.NewNodeFactory({})

        for i1, group in ipairs({ categorized.regularImports, categorized.typeOnlyImports }) do
            if ls.importGroup_isEmpty(group) then
                goto continue
            end

            do
                local isTypeOnly = i1 - 1 == 1

                if not isTypeOnly and core.Len(group.defaultImports) == 1 and core.Len(group.namespaceImports) == 1 and core.Len(group.namedImports) == 0 then
                    local defaultImport = group.defaultImports[1]
                    local namespaceImport = group.namespaceImports[1]

                    local defaultClause = defaultImport:AsImportDeclaration().importClause:AsImportClause()
                    local namespaceBindings = namespaceImport:AsImportDeclaration().importClause:AsImportClause().namedBindings

                    local newClause = factory:UpdateImportClause(defaultClause, defaultClause.phaseModifier, defaultClause:Name(), namespaceBindings)
                    local defaultDeclNode = defaultImport:AsImportDeclaration()
                    local newImportDecl = factory:UpdateImportDeclaration(
                        defaultDeclNode,
                        defaultDeclNode:Modifiers(),
                        newClause,
                        defaultDeclNode.moduleSpecifier,
                        defaultDeclNode.attributes
                    )
                    coalescedImports[#coalescedImports + 1] = newImportDecl
                    goto continue
                end

                core.SortFunc(group.namespaceImports, function(a, b)
                    local n1 = a:AsImportDeclaration().importClause:AsImportClause().namedBindings:AsNamespaceImport():Name()
                    local n2 = b:AsImportDeclaration().importClause:AsImportClause().namedBindings:AsNamespaceImport():Name()
                    return comparer(n1:Text(), n2:Text())
                end)

                for _, nsImport in ipairs(group.namespaceImports or {}) do
                    local nsImportDecl = nsImport:AsImportDeclaration()
                    local clause = nsImportDecl.importClause:AsImportClause()
                    local newClause = factory:UpdateImportClause(clause, clause.phaseModifier, nil, clause.namedBindings)
                    local newImportDecl = factory:UpdateImportDeclaration(
                        nsImportDecl,
                        nsImportDecl:Modifiers(),
                        newClause,
                        nsImportDecl.moduleSpecifier,
                        nsImportDecl.attributes
                    )
                    coalescedImports[#coalescedImports + 1] = newImportDecl
                end

                local firstDefaultImport = nil
                local firstNamedImport = nil

                if core.Len(group.defaultImports) > 0 then
                    firstDefaultImport = group.defaultImports[1]
                end
                if core.Len(group.namedImports) > 0 then
                    firstNamedImport = group.namedImports[1]
                end

                local importDecl = firstDefaultImport
                if importDecl == nil then
                    importDecl = firstNamedImport
                end
                if importDecl == nil then
                    goto continue
                end

                local newDefaultImport = nil
                local newImportSpecifiers = nil

                if core.Len(group.defaultImports) == 1 then
                    newDefaultImport = group.defaultImports[1]:AsImportDeclaration().importClause:AsImportClause():Name()
                else
                    for _, defaultImport in ipairs(group.defaultImports or {}) do
                        local defaultClause = defaultImport:AsImportDeclaration().importClause:AsImportClause()
                        local defaultName = defaultClause:Name()
                        local propertyName = factory:NewIdentifier("default")
                        local importSpec = factory:NewImportSpecifier(false, propertyName, defaultName)
                        newImportSpecifiers = core.Append(newImportSpecifiers, importSpec)
                    end
                end

                newImportSpecifiers = core.AppendAll(newImportSpecifiers, ls.getNewImportSpecifiers(group.namedImports, factory))
                core.SortStableFunc(newImportSpecifiers, specifierComparer)

                local newNamedImports
                if core.Len(newImportSpecifiers) == 0 then
                    if newDefaultImport ~= nil then
                        newNamedImports = nil
                    else
                        newNamedImports = factory:NewNamedImports(factory:NewNodeList(nil))
                    end
                else
                    local sortedList = factory:NewNodeList(newImportSpecifiers)
                    if firstNamedImport ~= nil then
                        local firstNamedBindings = firstNamedImport:AsImportDeclaration().importClause:AsImportClause().namedBindings:AsNamedImports()
                        local originalElements = firstNamedBindings.elements
                        if originalElements:HasTrailingComma() then
                            sortedList.loc = originalElements.loc
                        end
                        newNamedImports = factory:UpdateNamedImports(firstNamedBindings, sortedList)
                    else
                        newNamedImports = factory:NewNamedImports(sortedList)
                    end
                end

                if sourceFile ~= nil and newNamedImports ~= nil and firstNamedImport ~= nil then
                    local firstNamedBindings = firstNamedImport:AsImportDeclaration().importClause:AsImportClause().namedBindings
                    if not ast.NodeIsSynthesized(firstNamedBindings) and not printer.RangeIsOnSingleLine(firstNamedBindings.loc, sourceFile) then
                        changeTracker.emitContext:SetEmitFlags(newNamedImports, EF.EFMultiLine)
                    end
                end

                if isTypeOnly and newDefaultImport ~= nil and newNamedImports ~= nil then
                    local importDeclNode = importDecl:AsImportDeclaration()

                    local defaultClause = factory:NewImportClause(importDeclNode.importClause:AsImportClause().phaseModifier, newDefaultImport, nil)
                    local defaultImportDecl = factory:UpdateImportDeclaration(
                        importDeclNode,
                        importDeclNode:Modifiers(),
                        defaultClause,
                        importDeclNode.moduleSpecifier,
                        importDeclNode.attributes
                    )
                    coalescedImports[#coalescedImports + 1] = defaultImportDecl

                    local namedDeclNode = firstNamedImport
                    if namedDeclNode == nil then
                        namedDeclNode = importDecl
                    end
                    local namedImportDeclNode = namedDeclNode:AsImportDeclaration()
                    local namedClause = factory:NewImportClause(namedImportDeclNode.importClause:AsImportClause().phaseModifier, nil, newNamedImports)
                    local namedImportDecl = factory:UpdateImportDeclaration(
                        namedImportDeclNode,
                        namedImportDeclNode:Modifiers(),
                        namedClause,
                        namedImportDeclNode.moduleSpecifier,
                        namedImportDeclNode.attributes
                    )
                    coalescedImports[#coalescedImports + 1] = namedImportDecl
                else
                    local importDeclNode = importDecl:AsImportDeclaration()
                    local clauseNode = importDeclNode.importClause:AsImportClause()
                    local newClause = factory:UpdateImportClause(clauseNode, clauseNode.phaseModifier, newDefaultImport, newNamedImports)
                    local newImportDecl = factory:UpdateImportDeclaration(
                        importDeclNode,
                        importDeclNode:Modifiers(),
                        newClause,
                        importDeclNode.moduleSpecifier,
                        importDeclNode.attributes
                    )
                    coalescedImports[#coalescedImports + 1] = newImportDecl
                end
            end

            ::continue::
        end
    end
    return coalescedImports
end

-- categorizedImports: { importWithoutClause, typeOnlyImports = importGroup, regularImports = importGroup }
-- importGroup: { defaultImports, namespaceImports, namedImports } (slices, possibly nil)

function ls.importGroup_isEmpty(g)
    return core.Len(g.defaultImports) == 0 and core.Len(g.namespaceImports) == 0 and core.Len(g.namedImports) == 0
end

function ls.getCategorizedImports(importDecls)
    local importWithoutClause = nil
    local typeOnlyImports = { defaultImports = nil, namespaceImports = nil, namedImports = nil }
    local regularImports = { defaultImports = nil, namespaceImports = nil, namedImports = nil }

    for _, importDecl in ipairs(importDecls or {}) do
        if importDecl:AsImportDeclaration().importClause == nil then
            if importWithoutClause == nil then
                importWithoutClause = importDecl
            end
            goto continue
        end

        do
            local clause = importDecl:AsImportDeclaration().importClause:AsImportClause()
            local group = regularImports
            if clause:IsTypeOnly() then
                group = typeOnlyImports
            end

            local name = clause:Name()
            local namedBindings = clause.namedBindings

            if name ~= nil then
                group.defaultImports = core.Append(group.defaultImports, importDecl)
            end

            if namedBindings ~= nil then
                if namedBindings.kind == Kind.NamespaceImport then
                    group.namespaceImports = core.Append(group.namespaceImports, importDecl)
                elseif namedBindings.kind == Kind.NamedImports then
                    group.namedImports = core.Append(group.namedImports, importDecl)
                end
            end
        end

        ::continue::
    end

    return {
        importWithoutClause = importWithoutClause,
        typeOnlyImports = typeOnlyImports,
        regularImports = regularImports,
    }
end

function ls.getNewImportSpecifiers(namedImports, factory)
    local result = nil

    for _, namedImport in ipairs(namedImports or {}) do
        local elements = ls.tryGetNamedBindingElements(namedImport)
        if elements == nil then
            goto continue
        end

        for _, elem in ipairs(elements) do
            local spec = elem:AsImportSpecifier()

            if spec.propertyName ~= nil and spec:Name() ~= nil then
                local propertyText = spec.propertyName:Text()
                local nameText = spec:Name():Text()

                if propertyText == nameText then
                    local normalized = factory:UpdateImportSpecifier(spec, spec.isTypeOnly, nil, spec:Name())
                    result = core.Append(result, normalized)
                    goto nextElem
                end
            end

            result = core.Append(result, elem)
            ::nextElem::
        end

        ::continue::
    end

    return result
end

function ls.tryGetNamedBindingElements(namedImport)
    if namedImport.kind ~= Kind.ImportDeclaration then
        return nil
    end

    local importDecl = namedImport:AsImportDeclaration()
    if importDecl.importClause == nil then
        return nil
    end

    local clause = importDecl.importClause:AsImportClause()
    local namedBindings = clause.namedBindings

    if namedBindings ~= nil and namedBindings.kind == Kind.NamedImports then
        local namedImportsNode = namedBindings:AsNamedImports()
        return namedImportsNode.elements.nodes
    end

    return nil
end

function ls.getTopLevelExportGroups(sourceFile)
    local topLevelExportGroups = {}
    local statements = sourceFile.statements.nodes or {}
    local statementsLen = #statements

    local i = 0
    local groupIndex = 0
    while i < statementsLen do
        if statements[i + 1].kind == Kind.ExportDeclaration then
            if groupIndex >= #topLevelExportGroups then
                topLevelExportGroups[#topLevelExportGroups + 1] = {}
            end
            local exportDecl = statements[i + 1]:AsExportDeclaration()
            if exportDecl.moduleSpecifier ~= nil then
                local g = topLevelExportGroups[groupIndex + 1]
                g[#g + 1] = statements[i + 1]
                i = i + 1
            else
                while i < statementsLen and statements[i + 1].kind == Kind.ExportDeclaration do
                    local g = topLevelExportGroups[groupIndex + 1]
                    g[#g + 1] = statements[i + 1]
                    i = i + 1
                end
                groupIndex = groupIndex + 1
            end
        else
            i = i + 1
            if groupIndex < #topLevelExportGroups and #topLevelExportGroups[groupIndex + 1] > 0 then
                groupIndex = groupIndex + 1
            end
        end
    end

    local result = nil
    for _, exportGroup in ipairs(topLevelExportGroups) do
        local subGroups = ls.groupByNewlineContiguous(sourceFile, exportGroup)
        result = core.AppendAll(result, subGroups)
    end

    return result
end

function ls.organizeExportsWorker(oldExportDecls, comparer, sourceFile, changeTracker)
    if core.Len(oldExportDecls) == 0 then
        return
    end

    local specifierComparerFunc = lsutil.GetNamedImportSpecifierComparer(
        lsutil.UserPreferences_new({ organizeImportsTypeOrder = comparer.typeOrder }),
        comparer.namedImportComparer
    )

    local newExportDecls = ls.coalesceExportsWorker(oldExportDecls, specifierComparerFunc, comparer.moduleSpecifierComparer, sourceFile, changeTracker)

    if #oldExportDecls > 0 then
        if core.Len(newExportDecls) == 0 then
            changeTracker:DeleteNodeRange(
                sourceFile,
                oldExportDecls[1],
                oldExportDecls[#oldExportDecls],
                change.LeadingTriviaOption.Exclude,
                change.TrailingTriviaOption.Include
            )
        else
            for _, exp in ipairs(newExportDecls) do
                changeTracker.emitContext:AddEmitFlags(exp, EF.EFNoLeadingComments)
            end

            local options = change.NodeOptions_new({
                leadingTriviaOption = change.LeadingTriviaOption.Exclude,
                trailingTriviaOption = change.TrailingTriviaOption.Include,
                suffix = "\n",
            })

            local newNodes = core.Map(newExportDecls, function(s) return s end)
            changeTracker:ReplaceNodeWithNodes(sourceFile, oldExportDecls[1], newNodes, options)

            if #oldExportDecls > 1 then
                for i = 1, #oldExportDecls - 1 do
                    changeTracker:Delete(sourceFile, oldExportDecls[i + 1])
                end
            end
        end
    end
end

function ls.coalesceExportsWorker(exportGroup, specifierComparer, moduleSpecifierComparer, sourceFile, changeTracker)
    if core.Len(exportGroup) == 0 then
        return exportGroup
    end

    local exportsByModuleSpecifier = {}
    local moduleSpecifierOrder = {}

    for _, exportDecl in ipairs(exportGroup) do
        local export = exportDecl:AsExportDeclaration()
        local moduleSpecifier = ""
        if export.moduleSpecifier ~= nil then
            moduleSpecifier = export.moduleSpecifier:Text()
        end
        if exportsByModuleSpecifier[moduleSpecifier] == nil then
            moduleSpecifierOrder[#moduleSpecifierOrder + 1] = moduleSpecifier
            exportsByModuleSpecifier[moduleSpecifier] = {}
        end
        local g = exportsByModuleSpecifier[moduleSpecifier]
        g[#g + 1] = exportDecl
    end

    core.SortStableFunc(moduleSpecifierOrder, function(a, b)
        if a == "" and b ~= "" then
            return 1
        end
        if a ~= "" and b == "" then
            return -1
        end
        return moduleSpecifierComparer(a, b)
    end)

    local coalescedExports = nil
    local factory = ast.NewNodeFactory({})

    for _, moduleSpecifier in ipairs(moduleSpecifierOrder) do
        local group = exportsByModuleSpecifier[moduleSpecifier]

        local categorized = ls.getCategorizedExports(group)

        if categorized.exportWithoutClause ~= nil then
            coalescedExports = core.Append(coalescedExports, categorized.exportWithoutClause)
        end

        for _, subGroup in ipairs({ categorized.namedExports or {}, categorized.typeOnlyExports or {} }) do
            if #subGroup == 0 then
                goto continue
            end

            do
                local newExportSpecifiers = nil
                for _, exportDecl in ipairs(subGroup) do
                    local exportClause = exportDecl:AsExportDeclaration().exportClause
                    if exportClause ~= nil and exportClause.kind == Kind.NamedExports then
                        local namedExports = exportClause:AsNamedExports()
                        newExportSpecifiers = core.AppendAll(newExportSpecifiers, namedExports.elements.nodes)
                    end
                end

                core.SortStableFunc(newExportSpecifiers, specifierComparer)

                local exportDecl = subGroup[1]:AsExportDeclaration()

                local updatedExportClause = nil
                if exportDecl.exportClause ~= nil then
                    if exportDecl.exportClause.kind == Kind.NamedExports then
                        local namedExports = exportDecl.exportClause:AsNamedExports()
                        local sortedList = factory:NewNodeList(newExportSpecifiers)
                        updatedExportClause = factory:UpdateNamedExports(namedExports, sortedList)

                        if sourceFile ~= nil and not ast.NodeIsSynthesized(namedExports) and not printer.RangeIsOnSingleLine(namedExports.loc, sourceFile) then
                            changeTracker.emitContext:SetEmitFlags(updatedExportClause, EF.EFMultiLine)
                        end
                    else
                        updatedExportClause = exportDecl.exportClause
                    end
                end

                local newExportDecl = factory:UpdateExportDeclaration(
                    exportDecl,
                    exportDecl:Modifiers(),
                    exportDecl.isTypeOnly,
                    updatedExportClause,
                    exportDecl.moduleSpecifier,
                    exportDecl.attributes
                )
                coalescedExports = core.Append(coalescedExports, newExportDecl)
            end

            ::continue::
        end
    end

    return coalescedExports
end

-- categorizedExports: { exportWithoutClause, namedExports, typeOnlyExports }

function ls.getCategorizedExports(exportGroup)
    local exportWithoutClause = nil
    local namedExports, typeOnlyExports = nil, nil

    for _, exportDecl in ipairs(exportGroup or {}) do
        local export = exportDecl:AsExportDeclaration()
        if export.exportClause == nil then
            if exportWithoutClause == nil then
                exportWithoutClause = exportDecl
            end
        elseif export.isTypeOnly then
            typeOnlyExports = core.Append(typeOnlyExports, exportDecl)
        else
            namedExports = core.Append(namedExports, exportDecl)
        end
    end

    return {
        exportWithoutClause = exportWithoutClause,
        namedExports = namedExports,
        typeOnlyExports = typeOnlyExports,
    }
end
