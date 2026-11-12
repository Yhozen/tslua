-- Go internal/ls/completions.go, part 2 (getCompletionEntriesFromSymbols .. getCompletionsSymbolKind).
local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local autoimport = require("tslua.ls.autoimport")
local change = require("tslua.ls.change")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local jsnum = require("tslua.jsnum")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local FindAncestorResult = ast.FindAncestorResult
local TypeFlags = checker.TypeFlags
local ContextFlags = checker.ContextFlags
local ScriptElementKind = lsutil.ScriptElementKind
local LanguageVariant = core.LanguageVariant

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function hasPrefix(s, p)
    return #s >= #p and string.sub(s, 1, #p) == p
end

local function hasSuffix(s, p)
    return #s >= #p and (#p == 0 or string.sub(s, -#p) == p)
end

local function trimPrefix(s, p)
    if hasPrefix(s, p) then
        return string.sub(s, #p + 1)
    end
    return s
end

local function trimSuffix(s, p)
    if #p > 0 and hasSuffix(s, p) then
        return string.sub(s, 1, #s - #p)
    end
    return s
end

-- Go strings.CutPrefix: returns after, found.
local function cutPrefix(s, p)
    if hasPrefix(s, p) then
        return string.sub(s, #p + 1), true
    end
    return s, false
end

local function isExact(fidelity)
    return spanmap.Fidelity_IsExact(fidelity)
end

-- Go copies a collections.Set struct when passed by value: the copy shares the map once it exists,
-- but a nil map is lazily allocated in the copy only.
local function copySet(s)
    return setmetatable({ m = s.m }, collections.Set)
end

-- Go unicode.IsDigit (Unicode category Nd). Covers ASCII and the common decimal digit blocks.
local unicodeDigitRanges = {
    { 0x30, 0x39 }, { 0x660, 0x669 }, { 0x6F0, 0x6F9 }, { 0x7C0, 0x7C9 }, { 0x966, 0x96F },
    { 0x9E6, 0x9EF }, { 0xA66, 0xA6F }, { 0xAE6, 0xAEF }, { 0xB66, 0xB6F }, { 0xBE6, 0xBEF },
    { 0xC66, 0xC6F }, { 0xCE6, 0xCEF }, { 0xD66, 0xD6F }, { 0xDE6, 0xDEF }, { 0xE50, 0xE59 },
    { 0xED0, 0xED9 }, { 0xF20, 0xF29 }, { 0x1040, 0x1049 }, { 0x1090, 0x1099 }, { 0x17E0, 0x17E9 },
    { 0x1810, 0x1819 }, { 0x1946, 0x194F }, { 0x19D0, 0x19D9 }, { 0x1A80, 0x1A89 }, { 0x1A90, 0x1A99 },
    { 0x1B50, 0x1B59 }, { 0x1BB0, 0x1BB9 }, { 0x1C40, 0x1C49 }, { 0x1C50, 0x1C59 }, { 0xA620, 0xA629 },
    { 0xA8D0, 0xA8D9 }, { 0xA900, 0xA909 }, { 0xA9D0, 0xA9D9 }, { 0xA9F0, 0xA9F9 }, { 0xAA50, 0xAA59 },
    { 0xABF0, 0xABF9 }, { 0xFF10, 0xFF19 }, { 0x104A0, 0x104A9 }, { 0x11066, 0x1106F },
    { 0x1D7CE, 0x1D7FF },
}

local function unicodeIsDigit(r)
    if r < 0x80 then
        return r >= 0x30 and r <= 0x39
    end
    for _, rg in ipairs(unicodeDigitRanges) do
        if r >= rg[1] and r <= rg[2] then
            return true
        end
    end
    return false
end

function LanguageService:getCompletionEntriesFromSymbols(
    ctx,
    typeChecker,
    data,
    replacementToken,
    position,
    file,
    compilerOptions,
    includeSymbols
)
    local closestSymbolDeclaration = ls.getClosestSymbolDeclaration(data.contextToken, data.location)
    local useSemicolons = lsutil.ProbablyUsesSemicolons(file)
    local preferences = self:UserPreferences()
    local isMemberCompletion = ls.isMemberCompletionKind(data.completionKind)
    local sortedEntries = {}
    -- Tracks unique names.
    -- Value is set to false for global variables or completions from external module exports, because we can have multiple of those;
    -- true otherwise. Based on the order we add things we will always see locals first, then globals, then module exports.
    -- So adding a completion for a local will prevent us from adding completions for external module exports sharing the same name.
    local uniques = {}
    for index1, symbol in ipairs(data.symbols or {}) do
        local index = index1 - 1
        local origin = data.symbolToOriginInfoMap ~= nil and data.symbolToOriginInfoMap[index] or nil
        local name, needsConvertPropertyAccess = ls.getCompletionEntryDisplayNameForSymbol(
            symbol,
            origin,
            data.completionKind,
            data.isJsxIdentifierExpected
        )
        if name == "" or
            uniques[name] and (origin == nil or not ls.originIsObjectLiteralMethod(origin)) or
            data.completionKind == ls.CompletionKind.Global and
            not ls.shouldIncludeSymbol(symbol, data, closestSymbolDeclaration, file, typeChecker, compilerOptions) then
            goto continue
        end

        -- When in a value location in a JS file, ignore symbols that definitely seem to be type-only.
        if not data.isTypeOnlyLocation and ast.IsSourceFileJS(file) and ls.symbolAppearsToBeTypeOnly(symbol, typeChecker) then
            goto continue
        end

        do
            local originalSortText = data.symbolToSortTextMap ~= nil and data.symbolToSortTextMap[ast.GetSymbolId(symbol)] or ""
            if originalSortText == "" then
                originalSortText = ls.SortText.LocationPriority
            end

            local sortText
            if ls.isDeprecated(symbol, typeChecker) then
                sortText = ls.DeprecateSortText(originalSortText)
            else
                sortText = originalSortText
            end
            local entry, err = self:createCompletionItem(
                ctx,
                typeChecker,
                symbol,
                sortText,
                replacementToken,
                data,
                position,
                file,
                name,
                needsConvertPropertyAccess,
                origin,
                useSemicolons,
                compilerOptions,
                isMemberCompletion
            )
            if err ~= nil then
                return collections.NewSet(), nil, err
            end
            if entry == nil then
                goto continue
            end

            -- True for locals; false for globals, module exports from other files, `this.` completions.
            local shouldShadowLaterSymbols = (origin == nil or ls.originIsTypeOnlyAlias(origin)) and
                not (symbol.parent == nil and
                    not core.Some(symbol.declarations, function(d) return ast.GetSourceFileOfNode(d) == file end))
            uniques[name] = shouldShadowLaterSymbols
            local sym = nil
            if includeSymbols then
                sym = symbol
            end
            sortedEntries[#sortedEntries + 1] = ls.NewCompletionItem(entry, sym)
        end
        ::continue::
    end

    for _, autoImport in ipairs(data.autoImports or {}) do
        -- !!! check for type-only in JS
        -- !!! deprecation

        local replacementSpan = nil
        local insertText = ""
        local filterText = ""
        local isSnippet = false
        local sortText = ls.SortText.AutoImportSuggestions

        if data.importStatementCompletion ~= nil then
            isSnippet = ls.clientSupportsItemSnippet(ctx)
            insertText, replacementSpan = ls.getInsertTextAndReplacementSpanForImportCompletion(
                autoImport.fix,
                autoimport.GetImportKindForImportStatement(file, autoImport.export, self:GetProgram()),
                data.importStatementCompletion,
                useSemicolons,
                file,
                preferences,
                isSnippet
            )
            filterText = autoImport.fix.name
            sortText = ls.SortText.LocationPriority
        end

        -- Non-contextual keywords (e.g., `function`, `class`, `const`) cannot be used as identifiers,
        -- so auto-imports with these names should not shadow keyword completions.
        local token = scanner.StringToToken(autoImport.fix.name)
        if token ~= Kind.Unknown and ast.IsNonContextualKeyword(token) then
            goto continueAutoImport
        end

        if not autoImport.export:IsUnresolvedAlias() then
            if data.isTypeOnlyLocation then
                if autoImport.export.flags & SymbolFlags.Type == 0 and autoImport.export.flags & SymbolFlags.Module == 0 then
                    goto continueAutoImport
                end
            elseif data.importStatementCompletion == nil and autoImport.export.flags & SymbolFlags.Value == 0 then
                goto continueAutoImport
            end
        end

        do
            local entry = self:createLSPCompletionItem(
                ctx,
                autoImport.fix.name,
                insertText,
                filterText,
                sortText,
                autoImport.export.scriptElementKind,
                autoImport.export.scriptElementKindModifiers,
                replacementSpan,
                nil,
                {
                    description = autoImport.fix.moduleSpecifier,
                },
                file,
                position,
                false, --[[isMemberCompletion]]
                isSnippet,
                data.importStatementCompletion == nil, --[[hasAction]]
                false, --[[preselect]]
                autoImport.fix.moduleSpecifier,
                autoImport.fix.autoImportFix,
                nil, --[[additionalTextEdits]]
                nil --[[detail]]
            )

            entry.data.isImportStatementCompletion = data.importStatementCompletion ~= nil

            local isShadowed = uniques[autoImport.fix.name]
            if not isShadowed then
                uniques[autoImport.fix.name] = false
                sortedEntries[#sortedEntries + 1] = ls.NewCompletionItem(entry, nil)
            end
        end
        ::continueAutoImport::
    end

    local uniqueSet = collections.NewSetWithSizeHint(0)
    for name in pairs(uniques) do
        uniqueSet:Add(name)
    end
    return uniqueSet, sortedEntries, nil
end

function ls.completionNameForLiteral(file, preferences, literal)
    local tl = type(literal)
    if tl == "string" then
        return ls.quote(file, preferences, literal)
    elseif tl == "number" then
        local name = core.StringifyJson(literal, "" --[[prefix]], "" --[[suffix]])
        return name
    elseif tl == "table" and getmetatable(literal) == jsnum.PseudoBigInt then
        return literal:String() .. "n"
    end
    error("Unhandled literal value: " .. tostring(literal))
end

function ls.getInsertTextAndReplacementSpanForImportCompletion(fix, importKind, importStatementCompletion, useSemicolons, file, preferences, isSnippet)
    local quotedModuleSpecifier = ls.escapeSnippetText(ls.quote(file, preferences, fix.moduleSpecifier))
    local tabStop = core.IfElse(isSnippet, "$1", "")
    local suffix = core.IfElse(useSemicolons, ";", "")
    local topLevelTypeOnlyText = core.IfElse(importStatementCompletion.isTopLevelTypeOnly, " " .. scanner.TokenToString(Kind.TypeKeyword) .. " ", " ")
    local name = ls.escapeSnippetText(fix.name)
    local replacementSpan = importStatementCompletion.replacementSpan

    if importKind == lsproto.ImportKind.CommonJS then
        return "import" .. topLevelTypeOnlyText .. name .. tabStop .. " = require(" .. quotedModuleSpecifier .. ")" .. suffix, replacementSpan
    elseif importKind == lsproto.ImportKind.Default then
        return "import" .. topLevelTypeOnlyText .. name .. tabStop .. " from " .. quotedModuleSpecifier .. suffix, replacementSpan
    elseif importKind == lsproto.ImportKind.Namespace then
        return "import" .. topLevelTypeOnlyText .. "* as " .. name .. " from " .. quotedModuleSpecifier .. suffix, replacementSpan
    elseif importKind == lsproto.ImportKind.Named then
        return "import" .. topLevelTypeOnlyText .. "{ " ..
            core.IfElse(importStatementCompletion.couldBeTypeOnlyImportSpecifier, scanner.TokenToString(Kind.TypeKeyword) .. " ", "") ..
            name .. tabStop .. " } from " .. quotedModuleSpecifier .. suffix, replacementSpan
    else
        error("unhandled import kind: " .. tostring(lsproto.ImportKind_names[importKind]))
    end
end

function ls.createCompletionItemForLiteral(file, preferences, literal)
    return {
        label = ls.completionNameForLiteral(file, preferences, literal),
        kind = lsproto.CompletionItemKind.Constant,
        sortText = ls.SortText.LocationPriority,
        commitCharacters = {},
    }
end

function LanguageService:createCompletionItem(
    ctx,
    typeChecker,
    symbol,
    sortText,
    replacementToken,
    data,
    position,
    file,
    name,
    needsConvertPropertyAccess,
    origin,
    useSemicolons, -- luacheck: ignore 212
    compilerOptions, -- luacheck: ignore 212
    isMemberCompletion
)
    local contextToken = data.contextToken
    local insertText = ""
    local filterText = ""
    local replacementSpan = self:getReplacementRangeForContextToken(file, replacementToken, position)
    local isSnippet, hasAction = false, false
    local source = ls.getSourceFromOrigin(origin)
    local labelDetails = nil
    local preferences = self:UserPreferences()
    local insertQuestionDot = ls.originIsNullableMember(origin)
    local useBraces = ls.originIsSymbolMember(origin) or needsConvertPropertyAccess
    if ls.originIsThisTypeNode(origin) then
        if needsConvertPropertyAccess then
            insertText = "this" .. core.IfElse(insertQuestionDot, "?.", "") ..
                "[" .. ls.quotePropertyName(file, preferences, name) .. "]"
        else
            insertText = "this" .. core.IfElse(insertQuestionDot, "?.", ".") .. name
        end
    elseif data.propertyAccessToConvert ~= nil and (useBraces or insertQuestionDot) then
        -- We should only have needsConvertPropertyAccess if there's a property access to convert. But see microsoft/TypeScript#21790.
        -- Somehow there was a global with a non-identifier name. Hopefully someone will complain about getting a "foo bar" global completion and provide a repro.
        if useBraces then
            if needsConvertPropertyAccess then
                insertText = "[" .. ls.quotePropertyName(file, preferences, name) .. "]"
            else
                insertText = "[" .. name .. "]"
            end
        else
            insertText = name
        end

        if insertQuestionDot or data.propertyAccessToConvert:QuestionDotToken() ~= nil then
            insertText = "?." .. insertText
        end

        local dot = astnav.FindChildOfKind(data.propertyAccessToConvert, Kind.DotToken, file)
        if dot == nil then
            dot = astnav.FindChildOfKind(data.propertyAccessToConvert, Kind.QuestionDotToken, file)
        end

        if dot == nil then
            return nil, nil
        end

        -- If the text after the '.' starts with this name, write over it. Else, add new text.
        local end_
        if hasPrefix(name, data.propertyAccessToConvert:Name():Text()) then
            end_ = data.propertyAccessToConvert:End()
        else
            end_ = dot:End()
        end
        local lspRange, fidelity = self:createLspRangeFromBounds(astnav.GetStartOfNode(dot, file, false --[[includeJSDoc]]), end_, file)
        if not isExact(fidelity) then
            return nil, nil
        end
        replacementSpan = lspRange
    end

    if data.jsxInitializer.isInitializer then
        if insertText == "" then
            insertText = name
        end
        insertText = "{" .. insertText .. "}"
        if data.jsxInitializer.initializer ~= nil then
            local lspRange, fidelity = self:createLspRangeFromNode(data.jsxInitializer.initializer, file)
            if not isExact(fidelity) then
                return nil, nil
            end
            replacementSpan = lspRange
        end
    end

    if ls.originIsPromise(origin) and data.propertyAccessToConvert ~= nil then
        if insertText == "" then
            insertText = name
        end
        local precedingToken = astnav.FindPrecedingToken(file, data.propertyAccessToConvert:Pos())
        local awaitText = ""
        if precedingToken ~= nil and lsutil.PositionIsASICandidate(precedingToken:End(), precedingToken.parent, file) then
            awaitText = ";"
        end

        awaitText = awaitText .. "(await " .. scanner.GetTextOfNode(data.propertyAccessToConvert:Expression()) .. ")"
        if needsConvertPropertyAccess then
            insertText = awaitText .. insertText
        else
            local dotStr = core.IfElse(insertQuestionDot, "?.", ".")
            insertText = awaitText .. dotStr .. insertText
        end
        local isInAwaitExpression = ast.IsAwaitExpression(data.propertyAccessToConvert.parent)
        local wrapNode = core.IfElse(
            isInAwaitExpression,
            data.propertyAccessToConvert.parent,
            data.propertyAccessToConvert:Expression()
        )
        local lspRange, fidelity = self:createLspRangeFromBounds(
            astnav.GetStartOfNode(wrapNode, file, false --[[includeJSDoc]]),
            data.propertyAccessToConvert:End(),
            file
        )
        if not isExact(fidelity) then
            return nil, nil
        end
        replacementSpan = lspRange
    end

    if ls.originIsTypeOnlyAlias(origin) then
        hasAction = true
    end

    -- Provide object member completions when missing commas, and insert missing commas.
    -- For example:
    --
    --    interface I {
    --        a: string;
    --        b: number
    --     }
    --
    --     const cc: I = { a: "red" | }
    --
    -- Completion should add a comma after "red" and provide completions for b
    if data.completionKind == ls.CompletionKind.ObjectPropertyDeclaration and
        contextToken ~= nil and
        not ast.NodeHasKind(astnav.FindPrecedingTokenEx(file, contextToken:Pos(), contextToken, false --[[excludeJSDoc]]), Kind.CommaToken) then
        if ast.IsMethodDeclaration(contextToken.parent.parent) or
            ast.IsGetAccessorDeclaration(contextToken.parent.parent) or
            ast.IsSetAccessorDeclaration(contextToken.parent.parent) or
            ast.IsSpreadAssignment(contextToken.parent) or
            lsutil.GetLastToken(ast.FindAncestor(contextToken.parent, ast.IsPropertyAssignment), file) == contextToken or
            ast.IsShorthandPropertyAssignment(contextToken.parent) and
            ls.getLineOfPosition(file, contextToken:End()) ~= ls.getLineOfPosition(file, position) then
            source = ls.completionSource.ObjectLiteralMemberWithComma
            hasAction = true
        end
    end

    local additionalTextEdits = nil
    if core.Tristate_IsTrue(preferences.includeCompletionsWithClassMemberSnippets) and
        data.completionKind == ls.CompletionKind.MemberLike and
        ls.isClassLikeMemberCompletion(symbol, data.location, file) then
        local memberCompletionEntry, err = self:getEntryForMemberCompletion(ctx, typeChecker, symbol, name, data.location, position, contextToken, file)
        if err ~= nil then
            return nil, err
        end
        if memberCompletionEntry == nil then
            return nil, nil
        end
        insertText = memberCompletionEntry.insertText
        filterText = memberCompletionEntry.filterText
        isSnippet = memberCompletionEntry.isSnippet
        if core.Len(memberCompletionEntry.additionalTextEdits) > 0 then
            additionalTextEdits = memberCompletionEntry.additionalTextEdits
            hasAction = true
            source = ls.completionSource.ClassMemberSnippet
        end
    end

    if ls.originIsObjectLiteralMethod(origin) then
        insertText = origin:asObjectLiteralMethod().insertText
        isSnippet = origin:asObjectLiteralMethod().isSnippet
        labelDetails = origin:asObjectLiteralMethod().labelDetails
        if not ls.clientSupportsItemLabelDetails(ctx) then
            name = name .. origin:asObjectLiteralMethod().labelDetails.detail
            labelDetails = nil
        end
        source = ls.completionSource.ObjectLiteralMethodSnippet
        sortText = ls.SortBelow(sortText)
    end

    if data.isJsxIdentifierExpected and
        not data.isRightOfOpenTag and
        ls.clientSupportsItemSnippet(ctx) and
        preferences.jsxAttributeCompletionStyle ~= lsutil.JsxAttributeCompletionStyle.None and
        not (data.location.parent ~= nil and ast.IsJsxAttribute(data.location.parent) and data.location.parent:Initializer() ~= nil) then
        local useBraces2 = preferences.jsxAttributeCompletionStyle == lsutil.JsxAttributeCompletionStyle.Braces
        local t = typeChecker:GetTypeOfSymbolAtLocation(symbol, data.location)

        -- If is boolean like or undefined, don't return a snippet, we want to return just the completion.
        if preferences.jsxAttributeCompletionStyle == lsutil.JsxAttributeCompletionStyle.Auto and
            not t:IsBooleanLike() and
            not (t:IsUnion() and core.Some(t:Types(), function(u) return u:IsBooleanLike() end)) then
            if t:IsStringLike() or
                t:IsUnion() and
                core.Every(
                    t:Types(),
                    function(u)
                        return u:Flags() & (TypeFlags.StringLike | TypeFlags.Undefined) ~= 0 or
                            ls.isStringAndEmptyAnonymousObjectIntersection(typeChecker, u)
                    end
                ) then
                -- If type is string-like or undefined, use quotes.
                insertText = ls.escapeSnippetText(name) .. "=" .. ls.quote(file, preferences, "$1")
                isSnippet = true
            else
                -- Use braces for everything else.
                useBraces2 = true
            end
        end

        if useBraces2 then
            insertText = ls.escapeSnippetText(name) .. "={$1}"
            isSnippet = true
        end
    end

    local parentNamedImportOrExport = ast.FindAncestor(data.location, ls.isNamedImportsOrExports)
    if parentNamedImportOrExport ~= nil then
        if not scanner.IsIdentifierText(name, LanguageVariant.Standard) then
            insertText = ls.quotePropertyName(file, preferences, name)

            if parentNamedImportOrExport.kind == Kind.NamedImports then
                -- Check if it is `import { ^here as name } from '...'``.
                -- We have to access the scanner here to check if it is `{ ^here as name }`` or `{ ^here, as, name }`.
                local s = scanner.NewScanner()
                s:SetText(file:Text())
                s:ResetPos(position)
                if not (s:Scan() == Kind.AsKeyword and s:Scan() == Kind.Identifier) then
                    insertText = insertText .. " as " .. ls.generateIdentifierForArbitraryString(name)
                end
            end
        elseif parentNamedImportOrExport.kind == Kind.NamedImports then
            local possibleToken = scanner.StringToToken(name)
            if possibleToken ~= Kind.Unknown and
                (possibleToken == Kind.AwaitKeyword or lsutil.IsNonContextualKeyword(possibleToken)) then
                insertText = name .. " as " .. name .. "_"
            end
        end
    end

    -- Commit characters

    local elementKind = lsutil.GetSymbolKind(typeChecker, symbol, data.location)
    local commitCharacters = nil
    if ls.clientSupportsItemCommitCharacters(ctx) then
        if elementKind == ScriptElementKind.Warning or elementKind == ScriptElementKind.String then
            commitCharacters = {}
        elseif not ls.clientSupportsDefaultCommitCharacters(ctx) then
            commitCharacters = data.defaultCommitCharacters
        end
        -- Otherwise use the completion list default.
    end

    local preselect = ls.isRecommendedCompletionMatch(symbol, data.recommendedCompletion, typeChecker)
    local kindModifiers = lsutil.GetSymbolModifiers(typeChecker, symbol)

    return self:createLSPCompletionItem(
        ctx,
        name,
        insertText,
        filterText,
        sortText,
        elementKind,
        kindModifiers,
        replacementSpan,
        commitCharacters,
        labelDetails,
        file,
        position,
        isMemberCompletion,
        isSnippet,
        hasAction,
        preselect,
        source,
        nil, --[[autoImportFix]]
        additionalTextEdits,
        nil --[[detail]]
    ), nil
end

-- memberCompletionEntry: { insertText, filterText, isSnippet, additionalTextEdits }

function LanguageService:getEntryForObjectLiteralMethodCompletion(ctx, typeChecker, symbol, enclosingDeclaration, file)
    local snippetPrinter = ls.createSnippetPrinter({
        removeComments = true,
        newLine = core.GetNewLineKind(self:FormatOptions().newLineCharacter),
        target = self:GetProgram():Options():GetEmitScriptTarget(),
    }, nil --[[emitContext]])

    local isSnippet = ls.clientSupportsItemSnippet(ctx)
    local method = self:createObjectLiteralMethod(snippetPrinter, typeChecker, symbol, enclosingDeclaration, file, isSnippet)
    if method == nil then
        return nil
    end

    local insertText = snippetPrinter:printAndFormatNodeWithSettings(ctx, method, file, change.GetFormatCodeSettingsForWriting(self:FormatOptions(), file))
    insertText = insertText .. ","

    return setmetatable({
        insertText = insertText,
        labelDetails = {
            detail = self:printObjectLiteralMethodLabelDetail(method, file, snippetPrinter.factory),
        },
        isSnippet = isSnippet,
    }, ls.symbolOriginInfoObjectLiteralMethod)
end

function LanguageService:createObjectLiteralMethod(snippetPrinter, typeChecker, symbol, enclosingDeclaration, file, isSnippet)
    local factory = snippetPrinter.factory
    local emitContext = snippetPrinter.emitContext

    local declaration = core.FirstOrNil(symbol.declarations)
    if not ls.isObjectLiteralMethodCompletionCandidateDeclaration(declaration) then
        return nil
    end

    local effectiveType = typeChecker:GetWidenedType(typeChecker:GetTypeOfSymbolAtLocation(symbol, enclosingDeclaration))
    if effectiveType:Flags() & TypeFlags.Union ~= 0 and core.Len(effectiveType:Types()) < 10 then
        effectiveType = typeChecker:GetUnionTypeEx(effectiveType:Types(), checker.UnionReduction.Subtype)
    end
    if effectiveType:Flags() & TypeFlags.Union ~= 0 then
        local functionType = nil
        for _, unionType in ipairs(effectiveType:Types()) do
            if core.Len(typeChecker:GetSignaturesOfType(unionType, checker.SignatureKind.Call)) ~= 0 then
                if functionType ~= nil then
                    return nil
                end
                functionType = unionType
            end
        end
        if functionType == nil then
            return nil
        end
        effectiveType = functionType
    end

    local signatures = typeChecker:GetSignaturesOfType(effectiveType, checker.SignatureKind.Call)
    if core.Len(signatures) ~= 1 then
        return nil
    end

    local flags = nodebuilder.Flags.OmitThisParameter
    if lsutil.GetQuotePreference(file, self:UserPreferences()) == lsutil.QuotePreference.Single then
        flags = flags | nodebuilder.Flags.UseSingleQuotesForStringLiteralType
    end
    local typeNode = typeChecker:TypeToTypeNode(effectiveType, enclosingDeclaration, flags, nil --[[idToSymbol]])
    if typeNode == nil or typeNode.kind ~= Kind.FunctionType then
        return nil
    end

    local parameters = {}
    for _, parameter in ipairs(typeNode:AsFunctionTypeNode().parameters.nodes) do
        parameters[#parameters + 1] = factory:NewParameterDeclaration(
            nil, --[[modifiers]]
            parameter:AsParameterDeclaration().dotDotDotToken,
            parameter:Name():Clone(factory),
            nil, --[[questionToken]]
            nil, --[[typeNode]]
            parameter:AsParameterDeclaration().initializer
        )
    end

    local body = factory:NewBlock(factory:NewNodeList(nil --[[nodes]]), true --[[multiLine]])
    if isSnippet then
        body = ls.createSnippetTabStopBody(factory, emitContext)
    end

    return factory:NewMethodDeclaration(
        nil, --[[modifiers]]
        nil, --[[asteriskToken]]
        declaration:Name():Clone(factory),
        nil, --[[postfixToken]]
        nil, --[[typeParameters]]
        factory:NewNodeList(parameters),
        nil, --[[typeNode]]
        nil, --[[fullSignature]]
        body
    )
end

local objectLiteralMethodCandidateKinds = ast.kindSet(
    Kind.PropertySignature, Kind.PropertyDeclaration, Kind.MethodSignature, Kind.MethodDeclaration
)

function ls.isObjectLiteralMethodCompletionCandidateDeclaration(declaration)
    if declaration == nil then
        return false
    end
    return objectLiteralMethodCandidateKinds[declaration.kind] == true
end

-- objectLiteralMethodSymbol: { symbol, origin }

function LanguageService:collectObjectLiteralMethodSymbols(ctx, typeChecker, members, enclosingDeclaration, file)
    if ast.IsSourceFileJS(file) then
        return nil
    end

    local methods = nil
    for _, member in ipairs(members or {}) do
        if not ls.isObjectLiteralMethodSymbol(member) then
            goto continue
        end
        do
            local displayName = ls.getCompletionEntryDisplayNameForSymbol(member, nil --[[origin]], ls.CompletionKind.ObjectPropertyDeclaration, false --[[isJsxIdentifierExpected]])
            if displayName == "" then
                goto continue
            end
            local entry = self:getEntryForObjectLiteralMethodCompletion(ctx, typeChecker, member, enclosingDeclaration, file)
            if entry == nil then
                goto continue
            end
            methods = core.Append(methods, {
                symbol = member,
                origin = ls.newSymbolOriginInfo({
                    kind = ls.symbolOriginInfoKind.ObjectLiteralMethod,
                    data = entry,
                }),
            })
        end
        ::continue::
    end
    return methods
end

function ls.isObjectLiteralMethodSymbol(symbol)
    return symbol.flags & (SymbolFlags.Property | SymbolFlags.Method) ~= 0
end

function LanguageService:printObjectLiteralMethodLabelDetail(method, file, factory)
    local methodDeclaration = method:AsMethodDeclaration()
    local methodSignature = factory:NewMethodSignatureDeclaration(
        nil, --[[modifiers]]
        factory:NewIdentifier(""),
        methodDeclaration.postfixToken,
        methodDeclaration.typeParameters,
        methodDeclaration.parameters,
        methodDeclaration.type
    )
    local signaturePrinter = printer.NewPrinter({
        removeComments = true,
        omitTrailingSemicolon = true,
        newLine = core.GetNewLineKind(self:FormatOptions().newLineCharacter),
        target = self:GetProgram():Options():GetEmitScriptTarget(),
    }, {}, nil --[[emitContext]])
    return signaturePrinter:Emit(methodSignature, file)
end

function LanguageService:getEntryForMemberCompletion(ctx, typeChecker, symbol, name, location, position, contextToken, file)
    local classLikeDeclaration = ast.FindAncestor(location, ast.IsClassLike)
    if classLikeDeclaration == nil then
        return nil, nil
    end

    local importAdder, err = self:createImportAdder(ctx, typeChecker, file)
    if err ~= nil then
        return nil, err
    end

    local changeTracker = change.NewTracker(ctx, self:GetProgram():Options(), self:FormatOptions(), self.converters)
    local fixer = ls.newMissingMemberFixer(changeTracker, self:GetProgram(), typeChecker, self:UserPreferences(), importAdder, locale.FromContext(ctx))

    local presentModifiers = self:getPresentMemberModifiers(contextToken, file, position)
    local abstract = presentModifiers.modifiers & ModifierFlags.Abstract ~= 0 and classLikeDeclaration:ModifierFlags() & ModifierFlags.Abstract ~= 0
    local isSnippet = ls.clientSupportsItemSnippet(ctx)
    local body = changeTracker.nodeFactory:NewBlock(changeTracker.nodeFactory:NewNodeList(nil), true --[[multiLine]])
    if isSnippet then
        body = ls.createSnippetTabStopBody(changeTracker.nodeFactory, changeTracker.emitContext)
    end

    local nodes = fixer:createMemberFromSymbol(symbol, classLikeDeclaration, file, body, ls.preserveOptionalFlags.Property, abstract)
    local additionalTextEdits = nil
    if importAdder ~= nil and importAdder:HasFixes() then
        additionalTextEdits = importAdder:Edits()
    end
    if presentModifiers.eraseRange ~= nil then
        additionalTextEdits = core.Append(additionalTextEdits, {
            range = presentModifiers.eraseRange,
            newText = "",
        })
    end

    local modifiers = ModifierFlags.None
    local completionNodes = {}
    for _, node in ipairs(nodes or {}) do
        if node == nil then
            goto continue
        end
        if #completionNodes == 0 then
            modifiers = node:ModifierFlags()
            if abstract then
                modifiers = modifiers | ModifierFlags.Abstract
            end
            if ast.IsClassElement(node) and typeChecker:GetMemberOverrideModifierStatus(classLikeDeclaration, node, symbol) == checker.MemberOverrideStatus.NeedsOverride then
                modifiers = modifiers | ModifierFlags.Override
            end
        end
        completionNodes[#completionNodes + 1] = node
        ::continue::
    end

    if #completionNodes == 0 then
        return {
            insertText = name,
            filterText = name,
            isSnippet = isSnippet,
            additionalTextEdits = additionalTextEdits,
        }, nil
    end

    local allowedModifiers = modifiers | ModifierFlags.Override | ModifierFlags.Public
    if symbol.flags & SymbolFlags.Method ~= 0 then
        allowedModifiers = allowedModifiers | ModifierFlags.Async
    else
        allowedModifiers = allowedModifiers | ModifierFlags.Ambient | ModifierFlags.Readonly
    end

    local allowedAndPresent = presentModifiers.modifiers & allowedModifiers
    if presentModifiers.modifiers & ~allowedModifiers ~= 0 then
        return nil, nil
    end

    if modifiers & ModifierFlags.Protected ~= 0 and allowedAndPresent & ModifierFlags.Public ~= 0 then
        modifiers = modifiers & ~ModifierFlags.Protected
    end

    if allowedAndPresent ~= ModifierFlags.None and allowedAndPresent & ModifierFlags.Public == 0 then
        modifiers = modifiers & ~ModifierFlags.Public
    end

    modifiers = modifiers | allowedAndPresent
    local newLine = self:FormatOptions().newLineCharacter
    local snippetPrinter = ls.createSnippetPrinter({
        removeComments = true,
        newLine = core.GetNewLineKind(newLine),
        target = self:GetProgram():Options():GetEmitScriptTarget(),
    }, changeTracker.emitContext)

    local decoratedNode = nil
    if core.Len(presentModifiers.decorators) > 0 then
        local lastNodeIndex = #completionNodes - 1
        if ast.CanHaveDecorators(completionNodes[lastNodeIndex + 1]) then
            decoratedNode = completionNodes[lastNodeIndex + 1]
        end
    end

    local texts = {}
    for _, node in ipairs(completionNodes) do
        local isDecorated = node == decoratedNode
        node = ast.ReplaceModifiers(changeTracker.nodeFactory, node, ls.createModifierList(changeTracker.nodeFactory, modifiers, core.IfElse(isDecorated, presentModifiers.decorators, nil)))
        local text = snippetPrinter:printAndFormatNodeWithSettings(ctx, node, file, change.GetFormatCodeSettingsForWriting(self:FormatOptions(), file))
        texts[#texts + 1] = text
    end

    local insertText = table.concat(texts, newLine)
    if insertText == "" then
        return nil, nil
    end

    return {
        insertText = insertText,
        filterText = name,
        isSnippet = isSnippet,
        additionalTextEdits = additionalTextEdits,
    }, nil
end

-- presentMemberModifiers: { modifiers, decorators, eraseRange }

function LanguageService:getPresentMemberModifiers(contextToken, file, position)
    if contextToken == nil or ls.getLineOfPosition(file, position) > ls.getLineOfPosition(file, contextToken:End()) then
        return { modifiers = ModifierFlags.None, decorators = nil, eraseRange = nil }
    end

    local modifiers = ModifierFlags.None
    local decorators = nil
    local rangePos = position
    local rangeEnd = position

    if ast.IsPropertyDeclaration(contextToken.parent) then
        local contextModifierKind = ls.modifierLikeKind(contextToken)
        if contextModifierKind == Kind.Unknown then
            return { modifiers = ModifierFlags.None, decorators = nil, eraseRange = nil }
        end

        local modifierNodes = contextToken.parent:ModifierNodes()
        if core.Len(modifierNodes) > 0 then
            modifiers = modifiers | (ast.ModifiersToFlags(modifierNodes) & ModifierFlags.Modifier)
            for _, modifier in ipairs(modifierNodes) do
                if ast.IsDecorator(modifier) then
                    decorators = core.Append(decorators, modifier)
                end
                rangePos = math.min(rangePos, scanner.GetTokenPosOfNode(modifier, file, false --[[includeJSDoc]]))
            end
        end

        local contextModifierFlag = ast.ModifierToFlag(contextModifierKind)
        if modifiers & contextModifierFlag == 0 then
            modifiers = modifiers | contextModifierFlag
            rangePos = math.min(rangePos, astnav.GetStartOfNode(contextToken, file, false --[[includeJSDoc]]))
        end

        if contextToken.parent:Name() ~= contextToken then
            rangeEnd = astnav.GetStartOfNode(contextToken.parent:Name(), file, false --[[includeJSDoc]])
        end
    end

    local eraseRange = nil
    if rangePos < rangeEnd then
        local lspRange, fidelity = self:createLspRangeFromBounds(rangePos, rangeEnd, file)
        if isExact(fidelity) then
            eraseRange = lspRange
        end
    end

    return {
        modifiers = modifiers,
        decorators = decorators,
        eraseRange = eraseRange,
    }
end

function ls.modifierLikeKind(node)
    if node == nil then
        return Kind.Unknown
    end
    if ast.IsModifier(node) then
        return node.kind
    end
    if ast.IsIdentifier(node) then
        local keywordKind = scanner.IdentifierToKeywordKind(node:AsIdentifier())
        if keywordKind ~= Kind.Unknown and ast.IsModifierKind(keywordKind) then
            return keywordKind
        end
    end
    return Kind.Unknown
end

function ls.createModifierList(factory, flags, decorators)
    local nodes = {}
    for _, decorator in ipairs(decorators or {}) do
        nodes[#nodes + 1] = decorator:Clone(factory)
    end
    for _, m in ipairs(ast.CreateModifiersFromModifierFlags(flags, function(kind) return factory:NewModifier(kind) end) or {}) do
        nodes[#nodes + 1] = m
    end
    if #nodes == 0 then
        return nil
    end
    return factory:NewModifierList(nodes)
end

function ls.createSnippetTabStopBody(factory, emitContext)
    local emptyStatement = factory:NewEmptyStatement()
    emitContext:SetSnippetElement(emptyStatement, {
        kind = printer.SnippetKind.TabStop,
        order = 0,
    })
    return factory:NewBlock(factory:NewNodeList({ emptyStatement }), true --[[multiLine]])
end

function LanguageService:createImportAdder(ctx, typeChecker, file)
    if tspath.IsDynamicFileName(file:FileName()) then
        return nil, nil
    end
    local view, err = self:getPreparedAutoImportView(file)
    if err ~= nil then
        return nil, err
    end
    if view == nil then
        return nil, nil
    end
    return autoimport.NewImportAdder(ctx, self:GetProgram(), typeChecker, file, view, self:FormatOptions(), self.converters, self:UserPreferences()), nil
end

function ls.isRecommendedCompletionMatch(localSymbol, recommendedCompletion, typeChecker)
    return localSymbol == recommendedCompletion or
        localSymbol.flags & SymbolFlags.ExportValue ~= 0 and typeChecker:GetExportSymbolOfSymbol(localSymbol) == recommendedCompletion
end

-- Ported from vscode.
ls.wordSeparators = {}
for _, c in ipairs({
    "`", "~", "!", "@", "%", "^", "&", "*", "(", ")", "-", "=", "+", "[", "{", "]", "}", "\\", "|",
    ";", ":", "'", "\"", ",", ".", "<", ">", "/", "?",
}) do
    ls.wordSeparators[string.byte(c)] = true
end

-- Finds the length and first rune of the word that ends at the given position.
-- e.g. for "abc def.ghi|jkl", the word length is 3 and the word start is 'g'.
function ls.getWordLengthAndStart(sourceFile, position)
    -- !!! Port other case of vscode's `DEFAULT_WORD_REGEXP` that covers words that start like numbers, e.g. -123.456abcd.
    local text = string.sub(sourceFile:Text(), 1, position)
    local totalSize = 0
    local firstRune = 0
    local r, size = stringutil.DecodeLastRune(text, #text)
    while size ~= 0 do
        if ls.wordSeparators[r] or stringutil.UnicodeIsSpace(r) then
            break
        end
        totalSize = totalSize + size
        firstRune = r
        r, size = stringutil.DecodeLastRune(text, #text - totalSize)
    end
    -- If word starts with `@`, disregard this first character.
    if firstRune == string.byte("@") then
        totalSize = totalSize - 1
        firstRune = stringutil.DecodeRune(text, #text - totalSize)
    end
    return totalSize, firstRune
end

-- `["ab c"]` -> `ab c`
-- `['ab c']` -> `ab c`
-- `[123]` -> `123`
function ls.trimElementAccess(text)
    text = trimPrefix(text, "[")
    text = trimSuffix(text, "]")
    if hasPrefix(text, "'") and hasSuffix(text, "'") then
        text = trimPrefix(trimSuffix(text, "'"), "'")
    end
    if hasPrefix(text, "\"") and hasSuffix(text, "\"") then
        text = trimPrefix(trimSuffix(text, "\""), "\"")
    end
    return text
end

-- Ported from vscode ts extension: `getFilterText`.
function ls.getFilterText(
    file, -- luacheck: ignore 212
    position, -- luacheck: ignore 212
    insertText,
    label,
    wordStart,
    dotAccessor
)
    -- Private field completion, e.g. label `#bar`.
    local after, ok = cutPrefix(label, "#")
    if ok then
        if insertText ~= "" then
            local after2, ok2 = cutPrefix(insertText, "this.#")
            if ok2 then
                if wordStart == string.byte("#") then
                    -- `method() { this.#| }`
                    -- `method() { #| }`
                    return ""
                else
                    -- `method() { this.| }`
                    -- `method() { | }`
                    return after2
                end
            end
        else
            if wordStart == string.byte("#") then
                -- `method() { this.#| }`
                return ""
            else
                -- `method() { this.| }`
                -- `method() { | }`
                return after
            end
        end
    end

    -- For `this.` completions, generally don't set the filter text since we don't want them to be overly deprioritized. microsoft/vscode#74164
    if hasPrefix(insertText, "this.") then
        return ""
    end

    -- Handle the case:
    -- ```
    -- const xyz = { 'ab c': 1 };
    -- xyz.ab|
    -- ```
    -- In which case we want to insert a bracket accessor but should use `.abc` as the filter text instead of
    -- the bracketed insert text.
    if hasPrefix(insertText, "[") then
        return dotAccessor .. ls.trimElementAccess(insertText)
    end

    if hasPrefix(insertText, "?.") then
        -- Handle this case like the case above:
        -- ```
        -- const xyz = { 'ab c': 1 } | undefined;
        -- xyz.ab|
        -- ```
        -- filterText should be `.ab c` instead of `?.['ab c']`.
        if hasPrefix(insertText, "?.[") then
            return dotAccessor .. ls.trimElementAccess(string.sub(insertText, 3))
        else
            -- ```
            -- const xyz = { abc: 1 } | undefined;
            -- xyz.ab|
            -- ```
            -- filterText should be `.abc` instead of `?.abc.
            return dotAccessor .. string.sub(insertText, 3)
        end
    end

    -- In all other cases, fall back to using the insertText.
    return insertText
end

-- Ported from vscode's `provideCompletionItems`.
function ls.getDotAccessor(file, position)
    local text = string.sub(file:Text(), 1, position)
    local totalSize = 0
    if hasSuffix(text, "?.") then
        totalSize = totalSize + 2
        return string.sub(file:Text(), position - totalSize + 1, position)
    end
    if hasSuffix(text, ".") then
        totalSize = totalSize + 1
        return string.sub(file:Text(), position - totalSize + 1, position)
    end
    return ""
end

-- Go *string helpers: a nil Lua value is a nil pointer.
function ls.strPtrIsEmpty(ptr)
    if ptr == nil then
        return true
    end
    return ptr == ""
end

function ls.strPtrTo(v)
    if v == "" then
        return nil
    end
    return v
end

function ls.boolToPtr(v)
    if v then
        return true
    end
    return nil
end

function ls.getLineOfPosition(file, pos)
    local line = scanner.GetECMALineOfPosition(file, pos)
    return line
end

function ls.getLineEndOfPosition(file, pos)
    local line = ls.getLineOfPosition(file, pos)
    local lineStarts = scanner.GetECMALineStarts(file)
    local lastCharPos
    if line + 1 >= #lineStarts then
        lastCharPos = file:End()
    else
        lastCharPos = lineStarts[line + 2] - 1
    end
    local fullText = file:Text()
    if lastCharPos > 0 and lastCharPos < #fullText and string.byte(fullText, lastCharPos + 1) == 10 --[[\n]] and
        string.byte(fullText, lastCharPos) == 13 --[[\r]] then
        return lastCharPos - 1
    end
    return lastCharPos
end

function ls.isClassLikeMemberCompletion(symbol, location, file)
    if ast.IsInJSFile(location) then
        return false
    end
    local memberFlags = SymbolFlags.ClassMember & SymbolFlags.EnumMemberExcludes
    return symbol.flags & memberFlags ~= 0 and
        (ast.IsClassLike(location) or
            (location.parent ~= nil and location.parent.parent ~= nil and ast.IsClassElement(location.parent) and
                location == location.parent:Name() and lsutil.GetLastToken(location.parent, file) == location.parent:Name() and
                ast.IsClassLike(location.parent.parent)) or
            (location.parent ~= nil and ast.IsSyntaxList(location) and ast.IsClassLike(location.parent)))
end

function ls.symbolAppearsToBeTypeOnly(symbol, typeChecker)
    local flags = checker.SkipAlias(symbol, typeChecker):CombinedLocalAndExportSymbolFlags()
    return flags & SymbolFlags.Value == 0 and
        (core.Len(symbol.declarations) == 0 or not ast.IsInJSFile(symbol.declarations[1]) or flags & SymbolFlags.Type ~= 0)
end

function ls.shouldIncludeSymbol(
    symbol,
    data,
    closestSymbolDeclaration,
    file,
    typeChecker,
    compilerOptions
)
    local allFlags = symbol.flags
    local location = data.location
    -- export = /**/ here we want to get all meanings, so any symbol is ok
    if location.parent ~= nil and ast.IsExportAssignment(location.parent) then
        return true
    end

    -- Filter out variables from their own initializers
    -- `const a = /* no 'a' here */`
    if closestSymbolDeclaration ~= nil and
        ast.IsVariableDeclaration(closestSymbolDeclaration) and
        symbol.valueDeclaration == closestSymbolDeclaration then
        return false
    end

    -- Filter out current and latter parameters from defaults
    -- `function f(a = /* no 'a' and 'b' here */, b) { }` or
    -- `function f<T = /* no 'T' and 'T2' here */>(a: T, b: T2) { }`
    local symbolDeclaration = nil
    if symbol.valueDeclaration ~= nil then
        symbolDeclaration = symbol.valueDeclaration
    elseif core.Len(symbol.declarations) > 0 then
        symbolDeclaration = symbol.declarations[1]
    end

    if closestSymbolDeclaration ~= nil and symbolDeclaration ~= nil then
        if ast.IsParameterDeclaration(closestSymbolDeclaration) and ast.IsParameterDeclaration(symbolDeclaration) then
            local parameters = closestSymbolDeclaration.parent:ParameterList()
            if symbolDeclaration:Pos() >= closestSymbolDeclaration:Pos() and
                symbolDeclaration:Pos() < parameters:End() then
                return false
            end
        elseif ast.IsTypeParameterDeclaration(closestSymbolDeclaration) and
            ast.IsTypeParameterDeclaration(symbolDeclaration) then
            if closestSymbolDeclaration == symbolDeclaration and data.contextToken ~= nil and data.contextToken.kind == Kind.ExtendsKeyword then
                -- filter out the directly self-recursive type parameters
                -- `type A<K extends /* no 'K' here*/> = K`
                return false
            end
            if ls.isInTypeParameterDefault(data.contextToken) and not ast.IsInferTypeNode(closestSymbolDeclaration.parent) then
                local typeParameters = closestSymbolDeclaration.parent:TypeParameterList()
                if typeParameters ~= nil and symbolDeclaration:Pos() >= closestSymbolDeclaration:Pos() and
                    symbolDeclaration:Pos() < typeParameters:End() then
                    return false
                end
            end
        end
    end

    -- External modules can have global export declarations that will be
    -- available as global keywords in all scopes. But if the external module
    -- already has an explicit export and user only wants to use explicit
    -- module imports then the global keywords will be filtered out so auto
    -- import suggestions will win in the completion.
    local symbolOrigin = checker.SkipAlias(symbol, typeChecker)
    -- We only want to filter out the global keywords.
    -- Auto Imports are not available for scripts so this conditional is always false.
    if file:AsSourceFile().externalModuleIndicator ~= nil and
        compilerOptions.allowUmdGlobalAccess ~= core.Tristate.TSTrue and
        symbol ~= symbolOrigin and
        data.symbolToSortTextMap ~= nil and
        data.symbolToSortTextMap[ast.GetSymbolId(symbol)] == ls.SortText.GlobalsOrKeywords and
        symbol.parent ~= nil and checker.IsExternalModuleSymbol(symbol.parent) then
        return false
    end

    allFlags = allFlags | symbolOrigin:CombinedLocalAndExportSymbolFlags()
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        allFlags = allFlags | typeChecker:GetSymbolFlags(symbol)
    end

    -- import m = /**/ <-- It can only access namespace (if typing import = x. this would get member symbols and not namespace)
    if ls.isInRightSideOfInternalImportEqualsDeclaration(data.location) then
        return allFlags & SymbolFlags.Namespace ~= 0
    end

    if data.isTypeOnlyLocation then
        -- It's a type, but you can reach it by namespace.type as well.
        return ls.symbolCanBeReferencedAtTypeLocation(symbol, typeChecker, collections.NewSet())
    end

    -- expressions are value space (which includes the value namespaces)
    return allFlags & SymbolFlags.Value ~= 0
end

function ls.getCompletionEntryDisplayNameForSymbol(
    symbol,
    origin,
    completionKind,
    isJsxIdentifierExpected
)
    if ls.originIsIgnore(origin) then
        return "", false
    end

    local name
    if ls.originIncludesSymbolName(origin) then
        name = origin:symbolName()
    else
        name = ast.SymbolName(symbol)
    end
    if name == "" or
        -- If the symbol is external module, don't show it in the completion list
        -- (i.e declare module "http" { const x; } | // <= request completion here, "http" should not be there)
        symbol.flags & SymbolFlags.Module ~= 0 and ls.startsWithQuote(name) or
        -- If the symbol is the internal name of an ES symbol, it is not a valid entry. Internal names for ES symbols start with "__@"
        checker.IsKnownSymbol(symbol) then
        return "", false
    end

    local variant = core.IfElse(isJsxIdentifierExpected, LanguageVariant.JSX, LanguageVariant.Standard)
    -- name is a valid identifier or private identifier text
    if scanner.IsIdentifierText(name, variant) or
        symbol.valueDeclaration ~= nil and ast.IsPrivateIdentifierClassElementDeclaration(symbol.valueDeclaration) then
        return name, false
    end
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        -- Allow non-identifier import/export aliases since we can insert them as string literals
        return name, true
    end

    local CompletionKind = ls.CompletionKind
    if completionKind == CompletionKind.MemberLike then
        if ls.originIsComputedPropertyName(origin) then
            return origin:symbolName(), false
        end
        return "", false
    elseif completionKind == CompletionKind.ObjectPropertyDeclaration then
        -- TODO: microsoft/TypeScript#18169
        local escapedName = core.StringifyJson(name, "", "")
        return escapedName, false
    elseif completionKind == CompletionKind.PropertyAccess or completionKind == CompletionKind.Global then
        -- For a 'this.' completion it will be in a global context, but may have a non-identifier name.
        -- Don't add a completion for a name starting with a space. See https://github.com/Microsoft/TypeScript/pull/20547
        local ch = stringutil.DecodeRune(name, 0)
        if ch == string.byte(" ") then
            return "", false
        end
        return name, true
    elseif completionKind == CompletionKind.None or completionKind == CompletionKind.String then
        return name, false
    else
        error("Unexpected completion kind: " .. tostring(completionKind))
    end
end

-- !!! refactor symbolOriginInfo so that we can tell the difference between flags and the kind of data it has
function ls.originIsIgnore(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.Ignore ~= 0
end

function ls.originIncludesSymbolName(origin)
    return ls.originIsComputedPropertyName(origin)
end

function ls.originIsComputedPropertyName(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.ComputedPropertyName ~= 0
end

function ls.originIsObjectLiteralMethod(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.ObjectLiteralMethod ~= 0
end

function ls.originIsThisTypeNode(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.ThisType ~= 0
end

function ls.originIsTypeOnlyAlias(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.TypeOnlyAlias ~= 0
end

function ls.originIsSymbolMember(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.SymbolMember ~= 0
end

function ls.originIsNullableMember(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.Nullable ~= 0
end

function ls.originIsPromise(origin)
    return origin ~= nil and origin.kind & ls.symbolOriginInfoKind.Promise ~= 0
end

function ls.getSourceFromOrigin(origin)
    if ls.originIsThisTypeNode(origin) then
        return ls.completionSource.ThisProperty
    end

    if ls.originIsTypeOnlyAlias(origin) then
        return ls.completionSource.TypeOnlyAlias
    end

    return ""
end

-- In a scenarion such as `const x = 1 * |`, the context and previous tokens are both `*`.
-- In `const x = 1 * o|`, the context token is *, and the previous token is `o`.
-- `contextToken` and `previousToken` can both be nil if we are at the beginning of the file.
function ls.getRelevantTokens(position, file)
    local previousToken = astnav.FindPrecedingToken(file, position)
    if previousToken ~= nil and position <= previousToken:End() and (ast.IsMemberName(previousToken) or ast.IsKeywordKind(previousToken.kind)) then
        local contextToken = astnav.FindPrecedingToken(file, previousToken:Pos())
        return contextToken, previousToken
    end
    return previousToken, previousToken
end

-- "." | '"' | "'" | "`" | "/" | "@" | "<" | "#" | " " | "*"
-- type CompletionsTriggerCharacter = string

function ls.isValidTrigger(file, triggerCharacter, contextToken, position)
    if triggerCharacter == "." or triggerCharacter == "@" then
        return true
    elseif triggerCharacter == "\"" or triggerCharacter == "'" or triggerCharacter == "`" then
        -- Only automatically bring up completions if this is an opening quote.
        return contextToken ~= nil and
            ls.isStringLiteralOrTemplate(contextToken) and
            position == astnav.GetStartOfNode(contextToken, file, false --[[includeJSDoc]]) + 1
    elseif triggerCharacter == "#" then
        return contextToken ~= nil and
            ast.IsPrivateIdentifier(contextToken) and
            ast.GetContainingClass(contextToken) ~= nil
    elseif triggerCharacter == "<" then
        -- Opening JSX tag
        return contextToken ~= nil and
            contextToken.kind == Kind.LessThanToken and
            (not ast.IsBinaryExpression(contextToken.parent) or ls.binaryExpressionMayBeOpenTag(contextToken.parent:AsBinaryExpression()))
    elseif triggerCharacter == "/" then
        if contextToken == nil then
            return false
        end
        if ast.IsStringLiteralLike(contextToken) then
            return ast.TryGetImportFromModuleSpecifier(contextToken) ~= nil
        end
        return contextToken.kind == Kind.LessThanSlashToken and ast.IsJsxClosingElement(contextToken.parent)
    elseif triggerCharacter == " " then
        return contextToken ~= nil and contextToken.kind == Kind.ImportKeyword and contextToken.parent.kind == Kind.SourceFile
    elseif triggerCharacter == "*" then
        return ls.isPotentiallyValidJSDocSnippetCompletionPosition(file, position)
    else
        error("Unknown trigger character: " .. triggerCharacter)
    end
end

local stringLiteralOrTemplateKinds = ast.kindSet(
    Kind.StringLiteral, Kind.NoSubstitutionTemplateLiteral, Kind.TemplateExpression,
    Kind.TaggedTemplateExpression
)

function ls.isStringLiteralOrTemplate(node)
    return stringLiteralOrTemplateKinds[node.kind] == true
end

function ls.binaryExpressionMayBeOpenTag(binaryExpression)
    return ast.NodeIsMissing(binaryExpression.left)
end

function ls.isCheckedFile(file, compilerOptions)
    return not ast.IsSourceFileJS(file) or ast.IsCheckJSEnabledForFile(file, compilerOptions)
end

function ls.isContextTokenValueLocation(contextToken)
    return contextToken ~= nil and ((contextToken.kind == Kind.TypeOfKeyword and
        (contextToken.parent.kind == Kind.TypeQuery or ast.IsTypeOfExpression(contextToken.parent))) or
        (contextToken.kind == Kind.AssertsKeyword and contextToken.parent.kind == Kind.TypePredicate))
end

function ls.isPossiblyTypeArgumentPosition(token, sourceFile, typeChecker)
    local info = ls.getPossibleTypeArgumentsInfo(token, sourceFile)
    return info ~= nil and (ast.IsPartOfTypeNode(info.called) or
        core.Len(ls.getPossibleGenericSignatures(info.called, info.nTypeArguments, typeChecker)) ~= 0 or
        ls.isPossiblyTypeArgumentPosition(info.called, sourceFile, typeChecker))
end

function ls.isContextTokenTypeLocation(contextToken)
    if contextToken ~= nil then
        local parentKind = contextToken.parent.kind
        local k = contextToken.kind
        if k == Kind.ColonToken then
            return parentKind == Kind.PropertyDeclaration or
                parentKind == Kind.PropertySignature or
                parentKind == Kind.Parameter or
                parentKind == Kind.VariableDeclaration or
                ast.IsFunctionLikeKind(parentKind)
        elseif k == Kind.EqualsToken then
            return parentKind == Kind.TypeAliasDeclaration or parentKind == Kind.TypeParameter
        elseif k == Kind.AsKeyword then
            return parentKind == Kind.AsExpression
        elseif k == Kind.LessThanToken then
            return parentKind == Kind.TypeReference or parentKind == Kind.TypeAssertionExpression
        elseif k == Kind.ExtendsKeyword then
            return parentKind == Kind.TypeParameter
        elseif k == Kind.SatisfiesKeyword then
            return parentKind == Kind.SatisfiesExpression
        end
    end
    return false
end

-- True if symbol is a type or a module containing at least one type.
-- seenModules is a Go collections.Set passed by value (see copySet).
function ls.symbolCanBeReferencedAtTypeLocation(symbol, typeChecker, seenModules)
    -- Since an alias can be merged with a local declaration, we need to test both the alias and its target.
    -- This code used to just test the result of `skipAlias`, but that would ignore any locally introduced meanings.
    return ls.nonAliasCanBeReferencedAtTypeLocation(symbol, typeChecker, copySet(seenModules)) or
        ls.nonAliasCanBeReferencedAtTypeLocation(
            checker.SkipAlias(core.IfElse(symbol.exportSymbol ~= nil, symbol.exportSymbol, symbol), typeChecker),
            typeChecker,
            copySet(seenModules)
        )
end

function ls.nonAliasCanBeReferencedAtTypeLocation(symbol, typeChecker, seenModules)
    return symbol.flags & SymbolFlags.Type ~= 0 or typeChecker:IsUnknownSymbol(symbol) or
        symbol.flags & SymbolFlags.Module ~= 0 and seenModules:AddIfAbsent(ast.GetSymbolId(symbol)) and
        core.Some(
            typeChecker:GetExportsOfModule(symbol),
            function(e) return ls.symbolCanBeReferencedAtTypeLocation(e, typeChecker, copySet(seenModules)) end
        )
end

-- Gets all properties on a type, but if that type is a union of several types,
-- excludes array-like types or callable/constructable types.
function ls.getPropertiesForCompletion(t, typeChecker)
    if t:IsUnion() then
        return core.CheckEachDefined(typeChecker:GetAllPossiblePropertiesOfTypes(t:Types()), "getAllPossiblePropertiesOfTypes() should all be defined.")
    else
        return core.CheckEachDefined(typeChecker:GetApparentProperties(t), "getApparentProperties() should all be defined.")
    end
end

-- Given 'a.b.c', returns 'a'.
function ls.getLeftMostName(e)
    if ast.IsIdentifier(e) then
        return e
    elseif ast.IsPropertyAccessExpression(e) then
        return ls.getLeftMostName(e:Expression())
    else
        return nil
    end
end

function ls.getFirstSymbolInChain(symbol, enclosingDeclaration, typeChecker)
    local chain = typeChecker:GetAccessibleSymbolChain(
        symbol,
        enclosingDeclaration,
        SymbolFlags.All, --[[meaning]]
        false --[[useOnlyExternalAliasing]]
    )
    if core.Len(chain) > 0 then
        return chain[1]
    end
    if symbol.parent ~= nil then
        if ls.isModuleSymbol(symbol.parent) then
            return symbol
        end
        return ls.getFirstSymbolInChain(symbol.parent, enclosingDeclaration, typeChecker)
    end
    return nil
end

function ls.isModuleSymbol(symbol)
    return core.Some(symbol.declarations, function(decl) return decl.kind == Kind.SourceFile end)
end

function ls.getNullableSymbolOriginInfoKind(kind, insertQuestionDot)
    if insertQuestionDot then
        kind = kind | ls.symbolOriginInfoKind.Nullable
    end
    return kind
end

function ls.isStaticProperty(symbol)
    return symbol.valueDeclaration ~= nil and
        symbol.valueDeclaration:ModifierFlags() & ModifierFlags.Static ~= 0 and
        ast.IsClassLike(symbol.valueDeclaration.parent)
end

-- getContextualTypeForConditionalExpression handles completion within a conditional expression
-- (ternary operator) by using the parent expression to find the contextual type.
function ls.getContextualTypeForConditionalExpression(conditionalExpr, position, file, typeChecker)
    local argInfo = ls.getArgumentInfoForCompletions(conditionalExpr, position, file, typeChecker)
    if argInfo ~= nil then
        return typeChecker:GetContextualTypeForArgumentAtIndex(argInfo.invocation, argInfo.argumentIndex)
    end
    -- Fall through to regular contextual type logic if not in an argument
    local contextualType = typeChecker:GetContextualType(conditionalExpr, ContextFlags.IgnoreNodeInferences)
    if contextualType ~= nil then
        return contextualType
    end
    return typeChecker:GetContextualType(conditionalExpr, ContextFlags.None)
end

function ls.getContextualType(previousToken, position, file, typeChecker)
    local parent = previousToken.parent
    local k = previousToken.kind
    if k == Kind.Identifier then
        return ls.getContextualTypeFromParent(previousToken, typeChecker, ContextFlags.None)
    elseif k == Kind.EqualsToken then
        if parent.kind == Kind.VariableDeclaration then
            return typeChecker:GetContextualType(parent:Initializer(), ContextFlags.None)
        elseif parent.kind == Kind.BinaryExpression then
            return typeChecker:GetTypeAtLocation(parent:AsBinaryExpression().left)
        elseif parent.kind == Kind.JsxAttribute then
            return typeChecker:GetContextualTypeForJsxAttribute(parent)
        else
            return nil
        end
    elseif k == Kind.NewKeyword then
        return typeChecker:GetContextualType(parent, ContextFlags.None)
    elseif k == Kind.CaseKeyword then
        local caseClause = core.IfElse(ast.IsCaseClause(parent), parent, nil)
        if caseClause ~= nil then
            return ls.getSwitchedType(caseClause, typeChecker)
        end
        return nil
    elseif k == Kind.OpenBraceToken then
        if ast.IsJsxExpression(parent) and not ast.IsJsxElement(parent.parent) and not ast.IsJsxFragment(parent.parent) then
            return typeChecker:GetContextualTypeForJsxAttribute(parent.parent)
        end
        return nil
    elseif k == Kind.OpenBracketToken then
        -- When completing after `[` in an array literal (e.g., `[/*here*/]`),
        -- we should provide contextual type for the first element
        if ast.IsArrayLiteralExpression(parent) then
            local contextualArrayType = typeChecker:GetContextualType(parent, ContextFlags.None)
            if contextualArrayType ~= nil then
                -- Get the type for the first element (index 0)
                return typeChecker:GetContextualTypeForArrayLiteralAtPosition(contextualArrayType, parent, position)
            end
        end
        return nil
    elseif k == Kind.CloseBracketToken then
        -- When completing after `]` (e.g., `[x]/*here*/`), we should not provide a contextual type
        -- for the closing bracket token itself. Without this case, CloseBracketToken would fall through
        -- to the default case, and if the parent is an array literal, GetContextualType would try to
        -- find the token's index in the array elements (returning -1), leading to an out-of-bounds panic
        -- in getContextualTypeForElementExpression.
        return nil
    elseif k == Kind.QuestionToken then
        -- When completing after `?` in a ternary conditional (e.g., `foo(a ? /*here*/)`),
        -- we need to look at the parent conditional expression to find the contextual type.
        if ast.IsConditionalExpression(parent) then
            return ls.getContextualTypeForConditionalExpression(parent, position, file, typeChecker)
        end
        return nil
    elseif k == Kind.ColonToken then
        -- When completing after `:` in a ternary conditional (e.g., `foo(a ? b : /*here*/)`),
        -- we need to look at the parent conditional expression to find the contextual type.
        -- Only handle this if parent is ConditionalExpression, otherwise fall through to default
        -- (colons are used in other contexts like object literals, type annotations, etc.)
        if ast.IsConditionalExpression(parent) then
            return ls.getContextualTypeForConditionalExpression(parent, position, file, typeChecker)
        end
    elseif k == Kind.CommaToken then
        -- When completing after `,` in an array literal (e.g., `[x, /*here*/]`),
        -- we should provide contextual type for the element after the comma.
        if ast.IsArrayLiteralExpression(parent) then
            local contextualArrayType = typeChecker:GetContextualType(parent, ContextFlags.None)
            if contextualArrayType ~= nil then
                return typeChecker:GetContextualTypeForArrayLiteralAtPosition(contextualArrayType, parent, position)
            end
            return nil
        end
    end
    -- Default case: see if we're in an argument position.
    local argInfo = ls.getArgumentInfoForCompletions(previousToken, position, file, typeChecker)
    if argInfo ~= nil then
        return typeChecker:GetContextualTypeForArgumentAtIndex(argInfo.invocation, argInfo.argumentIndex)
    elseif ls.isEqualityOperatorKind(previousToken.kind) and ast.IsBinaryExpression(parent) and
        ls.isEqualityOperatorKind(parent:AsBinaryExpression().operatorToken.kind) then
        -- completion at `x ===/**/`
        return typeChecker:GetTypeAtLocation(parent:AsBinaryExpression().left)
    else
        local contextualType = typeChecker:GetContextualType(previousToken, ContextFlags.IgnoreNodeInferences)
        if contextualType ~= nil then
            return contextualType
        end
        return typeChecker:GetContextualType(previousToken, ContextFlags.None)
    end
end

function ls.getSwitchedType(caseClause, typeChecker)
    return typeChecker:GetTypeAtLocation(caseClause.parent.parent:Expression())
end

function ls.isEqualityOperatorKind(kind)
    return kind == Kind.EqualsEqualsEqualsToken or kind == Kind.EqualsEqualsToken or
        kind == Kind.ExclamationEqualsEqualsToken or kind == Kind.ExclamationEqualsToken
end

-- We disregard boolean literals for completion purposes.
function ls.isLiteral(t)
    return t:IsStringLiteral() or t:IsNumberLiteral() or t:IsBigIntLiteral()
end

function ls.getRecommendedCompletion(previousToken, contextualType, typeChecker)
    local types
    if contextualType:IsUnion() then
        types = contextualType:Types()
    else
        types = { contextualType }
    end
    -- For a union, return the first one with a recommended completion.
    return core.FirstNonNil(
        types,
        function(t)
            local symbol = t:Symbol()
            -- Don't make a recommended completion for an abstract class.
            if symbol ~= nil and
                symbol.flags & (SymbolFlags.EnumMember | SymbolFlags.Enum | SymbolFlags.Class) ~= 0 and
                not ls.isAbstractConstructorSymbol(symbol) then
                return ls.getFirstSymbolInChain(symbol, previousToken, typeChecker)
            end
            return nil
        end
    )
end

function ls.isAbstractConstructorSymbol(symbol)
    if symbol.flags & SymbolFlags.Class ~= 0 then
        local declaration = ast.GetClassLikeDeclarationOfSymbol(symbol)
        return declaration ~= nil and ast.HasSyntacticModifier(declaration, ModifierFlags.Abstract)
    end
    return false
end

function ls.startsWithQuote(s)
    local r = stringutil.DecodeRune(s, 0)
    return r == string.byte("\"") or r == string.byte("'")
end

function ls.getClosestSymbolDeclaration(contextToken, location)
    if contextToken == nil then
        return nil
    end

    local closestDeclaration = ast.FindAncestorOrQuit(contextToken, function(node)
        if ast.IsFunctionBlock(node) or ls.isArrowFunctionBody(node) or ast.IsBindingPattern(node) then
            return FindAncestorResult.FindAncestorQuit
        end

        if (ast.IsParameterDeclaration(node) or ast.IsTypeParameterDeclaration(node)) and
            not ast.IsIndexSignatureDeclaration(node.parent) then
            return FindAncestorResult.FindAncestorTrue
        end
        return FindAncestorResult.FindAncestorFalse
    end)

    if closestDeclaration == nil then
        closestDeclaration = ast.FindAncestorOrQuit(location, function(node)
            if ast.IsFunctionBlock(node) or ls.isArrowFunctionBody(node) or ast.IsBindingPattern(node) then
                return FindAncestorResult.FindAncestorQuit
            end

            if ast.IsVariableDeclaration(node) then
                return FindAncestorResult.FindAncestorTrue
            end
            return FindAncestorResult.FindAncestorFalse
        end)
    end
    return closestDeclaration
end

function ls.isArrowFunctionBody(node)
    return node.parent ~= nil and ast.IsArrowFunction(node.parent) and
        (node.parent:Body() == node or
            -- const a = () => /**/;
            node.kind == Kind.EqualsGreaterThanToken)
end

function ls.isInTypeParameterDefault(contextToken)
    if contextToken == nil then
        return false
    end

    local node = contextToken
    local parent = contextToken.parent
    while parent ~= nil do
        if ast.IsTypeParameterDeclaration(parent) then
            return parent:AsTypeParameterDeclaration().defaultType == node or node.kind == Kind.EqualsToken
        end
        node = parent
        parent = parent.parent
    end

    return false
end

function ls.isDeprecated(symbol, typeChecker)
    local declarations = checker.SkipAlias(symbol, typeChecker).declarations
    return core.Len(declarations) > 0 and core.Every(declarations, function(decl) return typeChecker:IsDeprecatedDeclaration(decl) end)
end

function LanguageService:getReplacementRangeForContextToken(file, contextToken, position)
    if contextToken == nil then
        return nil
    end

    -- !!! ensure range is single line
    if contextToken.kind == Kind.StringLiteral or contextToken.kind == Kind.NoSubstitutionTemplateLiteral then
        return self:createRangeFromStringLiteralLikeContent(file, contextToken, position)
    else
        local lspRange, fidelity = self:createLspRangeFromNode(contextToken, file)
        if not isExact(fidelity) then
            return nil
        end
        return lspRange
    end
end

function LanguageService:createRangeFromStringLiteralLikeContent(file, node, position)
    local replacementEnd = node:End() - 1
    local nodeStart = astnav.GetStartOfNode(node, file, false --[[includeJSDoc]])
    if ast.IsUnterminatedLiteral(node) then
        -- we return no replacement range only if unterminated string is empty
        if nodeStart == replacementEnd then
            return nil
        end
        replacementEnd = math.min(position, node:End())
    end
    local lspRange, fidelity = self:createLspRangeFromBounds(nodeStart + 1, replacementEnd, file)
    if not isExact(fidelity) then
        return nil
    end
    return lspRange
end

function ls.quotePropertyName(file, preferences, name)
    local r = stringutil.DecodeRune(name, 0)
    if unicodeIsDigit(r) then
        return name
    end
    return ls.quote(file, preferences, name)
end

-- Checks whether type is `string & {}`, which is semantically equivalent to string but
-- is not reduced by the checker as a special case used for supporting string literal completions
-- for string type.
function ls.isStringAndEmptyAnonymousObjectIntersection(typeChecker, t)
    if not t:IsIntersection() then
        return false
    end

    local types = t:Types()
    return #types == 2 and
        (ls.areIntersectedTypesAvoidingStringReduction(typeChecker, types[1], types[2]) or
            ls.areIntersectedTypesAvoidingStringReduction(typeChecker, types[2], types[1]))
end

function ls.areIntersectedTypesAvoidingStringReduction(typeChecker, t1, t2)
    return t1:IsString() and typeChecker:IsEmptyAnonymousObjectType(t2)
end

function ls.escapeSnippetText(text)
    return (string.gsub(text, "%$", "\\$"))
end

function ls.isNamedImportsOrExports(node)
    return ast.IsNamedImports(node) or ast.IsNamedExports(node)
end

function ls.generateIdentifierForArbitraryString(text)
    local needsUnderscore = false
    local identifier = {}
    local ch
    local size

    -- Convert "(example, text)" into "_example_text_"
    local pos = 0
    while pos < #text do
        ch, size = stringutil.DecodeRune(text, pos)
        local validChar
        if pos == 0 then
            validChar = scanner.IsIdentifierStart(ch)
        else
            validChar = scanner.IsIdentifierPart(ch)
        end
        if size > 0 and validChar then
            if needsUnderscore then
                identifier[#identifier + 1] = "_"
            end
            identifier[#identifier + 1] = stringutil.EncodeRune(ch)
            needsUnderscore = false
        else
            needsUnderscore = true
        end
        pos = pos + size
    end

    if needsUnderscore then
        identifier[#identifier + 1] = "_"
    end

    -- Default to "_" if the provided text was empty
    local id = table.concat(identifier)
    if id == "" then
        return "_"
    end

    return id
end

local completionsSymbolKindMap = nil

local function buildCompletionsSymbolKindMap()
    local CompletionItemKind = lsproto.CompletionItemKind
    return {
    [ScriptElementKind.PrimitiveType] = CompletionItemKind.Keyword,
    [ScriptElementKind.Keyword] = CompletionItemKind.Keyword,

    [ScriptElementKind.ConstElement] = CompletionItemKind.Variable,
    [ScriptElementKind.LetElement] = CompletionItemKind.Variable,
    [ScriptElementKind.VariableElement] = CompletionItemKind.Variable,
    [ScriptElementKind.LocalVariableElement] = CompletionItemKind.Variable,
    [ScriptElementKind.Alias] = CompletionItemKind.Variable,
    [ScriptElementKind.ParameterElement] = CompletionItemKind.Variable,

    [ScriptElementKind.MemberVariableElement] = CompletionItemKind.Field,
    [ScriptElementKind.MemberGetAccessorElement] = CompletionItemKind.Field,
    [ScriptElementKind.MemberSetAccessorElement] = CompletionItemKind.Field,

    [ScriptElementKind.FunctionElement] = CompletionItemKind.Function,
    [ScriptElementKind.LocalFunctionElement] = CompletionItemKind.Function,

    [ScriptElementKind.MemberFunctionElement] = CompletionItemKind.Method,
    [ScriptElementKind.ConstructSignatureElement] = CompletionItemKind.Method,
    [ScriptElementKind.CallSignatureElement] = CompletionItemKind.Method,
    [ScriptElementKind.IndexSignatureElement] = CompletionItemKind.Method,

    [ScriptElementKind.EnumElement] = CompletionItemKind.Enum,

    [ScriptElementKind.EnumMemberElement] = CompletionItemKind.EnumMember,

    [ScriptElementKind.ModuleElement] = CompletionItemKind.Module,
    [ScriptElementKind.ExternalModuleName] = CompletionItemKind.Module,

    [ScriptElementKind.ClassElement] = CompletionItemKind.Class,
    [ScriptElementKind.TypeElement] = CompletionItemKind.Class,

    [ScriptElementKind.InterfaceElement] = CompletionItemKind.Interface,

    [ScriptElementKind.Warning] = CompletionItemKind.Text,

    [ScriptElementKind.ScriptElement] = CompletionItemKind.File,

    [ScriptElementKind.Directory] = CompletionItemKind.Folder,

    [ScriptElementKind.String] = CompletionItemKind.Constant,
    }
end

-- Copied from vscode TS extension.
function ls.getCompletionsSymbolKind(kind)
    if completionsSymbolKindMap == nil then
        completionsSymbolKindMap = buildCompletionsSymbolKindMap()
    end
    local k = completionsSymbolKindMap[kind]
    if k ~= nil then
        return k
    end
    return lsproto.CompletionItemKind.Property
end
