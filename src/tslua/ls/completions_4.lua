-- Go internal/ls/completions.go, part 4: ResolveCompletionItem .. snippetEmitTextWriter.escapingWrite
local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local core = require("tslua.core")
local debug = require("tslua.debug")
local format = require("tslua.format")
local jsnum = require("tslua.jsnum")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")
local lsutil = require("tslua.ls.lsutil")
local autoimport = require("tslua.ls.autoimport")
local lsproto = require("tslua.lsp.lsproto")

local Kind = ast.Kind

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

-- Go errors.New / fmt.Errorf
local function newError(message)
    return {
        Error = function()
            return message
        end,
    }
end

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function trimPrefix(s, prefix)
    if hasPrefix(s, prefix) then
        return string.sub(s, #prefix + 1)
    end
    return s
end

-- Go strings.TrimSpace
local function trimSpace(s)
    local start, stop = 0, #s
    while start < stop do
        local r, size = stringutil.DecodeRune(s, start)
        if not stringutil.UnicodeIsSpace(r) then
            break
        end
        start = start + size
    end
    while stop > start do
        local r, size = stringutil.DecodeLastRune(s, stop)
        if not stringutil.UnicodeIsSpace(r) then
            break
        end
        stop = stop - size
    end
    return string.sub(s, start + 1, stop)
end

-- Go slices.Index (0-based, -1 if absent)
local function sliceIndex(xs, x)
    for i, v in ipairs(xs or {}) do
        if v == x then
            return i - 1
        end
    end
    return -1
end

-- Go &autoimport.Fix{AutoImportFix: x}
local function newAutoImportFix(autoImportFix)
    return setmetatable({
        autoImportFix = autoImportFix,
        moduleSpecifierKind = 0,
        isReExport = false,
        moduleFileName = "",
        typeOnlyAliasDeclaration = nil,
    }, autoimport.Fix)
end

function LanguageService:ResolveCompletionItem(ctx, item, data)
    if data == nil then
        return nil, newError("completion item data is nil")
    end

    local program, file = self:tryGetProgramAndFile(data.fileName)
    if file == nil then
        return nil, newError("file not found: " .. data.fileName)
    end
    file = ls.sourceFileForSupplementalFileIndex(file, data.supplementalFileIndex)
    if file == nil then
        return nil, newError(string.format("supplemental source file index not found: %d", data.supplementalFileIndex))
    end

    local c, done = program:GetTypeCheckerForFile(ctx, file)
    local result = self:getCompletionItemDetails(ctx, program, c, data.position, file, item, data)
    done()
    return result, nil
end

function ls.getCompletionDocumentationFormat(ctx)
    return lsproto.PreferredMarkupKind(lsproto.GetClientCapabilities(ctx).textDocument.completion.completionItem.documentationFormat)
end

function LanguageService:getCompletionItemDetails(ctx, program, c, position, file, item, data)
    local docFormat = ls.getCompletionDocumentationFormat(ctx)
    local contextToken, previousToken = ls.getRelevantTokens(position, file)
    if ls.IsInString(file, position, previousToken) then
        return self:getStringLiteralCompletionDetails(
            ctx,
            c,
            item,
            data.name,
            file,
            position,
            contextToken,
            docFormat
        )
    end

    if data.autoImport ~= nil then
        if data.isImportStatementCompletion then
            return item
        end
        -- Auto-imports in content-mapped files are evaluated eagerly so edits outside
        -- of verbatim spans can cause the completion item to be filtered out entirely.
        -- Only real files take this code path, so the final Edits() is guaranteed ok.
        local edits, description = newAutoImportFix(data.autoImport):Edits(ctx, file, program:Options(), self:FormatOptions(), self.converters, self:UserPreferences())
        item.additionalTextEdits = edits
        item.detail = ls.strPtrTo(description)
        return item
    end

    -- Compute all the completion symbols again.
    local symbolCompletion = self:getSymbolCompletionFromItemData(
        ctx,
        c,
        file,
        position,
        data
    )
    local preferences = self:UserPreferences()

    if symbolCompletion.request ~= nil then
        local request = symbolCompletion.request
        local mt = getmetatable(request)
        if mt == ls.completionDataJSDocTagName then
            return ls.createSimpleDetails(item, data.name, docFormat)
        elseif mt == ls.completionDataJSDocTag then
            return ls.createSimpleDetails(item, data.name, docFormat)
        elseif mt == ls.completionDataJSDocParameterName then
            return ls.createSimpleDetails(item, data.name, docFormat)
        elseif mt == ls.completionDataKeyword then
            if core.Some(request.keywordCompletions, function(ci)
                return ci.label == data.name
            end) then
                return ls.createSimpleDetails(item, data.name, docFormat)
            end
            return item
        else
            error("Unexpected completion data type", 0)
        end
    elseif symbolCompletion.symbol ~= nil then
        local symbolDetails = symbolCompletion.symbol
        return self:createCompletionDetailsForSymbol(
            item,
            symbolDetails.symbol,
            c,
            symbolDetails.location,
            position,
            docFormat
        )
    elseif symbolCompletion.literal ~= nil then
        local literal = symbolCompletion.literal
        return ls.createSimpleDetails(item, ls.completionNameForLiteral(file, preferences, literal), docFormat)
    elseif symbolCompletion.cases ~= nil then
        return item
    else
        -- Didn't find a symbol with this name.  See if we can find a keyword instead.
        if core.Some(ls.allKeywordCompletions(), function(ci)
            return ci.label == data.name
        end) then
            return ls.createSimpleDetails(item, data.name, docFormat)
        end
        return item
    end
end

-- detailsData: { symbol = symbolDetails|nil, request = completionData|nil, literal = literalValue|nil,
-- cases = true|nil }
-- symbolDetails: { symbol, location, origin, previousToken, contextToken, jsxInitializer, isTypeOnlyLocation }

function LanguageService:getSymbolCompletionFromItemData(ctx, ch, file, position, itemData)
    if itemData.source == ls.SourceSwitchCases then
        return {
            cases = true,
        }
    end

    local completionData, err = self:getCompletionData(ctx, ch, file, position, self:UserPreferences(), true --[[forItemResolve]])
    if err ~= nil then
        error(err, 0)
    end

    if completionData == nil then
        return {}
    end

    if getmetatable(completionData) ~= ls.completionDataData then
        return {
            request = completionData,
        }
    end

    local data = completionData

    local preferences = self:UserPreferences()
    local literal = nil
    for _, lit in ipairs(data.literals or {}) do
        if ls.completionNameForLiteral(file, preferences, lit) == itemData.name then
            literal = lit
            break
        end
    end
    if literal ~= nil then
        return {
            literal = literal,
        }
    end

    -- Find the symbol with the matching entry name.
    -- We don't need to perform character checks here because we're only comparing the
    -- name against 'entryName' (which is known to be good), not building a new
    -- completion entry.
    for i, symbol in ipairs(data.symbols or {}) do
        local index = i - 1
        local origin = data.symbolToOriginInfoMap[index]
        local displayName = ls.getCompletionEntryDisplayNameForSymbol(symbol, origin, data.completionKind, data.isJsxIdentifierExpected)
        if displayName == itemData.name and
            (itemData.source == ls.completionSource.ClassMemberSnippet and symbol.flags & ast.SymbolFlags.ClassMember ~= 0 or
                itemData.source == ls.completionSource.ObjectLiteralMethodSnippet and symbol.flags & (ast.SymbolFlags.Property | ast.SymbolFlags.Method) ~= 0 or
                ls.getSourceFromOrigin(origin) == itemData.source or
                itemData.source == ls.completionSource.ObjectLiteralMemberWithComma) then
            return {
                symbol = {
                    symbol = symbol,
                    location = data.location,
                    origin = origin,
                    previousToken = data.previousToken,
                    contextToken = data.contextToken,
                    jsxInitializer = data.jsxInitializer,
                    isTypeOnlyLocation = data.isTypeOnlyLocation,
                },
            }
        end
    end
    return {}
end

function ls.createSimpleDetails(item, name, docFormat)
    return ls.createCompletionDetails(item, name, "" --[[documentation]], docFormat)
end

function ls.createCompletionDetails(item, detail, documentation, docFormat)
    -- !!! fill in additionalTextEdits from code actions
    if item.detail == nil and detail ~= "" then
        item.detail = detail
    end
    if documentation ~= "" then
        item.documentation = {
            markupContent = {
                kind = docFormat,
                value = documentation,
            },
        }
    end
    return item
end

-- codeAction: { description = string, changes = []*lsproto.TextEdit }

function LanguageService:createCompletionDetailsForSymbol(item, symbol, c, location, position, docFormat)
    local quickInfo, documentation = self:getQuickInfoAndDocumentationForSymbol(c, symbol, location, docFormat, nil, false --[[vsCapability]])
    return ls.createCompletionDetails(item, quickInfo, documentation, docFormat)
end

function LanguageService:getImportStatementCompletionInfo(contextToken, sourceFile)
    local result = {
        isKeywordOnlyCompletion = false,
        keywordCompletion = Kind.Unknown,
        isNewIdentifierLocation = false,
        isTopLevelTypeOnly = false,
        couldBeTypeOnlyImportSpecifier = false,
        replacementSpan = nil,
    }
    local candidate = nil
    local parent = contextToken.parent
    if ast.IsImportEqualsDeclaration(parent) then
        -- import Foo |
        -- import Foo f|
        local lastToken = lsutil.GetLastToken(parent, sourceFile)
        if contextToken.kind == Kind.Identifier and lastToken ~= contextToken then
            result.keywordCompletion = Kind.FromKeyword
            result.isKeywordOnlyCompletion = true
        else
            if contextToken.kind ~= Kind.TypeKeyword then
                result.keywordCompletion = Kind.TypeKeyword
            end
            if ls.isModuleSpecifierMissingOrEmpty(parent:AsImportEqualsDeclaration().moduleReference) then
                candidate = parent
            end
        end
    elseif ls.couldBeTypeOnlyImportSpecifier(parent, contextToken) and ls.canCompleteFromNamedBindings(parent.parent) then
        candidate = parent
    elseif ast.IsNamedImports(parent) or ast.IsNamespaceImport(parent) then
        if not parent.parent:IsTypeOnly() and (contextToken.kind == Kind.OpenBraceToken or
            contextToken.kind == Kind.ImportKeyword or
            contextToken.kind == Kind.CommaToken) then
            result.keywordCompletion = Kind.TypeKeyword
        end
        if ls.canCompleteFromNamedBindings(parent) then
            -- At `import { ... } |` or `import * as Foo |`, the only possible completion is `from`
            if contextToken.kind == Kind.CloseBraceToken or contextToken.kind == Kind.Identifier then
                result.isKeywordOnlyCompletion = true
                result.keywordCompletion = Kind.FromKeyword
            else
                candidate = parent.parent.parent
            end
        end
    elseif ast.IsExportDeclaration(parent) and contextToken.kind == Kind.AsteriskToken or
        ast.IsNamedExports(parent) and contextToken.kind == Kind.CloseBraceToken then
        result.isKeywordOnlyCompletion = true
        result.keywordCompletion = Kind.FromKeyword
    elseif contextToken.kind == Kind.ImportKeyword then
        if ast.IsSourceFile(parent) then
            -- A lone import keyword with nothing following it does not parse as a statement at all
            result.keywordCompletion = Kind.TypeKeyword
            candidate = contextToken
        elseif ast.IsImportDeclaration(parent) then
            -- `import s| from`
            result.keywordCompletion = Kind.TypeKeyword
            if ls.isModuleSpecifierMissingOrEmpty(parent:ModuleSpecifier()) then
                candidate = parent
            end
        end
    end

    if candidate ~= nil then
        result.isNewIdentifierLocation = true
        result.replacementSpan = self:getSingleLineReplacementSpanForImportCompletionNode(candidate)
        result.couldBeTypeOnlyImportSpecifier = ls.couldBeTypeOnlyImportSpecifier(candidate, contextToken)
        if ast.IsImportDeclaration(candidate) then
            local importClause = candidate:ImportClause()
            if importClause ~= nil then
                result.isTopLevelTypeOnly = importClause:IsTypeOnly()
            end
        elseif candidate.kind == Kind.ImportEqualsDeclaration then
            result.isTopLevelTypeOnly = candidate:IsTypeOnly()
        end
    else
        result.isNewIdentifierLocation = result.keywordCompletion == Kind.TypeKeyword
    end
    return result
end

function LanguageService:getSingleLineReplacementSpanForImportCompletionNode(node)
    -- node is ImportDeclaration | ImportEqualsDeclaration | ImportSpecifier | JSDocImportTag | Token<SyntaxKind.ImportKeyword>
    local ancestor = ast.FindAncestor(node, core.Or(ast.IsImportDeclaration, ast.IsImportEqualsDeclaration, ast.IsJSDocImportTag))
    if ancestor ~= nil then
        node = ancestor
    end
    local sourceFile = ast.GetSourceFileOfNode(node)
    -- Use token position (excluding JSDoc/trivia) instead of node.Pos() to avoid including JSDoc comments
    local tokenPos = scanner.GetTokenPosOfNode(node, sourceFile, false --[[includeJSDoc]])
    if printer.GetLinesBetweenPositions(sourceFile, tokenPos, node:End()) == 0 then
        local lspRange, fidelity = self:createLspRangeFromNode(node, sourceFile)
        if not spanmap.Fidelity_IsExact(fidelity) then
            return nil
        end
        return lspRange
    end

    if node.kind == Kind.ImportKeyword or node.kind == Kind.ImportSpecifier then
        error("ImportKeyword was necessarily on one line; ImportSpecifier was necessarily parented in an ImportDeclaration", 0)
    end

    -- Guess which point in the import might actually be a later statement parsed as part of the import
    -- during parser recovery - either in the middle of named imports, or the module specifier.
    local potentialSplitPoint
    if node.kind == Kind.ImportDeclaration or node.kind == Kind.JSDocImportTag then
        local specifier = nil
        local importClause = node:ImportClause()
        if importClause ~= nil then
            specifier = ls.getPotentiallyInvalidImportSpecifier(importClause:AsImportClause().namedBindings)
        end

        if specifier ~= nil then
            potentialSplitPoint = specifier
        else
            potentialSplitPoint = node:ModuleSpecifier()
        end
    else
        potentialSplitPoint = node:AsImportEqualsDeclaration().moduleReference
    end

    local withoutModuleSpecifier = core.NewTextRange(scanner.GetTokenPosOfNode(lsutil.GetFirstToken(node, sourceFile), sourceFile, false), potentialSplitPoint:Pos())
    -- The module specifier/reference was previously found to be missing, empty, or
    -- not a string literal - in this last case, it's likely that statement on a following
    -- line was parsed as the module specifier of a partially-typed import, e.g.
    --   import Foo|
    --   interface Blah {}
    -- This appears to be a multiline-import, and editors can't replace multiple lines.
    -- But if everything but the "module specifier" is on one line, by this point we can
    -- assume that the "module specifier" is actually just another statement, and return
    -- the single-line range of the import excluding that probable statement.
    if printer.GetLinesBetweenPositions(sourceFile, withoutModuleSpecifier:Pos(), withoutModuleSpecifier:End()) == 0 then
        local lspRange, fidelity = self:createLspRangeFromBounds(withoutModuleSpecifier:Pos(), withoutModuleSpecifier:End(), sourceFile)
        if not spanmap.Fidelity_IsExact(fidelity) then
            return nil
        end
        return lspRange
    end
    return nil
end

function ls.couldBeTypeOnlyImportSpecifier(importSpecifier, contextToken)
    return ast.IsImportSpecifier(importSpecifier) and (importSpecifier:IsTypeOnly() or contextToken == importSpecifier:Name() and ls.isTypeKeywordTokenOrIdentifier(contextToken))
end

function ls.canCompleteFromNamedBindings(namedBindings)
    if not ls.isModuleSpecifierMissingOrEmpty(namedBindings.parent.parent:ModuleSpecifier()) or namedBindings.parent:Name() ~= nil then
        return false
    end
    if ast.IsNamedImports(namedBindings) then
        -- We can only complete on named imports if there are no other named imports already,
        -- but parser recovery sometimes puts later statements in the named imports list, so
        -- we try to only consider the probably-valid ones.
        local invalidNamedImport = ls.getPotentiallyInvalidImportSpecifier(namedBindings)
        local elements = namedBindings:Elements()
        local validImports = core.Len(elements)
        if invalidNamedImport ~= nil then
            validImports = sliceIndex(elements, invalidNamedImport)
        end

        return validImports < 2 and validImports > -1
    end
    return true
end

-- Tries to identify the first named import that is not really a named import, but rather
-- just parser recovery for a situation like:
--
--	import { Foo|
--	interface Bar {}
--
-- in which `Foo`, `interface`, and `Bar` are all parsed as import specifiers. The caller
-- will also check if this token is on a separate line from the rest of the import.
function ls.getPotentiallyInvalidImportSpecifier(namedBindings)
    if namedBindings == nil or namedBindings.kind ~= Kind.NamedImports then
        return nil
    end
    return core.Find(namedBindings:Elements(), function(e)
        return e:PropertyName() == nil and lsutil.IsNonContextualKeyword(scanner.StringToToken(e:Name():Text())) and
            astnav.FindPrecedingToken(ast.GetSourceFileOfNode(namedBindings), e:Name():Pos()).kind ~= Kind.CommaToken
    end)
end

function ls.isModuleSpecifierMissingOrEmpty(specifier)
    if ast.NodeIsMissing(specifier) then
        return true
    end
    local node = specifier
    if ast.IsExternalModuleReference(node) then
        node = node:Expression()
    end
    if not ast.IsStringLiteralLike(node) then
        return true
    end
    return node:Text() == ""
end

function ls.hasDocComment(file, position)
    local token = astnav.GetTokenAtPosition(file, position)
    return ast.FindAncestor(token, function(n)
        return n:IsJSDoc()
    end) ~= nil
end

-- Get the corresponding JSDocTag node if the position is in a JSDoc comment
function ls.getJSDocTagAtPosition(node, position)
    return ast.FindAncestorOrQuit(node, function(n)
        if ast.IsJSDocTag(n) and n.loc:ContainsInclusive(position) then
            return ast.FindAncestorResult.FindAncestorTrue
        end
        if n:IsJSDoc() then
            return ast.FindAncestorResult.FindAncestorQuit
        end
        return ast.FindAncestorResult.FindAncestorFalse
    end)
end

function ls.tryGetTypeExpressionFromTag(tag)
    if ls.isTagWithTypeExpression(tag) then
        local typeExpression
        if ast.IsJSDocTemplateTag(tag) then
            typeExpression = tag:AsJSDocTemplateTag().constraint
        else
            typeExpression = tag:TypeExpression()
        end
        if typeExpression ~= nil and typeExpression.kind == Kind.JSDocTypeExpression then
            return typeExpression
        end
    end
    if ast.IsJSDocAugmentsTag(tag) or ast.IsJSDocImplementsTag(tag) then
        return tag:ClassName()
    end
    return nil
end

local tagWithTypeExpressionKinds = ast.kindSet(Kind.JSDocParameterTag, Kind.JSDocPropertyTag, Kind.JSDocReturnTag, Kind.JSDocTypeTag,
    Kind.JSDocTypedefTag, Kind.JSDocThrowsTag, Kind.JSDocSatisfiesTag)

function ls.isTagWithTypeExpression(tag)
    if tagWithTypeExpressionKinds[tag.kind] then
        return true
    elseif tag.kind == Kind.JSDocTemplateTag then
        return tag:AsJSDocTemplateTag().constraint ~= nil
    else
        return false
    end
end

function LanguageService:jsDocCompletionInfo(ctx, position, file, items)
    local defaultCommitCharacters = ls.getDefaultCommitCharacters(false --[[isNewIdentifierLocation]])
    local itemDefaults = self:setItemDefaults(
        ctx,
        position,
        file,
        items,
        defaultCommitCharacters,
        nil --[[optionalReplacementSpan]]
    )
    return setmetatable({
        isIncomplete = false,
        itemDefaults = itemDefaults,
        items = items,
    }, ls.CompletionList)
end

ls.jsDocTagNames = {
    "abstract",
    "access",
    "alias",
    "argument",
    "async",
    "augments",
    "author",
    "borrows",
    "callback",
    "class",
    "classdesc",
    "constant",
    "constructor",
    "constructs",
    "copyright",
    "default",
    "deprecated",
    "description",
    "emits",
    "enum",
    "event",
    "example",
    "exports",
    "extends",
    "external",
    "field",
    "file",
    "fileoverview",
    "fires",
    "function",
    "generator",
    "global",
    "hideconstructor",
    "host",
    "ignore",
    "implements",
    "import",
    "inheritdoc",
    "inner",
    "instance",
    "interface",
    "kind",
    "lends",
    "license",
    "link",
    "linkcode",
    "linkplain",
    "listens",
    "member",
    "memberof",
    "method",
    "mixes",
    "module",
    "name",
    "namespace",
    "overload",
    "override",
    "package",
    "param",
    "private",
    "prop",
    "property",
    "protected",
    "public",
    "readonly",
    "requires",
    "returns",
    "satisfies",
    "see",
    "since",
    "static",
    "summary",
    "template",
    "this",
    "throws",
    "todo",
    "tutorial",
    "type",
    "typedef",
    "var",
    "variation",
    "version",
    "virtual",
    "yields",
}

-- sync.OnceValue
local jsDocTagNameCompletionItemsCache = nil
function ls.jsDocTagNameCompletionItems()
    if jsDocTagNameCompletionItemsCache == nil then
        local items = {}
        for _, tagName in ipairs(ls.jsDocTagNames) do
            local item = {
                label = tagName,
                kind = lsproto.CompletionItemKind.Keyword,
                sortText = ls.SortText.LocationPriority,
            }
            items[#items + 1] = item
        end
        jsDocTagNameCompletionItemsCache = items
    end
    return jsDocTagNameCompletionItemsCache
end

-- sync.OnceValue
local jsDocTagCompletionItemsCache = nil
function ls.jsDocTagCompletionItems()
    if jsDocTagCompletionItemsCache == nil then
        local items = {}
        for _, tagName in ipairs(ls.jsDocTagNames) do
            local item = {
                label = "@" .. tagName,
                kind = lsproto.CompletionItemKind.Keyword,
                sortText = ls.SortText.LocationPriority,
            }
            items[#items + 1] = item
        end
        jsDocTagCompletionItemsCache = items
    end
    return jsDocTagCompletionItemsCache
end

function ls.getJSDocTagNameCompletions()
    return ls.cloneItems(ls.jsDocTagNameCompletionItems())
end

function ls.getJSDocTagCompletions()
    return ls.cloneItems(ls.jsDocTagCompletionItems())
end

function ls.getJSDocParameterCompletions(ctx, file, position, typeChecker, options, preferences, tagNameOnly)
    local currentToken = astnav.GetTokenAtPosition(file, position)
    if not ast.IsJSDocTag(currentToken) and not currentToken:IsJSDoc() then
        return nil
    end
    local jsDoc
    if currentToken:IsJSDoc() then
        jsDoc = currentToken
    else
        jsDoc = currentToken.parent
    end
    if not jsDoc:IsJSDoc() then
        return nil
    end
    local fun = jsDoc.parent
    if not ast.IsFunctionLike(fun) then
        return nil
    end

    local isJS = ast.IsSourceFileJS(file)
    -- isSnippet := clientSupportsItemSnippet(clientOptions)
    local isSnippet = false -- !!! need snippet printer
    local paramTagCount = 0
    local tags = nil
    if jsDoc:AsJSDoc().tags ~= nil then
        tags = jsDoc:AsJSDoc().tags.nodes
    end
    for _, tag in ipairs(tags or {}) do
        if ast.IsJSDocParameterTag(tag) and
            astnav.GetStartOfNode(tag, file, false --[[includeJSDoc]]) < position and
            ast.IsIdentifier(tag:Name()) then
            paramTagCount = paramTagCount + 1
        end
    end
    local paramIndex = -1
    return core.MapNonNil(fun:Parameters(), function(param)
        paramIndex = paramIndex + 1
        if paramIndex < paramTagCount then
            -- This parameter is already annotated.
            return nil
        end
        if ast.IsIdentifier(param:Name()) then -- Named parameter
            local tabstopCounter = { value = 1 }
            local paramName = param:Name():Text()
            local displayText = ls.getJSDocParamAnnotation(
                paramName,
                param:Initializer(),
                param:AsParameterDeclaration().dotDotDotToken,
                isJS,
                false --[[isObject]],
                false --[[isSnippet]],
                typeChecker,
                options,
                preferences,
                tabstopCounter
            )
            local snippetText = ""
            if isSnippet then
                snippetText = ls.getJSDocParamAnnotation(
                    paramName,
                    param:Initializer(),
                    param:AsParameterDeclaration().dotDotDotToken,
                    isJS,
                    false --[[isObject]],
                    true --[[isSnippet]],
                    typeChecker,
                    options,
                    preferences,
                    tabstopCounter
                )
            end
            if tagNameOnly then -- Remove `@`
                displayText = string.sub(displayText, 2)
                if snippetText ~= "" then
                    snippetText = string.sub(snippetText, 2)
                end
            end

            return ls.NewCompletionItem({
                label = displayText,
                kind = lsproto.CompletionItemKind.Variable,
                sortText = ls.SortText.LocationPriority,
                insertText = ls.strPtrTo(snippetText),
                insertTextFormat = core.IfElse(isSnippet, lsproto.InsertTextFormat.Snippet, nil),
            }, nil)
        elseif paramIndex == paramTagCount then
            -- Destructuring parameter; do it positionally
            local paramPath = string.format("param%d", paramIndex)
            local displayTextResult = ls.generateJSDocParamTagsForDestructuring(
                paramPath,
                param:Name(),
                param:Initializer(),
                param:AsParameterDeclaration().dotDotDotToken,
                isJS,
                false --[[isSnippet]],
                typeChecker,
                options,
                preferences
            )
            local snippetText = ""
            if isSnippet then
                local snippetTextResult = ls.generateJSDocParamTagsForDestructuring(
                    paramPath,
                    param:Name(),
                    param:Initializer(),
                    param:AsParameterDeclaration().dotDotDotToken,
                    isJS,
                    true --[[isSnippet]],
                    typeChecker,
                    options,
                    preferences
                )
                snippetText = table.concat(snippetTextResult, core.NewLineKind_GetNewLineCharacter(options.newLine) .. "* ")
            end
            local displayText = table.concat(displayTextResult, core.NewLineKind_GetNewLineCharacter(options.newLine) .. "* ")
            if tagNameOnly then -- Remove `@`
                displayText = trimPrefix(displayText, "@")
                snippetText = trimPrefix(snippetText, "@")
            end
            return ls.NewCompletionItem({
                label = displayText,
                kind = lsproto.CompletionItemKind.Variable,
                sortText = ls.SortText.LocationPriority,
                insertText = ls.strPtrTo(snippetText),
                insertTextFormat = core.IfElse(isSnippet, lsproto.InsertTextFormat.Snippet, nil),
            }, nil)
        end
        return nil
    end)
end

-- tabstopCounter is Go *int: a table { value = int } (or nil).
function ls.getJSDocParamAnnotation(paramName, initializer, dotDotDotToken, isJS, isObject, isSnippet, typeChecker, options, preferences, tabstopCounter)
    if isSnippet then
        debug.Assert(tabstopCounter ~= nil)
    end
    if initializer ~= nil then
        paramName = ls.getJSDocParamNameWithInitializer(paramName, initializer)
    end
    if isSnippet then
        paramName = ls.escapeSnippetText(paramName)
    end
    if isJS then
        local t = "*"
        if isObject then
            debug.Assert(dotDotDotToken == nil, "Cannot annotate a rest parameter with type 'object'.")
            t = "object"
        else
            if initializer ~= nil then
                local inferredType = typeChecker:GetTypeAtLocation(initializer.parent)
                if inferredType:Flags() & (checker.TypeFlags.Any | checker.TypeFlags.Void) == 0 then
                    local file = ast.GetSourceFileOfNode(initializer)
                    local quotePreference = lsutil.GetQuotePreference(file, preferences)
                    local builderFlags = core.IfElse(
                        quotePreference == lsutil.QuotePreference.Single,
                        nodebuilder.Flags.UseSingleQuotesForStringLiteralType,
                        nodebuilder.Flags.None
                    )
                    local typeNode = typeChecker:TypeToTypeNode(
                        inferredType,
                        ast.FindAncestor(initializer, ast.IsFunctionLike),
                        builderFlags,
                        nil --[[idToSymbol]]
                    )
                    if typeNode ~= nil then
                        local emitContext = printer.NewEmitContext()
                        -- !!! snippet p
                        local p = printer.NewPrinter({
                            removeComments = true,
                            -- !!!
                            -- Module: options.Module,
                            -- ModuleResolution: options.ModuleResolution,
                            -- Target: options.Target,
                        }, {}, emitContext)
                        emitContext:SetEmitFlags(typeNode, printer.EmitFlags.EFSingleLine)
                        t = p:Emit(typeNode, file)
                    end
                end
            end
            if isSnippet and t == "*" then
                local tabstop = tabstopCounter.value
                tabstopCounter.value = tabstopCounter.value + 1
                t = string.format("${%d:%s}", tabstop, t)
            end
        end
        local dotDotDot = core.IfElse(not isObject and dotDotDotToken ~= nil, "...", "")
        local description = ""
        if isSnippet then
            local tabstop = tabstopCounter.value
            tabstopCounter.value = tabstopCounter.value + 1
            description = string.format("${%d}", tabstop)
        end
        return string.format("@param {%s%s} %s %s", dotDotDot, t, paramName, description)
    else
        local description = ""
        if isSnippet then
            local tabstop = tabstopCounter.value
            tabstopCounter.value = tabstopCounter.value + 1
            description = string.format("${%d}", tabstop)
        end
        return string.format("@param %s %s", paramName, description)
    end
end

function ls.getJSDocParamNameWithInitializer(paramName, initializer)
    local initializerText = trimSpace(scanner.GetTextOfNode(initializer))
    if string.find(initializerText, "\n", 1, true) ~= nil or #initializerText > 80 then
        return string.format("[%s]", paramName)
    end
    return string.format("[%s=%s]", paramName, initializerText)
end

function ls.generateJSDocParamTagsForDestructuring(path, pattern, initializer, dotDotDotToken, isJS, isSnippet, typeChecker, options, preferences)
    local tabstopCounter = { value = 1 }
    if not isJS then
        return { ls.getJSDocParamAnnotation(
            path,
            initializer,
            dotDotDotToken,
            isJS,
            false --[[isObject]],
            isSnippet,
            typeChecker,
            options,
            preferences,
            tabstopCounter
        ) }
    end
    return ls.jsDocParamPatternWorker(
        path,
        pattern,
        initializer,
        dotDotDotToken,
        isJS,
        isSnippet,
        typeChecker,
        options,
        preferences,
        tabstopCounter
    )
end

function ls.jsDocParamPatternWorker(path, pattern, initializer, dotDotDotToken, isJS, isSnippet, typeChecker, options, preferences, counter)
    if ast.IsObjectBindingPattern(pattern) and dotDotDotToken == nil then
        local childCounter = { value = counter.value }
        local rootParam = ls.getJSDocParamAnnotation(
            path,
            initializer,
            dotDotDotToken,
            isJS,
            true --[[isObject]],
            isSnippet,
            typeChecker,
            options,
            preferences,
            childCounter
        )
        local childTags = nil
        for _, element in ipairs(pattern:Elements() or {}) do
            local elementTags = ls.jsDocParamElementWorker(
                path,
                element,
                initializer,
                dotDotDotToken,
                isJS,
                isSnippet,
                typeChecker,
                options,
                preferences,
                childCounter
            )
            if core.Len(elementTags) == 0 then
                childTags = nil
                break
            end
            childTags = childTags or {}
            for _, tag in ipairs(elementTags) do
                childTags[#childTags + 1] = tag
            end
        end
        if core.Len(childTags) > 0 then
            counter.value = childCounter.value
            local result = { rootParam }
            for _, tag in ipairs(childTags) do
                result[#result + 1] = tag
            end
            return result
        end
    end
    return {
        ls.getJSDocParamAnnotation(
            path,
            initializer,
            dotDotDotToken,
            isJS,
            false --[[isObject]],
            isSnippet,
            typeChecker,
            options,
            preferences,
            counter
        ),
    }
end

-- Assumes binding element is inside object binding pattern.
-- We can't deeply annotate an array binding pattern.
function ls.jsDocParamElementWorker(path, element, initializer, dotDotDotToken, isJS, isSnippet, typeChecker, options, preferences, counter)
    if ast.IsIdentifier(element:Name()) then -- `{ b }` or `{ b: newB }`
        local propertyName
        if element:PropertyName() ~= nil then
            propertyName = ast.TryGetTextOfPropertyName(element:PropertyName())
        else
            propertyName = element:Name():Text()
        end
        if propertyName == "" then
            return nil
        end
        local paramName = string.format("%s.%s", path, propertyName)
        return {
            ls.getJSDocParamAnnotation(
                paramName,
                element:Initializer(),
                element:AsBindingElement().dotDotDotToken,
                isJS,
                false --[[isObject]],
                isSnippet,
                typeChecker,
                options,
                preferences,
                counter
            ),
        }
    elseif element:PropertyName() ~= nil then -- `{ b: {...} }` or `{ b: [...] }`
        local propertyName = ast.TryGetTextOfPropertyName(element:PropertyName())
        if propertyName == "" then
            return nil
        end
        return ls.jsDocParamPatternWorker(
            string.format("%s.%s", path, propertyName),
            element:Name(),
            element:Initializer(),
            element:AsBindingElement().dotDotDotToken,
            isJS,
            isSnippet,
            typeChecker,
            options,
            preferences,
            counter
        )
    end
    return nil
end

function ls.getJSDocParameterNameCompletions(tag)
    if not ast.IsIdentifier(tag:Name()) then
        return nil
    end
    local nameThusFar = tag:Name():Text()
    local jsDoc = tag.parent
    local fn = jsDoc.parent
    if not ast.IsFunctionLike(fn) then
        return nil
    end

    local tags = nil
    if jsDoc:AsJSDoc().tags ~= nil then
        tags = jsDoc:AsJSDoc().tags.nodes
    end

    return core.MapNonNil(fn:Parameters(), function(param)
        if not ast.IsIdentifier(param:Name()) then
            return nil
        end

        local name = param:Name():Text()
        if core.Some(tags, function(t)
            return t ~= tag and
                ast.IsJSDocParameterTag(t) and
                ast.IsIdentifier(t:Name()) and
                t:Name():Text() == name
        end) or nameThusFar ~= "" and not hasPrefix(name, nameThusFar) then
            return nil
        end

        return ls.NewCompletionItem({
            label = name,
            kind = lsproto.CompletionItemKind.Variable,
            sortText = ls.SortText.LocationPriority,
        }, nil)
    end)
end

function LanguageService:getExhaustiveCaseSnippets(ctx, caseBlock, file, position, options, program, c)
    local clauses = caseBlock.clauses.nodes
    local switchType = c:GetTypeAtLocation(caseBlock.parent:Expression())
    if switchType ~= nil and switchType:IsUnion() and core.Every(switchType:Types(), ls.isLiteral) then
        -- Collect constant values in existing clauses.
        local tracker = ls.newCaseClauseTracker(c, clauses)
        local target = options:GetEmitScriptTarget()
        local quotePreference = lsutil.GetQuotePreference(file, self:UserPreferences())
        -- Tolerate a nil import adder in untitled files.
        local importAdder = nil
        if not tspath.IsDynamicFileName(file:FileName()) then
            local view, err = self:getPreparedAutoImportView(file)
            if err ~= nil then
                return nil, err
            end
            if view ~= nil then
                importAdder = autoimport.NewImportAdder(
                    ctx,
                    program,
                    c,
                    file,
                    view,
                    self:FormatOptions(),
                    self.converters,
                    self:UserPreferences()
                )
            end
        end

        local elements = {}
        local factory = ast.NewNodeFactory({})
        for _, t in ipairs(switchType:Types()) do
            -- Enums
            if t:IsEnumLiteral() then
                debug.Assert(t:Symbol() ~= nil, "An enum member type should have a symbol")
                debug.Assert(t:Symbol().parent ~= nil, "An enum member type should have a parent symbol (the enum symbol)")
                -- Filter existing enums by their values
                local enumValue = nil
                if t:Symbol().valueDeclaration ~= nil then
                    enumValue = c:GetConstantValue(t:Symbol().valueDeclaration)
                end
                if enumValue ~= nil then
                    if tracker:hasValue(enumValue) then
                        goto continue
                    end
                    tracker:addValue(enumValue)
                end
                local typeNode = autoimport.TypeToAutoImportableTypeNode(c, importAdder, t, caseBlock)
                if typeNode == nil then
                    return nil, nil
                end
                local expr = ls.typeNodeToExpression(typeNode, target, quotePreference, factory)
                if expr == nil then
                    return nil, nil
                end
                elements[#elements + 1] = expr
            else
                local value = t:AsLiteralType():Value()
                if not tracker:hasValue(value) then -- Literals
                    if getmetatable(value) == jsnum.PseudoBigInt then
                        local bigInt
                        if value.negative then
                            local v = jsnum.NewPseudoBigInt(value.base10Value, false)
                            bigInt = factory:NewPrefixUnaryExpression(Kind.MinusToken, factory:NewBigIntLiteral(v:String() .. "n", ast.TokenFlags.None))
                        else
                            bigInt = factory:NewBigIntLiteral(value:String() .. "n", ast.TokenFlags.None)
                        end
                        elements[#elements + 1] = bigInt
                    elseif type(value) == "number" then
                        local number
                        if value < 0 then
                            number = factory:NewPrefixUnaryExpression(Kind.MinusToken, factory:NewNumericLiteral(jsnum.Number_String(jsnum.Number_Abs(value)), ast.TokenFlags.None))
                        else
                            number = factory:NewNumericLiteral(jsnum.Number_String(value), ast.TokenFlags.None)
                        end
                        elements[#elements + 1] = number
                    elseif type(value) == "string" then
                        local literal = factory:NewStringLiteral(value, core.IfElse(quotePreference == lsutil.QuotePreference.Single, ast.TokenFlags.SingleQuote, ast.TokenFlags.None))
                        elements[#elements + 1] = literal
                    end
                end
            end
            ::continue::
        end
        if #elements == 0 then
            return nil, nil
        end

        local newClauses = core.Map(elements, function(element)
            return factory:NewCaseOrDefaultClause(Kind.CaseClause, element, factory:NewNodeList(nil))
        end)
        local newLineChar = self:FormatOptions().newLineCharacter
        local p = ls.createSnippetPrinter({
            removeComments = true,
            newLine = core.GetNewLineKind(newLineChar),
        }, nil --[[emitContext]])
        local function printNode(node)
            return p:printAndFormatNode(ctx, node, file)
        end
        local insertText = table.concat(core.MapIndex(newClauses, function(clause, i)
            if ls.clientSupportsItemSnippet(ctx) then
                return string.format("%s$%d", printNode(clause), i + 1)
            end
            return p:printUnescapedNode(clause)
        end), newLineChar)

        local firstClause = p:printUnescapedNode(newClauses[1])
        local name = firstClause .. " ..."

        local additionalTextEdits = nil
        if importAdder ~= nil then
            local edits = importAdder:Edits()
            if core.Len(edits) ~= 0 then
                additionalTextEdits = edits
            end
        end

        return {
            label = name,
            kind = lsproto.CompletionItemKind.Snippet,
            sortText = ls.SortText.GlobalsOrKeywords,
            insertText = ls.strPtrTo(insertText),
            additionalTextEdits = additionalTextEdits,
            insertTextFormat = core.IfElse(ls.clientSupportsItemSnippet(ctx), lsproto.InsertTextFormat.Snippet, nil),
            data = {
                fileName = file:OriginalFileName(),
                position = position,
                supplementalFileIndex = ls.supplementalFileIndex(file),
                name = name,
                source = ls.completionSource.SwitchCases,
                isImportStatementCompletion = false,
            },
        }, nil
    end
    return nil, nil
end

function ls.typeNodeToExpression(typeNode, target, quotePreference, factory)
    local kind = typeNode.kind
    if kind == Kind.TypeReference then
        local typeName = typeNode:AsTypeReferenceNode().typeName
        return ls.entityNameToExpression(typeName, target, quotePreference, factory)
    elseif kind == Kind.IndexedAccessType then
        local objectExpression = ls.typeNodeToExpression(
            typeNode:AsIndexedAccessTypeNode().objectType,
            target,
            quotePreference,
            factory
        )
        local indexExpression = ls.typeNodeToExpression(
            typeNode:AsIndexedAccessTypeNode().indexType,
            target,
            quotePreference,
            factory
        )
        if objectExpression ~= nil and indexExpression ~= nil then
            return factory:NewElementAccessExpression(objectExpression, nil --[[questionDotToken]], indexExpression, ast.NodeFlags.None)
        end
        return nil
    elseif kind == Kind.LiteralType then
        local literal = typeNode:AsLiteralTypeNode().literal
        if literal.kind == Kind.StringLiteral then
            local expr = factory:NewStringLiteral(literal:Text(), core.IfElse(quotePreference == lsutil.QuotePreference.Single, ast.TokenFlags.SingleQuote, ast.TokenFlags.None))
            return expr
        elseif literal.kind == Kind.NumericLiteral then
            local expr = factory:NewNumericLiteral(literal:Text(), literal:AsNumericLiteral().tokenFlags)
            return expr
        else
            return nil
        end
    elseif kind == Kind.ParenthesizedType then
        local expr = ls.typeNodeToExpression(
            typeNode:AsParenthesizedTypeNode().type,
            target,
            quotePreference,
            factory
        )
        if expr == nil then
            return nil
        end
        if ast.IsIdentifier(expr) then
            return expr
        end
        return factory:NewParenthesizedExpression(expr)
    elseif kind == Kind.TypeQuery then
        return ls.entityNameToExpression(typeNode:AsTypeQueryNode().exprName, target, quotePreference, factory)
    elseif kind == Kind.ImportType then
        debug.Fail("We should not get an import type after calling 'typeToAutoImportableTypeNode'.")
        return nil
    end
    return nil
end

function ls.entityNameToExpression(entityName, target, quotePreference, factory)
    if ast.IsIdentifier(entityName) then
        return entityName
    end
    return factory:NewPropertyAccessExpression(
        ls.entityNameToExpression(entityName:AsQualifiedName().left, target, quotePreference, factory),
        nil --[[questionDotToken]],
        entityName:AsQualifiedName().right,
        ast.NodeFlags.None
    )
end

-- snippetPrinter: { baseWriter = printer.ChangeTrackerWriter, emitContext, printer, writer = snippetEmitTextWriter, factory }
local snippetPrinter = {}
snippetPrinter.__index = snippetPrinter
ls.snippetPrinter = snippetPrinter

--[[* Snippet-escaping version of `printer.printNode`. ]]
function snippetPrinter:printNode(node)
    local unescaped = self:printUnescapedNode(node)
    if core.Len(self.writer.escapes) > 0 then
        return core.ApplyBulkEdits(unescaped, self.writer.escapes)
    end
    return unescaped
end

function snippetPrinter:printUnescapedNode(node)
    self.writer.escapes = nil
    self.writer:Clear()
    self.printer:Write(node, nil --[[sourceFile]], self.writer, nil --[[sourceMapGenerator]])
    return self.writer:String()
end

function snippetPrinter:printAndFormatNode(ctx, node, sourceFile)
    return self:printAndFormatNodeWithSettings(ctx, node, sourceFile, format.GetFormatCodeSettingsFromContext(ctx))
end

function snippetPrinter:printAndFormatNodeWithSettings(ctx, node, sourceFile, formatOptions)
    local text = self:printUnescapedNode(node)
    local nodeWithPos = self.baseWriter:AssignPositionsToNode(node, self.factory)
    local syntheticFile = printer.CreateSyntheticSourceFile(self.factory, nodeWithPos, text, sourceFile:ParseOptions())
    ctx = format.WithFormatCodeSettings(ctx, formatOptions, formatOptions.newLineCharacter)
    local changes = format.FormatNodeGivenIndentation(
        ctx,
        nodeWithPos,
        syntheticFile,
        sourceFile.languageVariant,
        0, --[[initialIndentation]]
        0 --[[delta]]
    )

    local allChanges = changes
    if core.Len(self.writer.escapes) > 0 then
        allChanges = {}
        for _, ch in ipairs(changes or {}) do
            allChanges[#allChanges + 1] = ch
        end
        for _, ch in ipairs(self.writer.escapes) do
            allChanges[#allChanges + 1] = ch
        end
        core.SortFunc(allChanges, function(a, b)
            return core.CompareTextRanges(a, b)
        end)
    end

    return core.ApplyBulkEdits(syntheticFile:Text(), allChanges)
end

function ls.createSnippetPrinter(options, emitContext)
    if emitContext == nil then
        emitContext = printer.NewEmitContext()
    end
    local baseWriter = printer.NewChangeTrackerWriter(core.NewLineKind_GetNewLineCharacter(options.newLine or 0), -1)
    local p = printer.NewPrinter(options, baseWriter:GetPrintHandlers(), emitContext)
    local writer = ls.newSnippetEmitTextWriter(baseWriter)
    return setmetatable({
        baseWriter = baseWriter,
        emitContext = emitContext,
        printer = p,
        writer = writer,
        factory = emitContext.factory:AsNodeFactory(),
    }, snippetPrinter)
end

-- Override base writer methods to perform snippet escaping.
-- snippetEmitTextWriter: { changeTrackerWriter = *printer.ChangeTrackerWriter, escapes = []core.TextChange }
-- Go embeds *printer.ChangeTrackerWriter: methods not overridden here are promoted from the embedded
-- writer (called with the embedded writer as receiver).
local snippetEmitTextWriter = {}
ls.snippetEmitTextWriter = snippetEmitTextWriter
local snippetEmitTextWriterMT = {
    __index = function(w, k)
        local m = snippetEmitTextWriter[k]
        if m ~= nil then
            return m
        end
        local base = rawget(w, "changeTrackerWriter")
        local v = base[k]
        if type(v) == "function" then
            local bound = function(_, ...)
                return v(base, ...)
            end
            rawset(w, k, bound)
            return bound
        end
        return v
    end,
}
ls.snippetEmitTextWriterMT = snippetEmitTextWriterMT

function ls.newSnippetEmitTextWriter(changeTrackerWriter)
    return setmetatable({ changeTrackerWriter = changeTrackerWriter, escapes = nil }, snippetEmitTextWriterMT)
end

function snippetEmitTextWriter:Write(s)
    self:escapingWrite(s, function() self.changeTrackerWriter:Write(s) end)
end

function snippetEmitTextWriter:WriteComment(text)
    self:escapingWrite(text, function() self.changeTrackerWriter:WriteComment(text) end)
end

function snippetEmitTextWriter:WriteStringLiteral(text)
    self:escapingWrite(text, function() self.changeTrackerWriter:WriteStringLiteral(text) end)
end

function snippetEmitTextWriter:WriteParameter(text)
    self:escapingWrite(text, function() self.changeTrackerWriter:WriteParameter(text) end)
end

function snippetEmitTextWriter:WriteProperty(text)
    self:escapingWrite(text, function() self.changeTrackerWriter:WriteProperty(text) end)
end

function snippetEmitTextWriter:WriteSymbol(text, symbol)
    self:escapingWrite(text, function() self.changeTrackerWriter:WriteSymbol(text, symbol) end)
end

-- The formatter/scanner will have issues with snippet-escaped text,
-- so instead of writing the escaped text directly to the writer,
-- generate a set of changes that can be applied to the unescaped text
-- to escape it post-formatting.
function snippetEmitTextWriter:escapingWrite(s, write)
    local escaped = ls.escapeSnippetText(s)
    if escaped ~= s then
        local start = self:GetTextPos()
        write()
        local end_ = self:GetTextPos()
        local escapes = self.escapes or {}
        escapes[#escapes + 1] = core.NewTextChange(core.NewTextRange(start, end_), escaped)
        self.escapes = escapes
    else
        write()
    end
end
