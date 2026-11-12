-- Go internal/ls/completions.go, part 1: ErrNeedsAutoImports .. completionInfoFromData
local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local autoimport = require("tslua.ls.autoimport")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local format = require("tslua.format")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local CompletionKind = ls.CompletionKind
local KeywordCompletionFilters = ls.KeywordCompletionFilters
local SortText = ls.SortText

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

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

local function appendAll(xs, ys)
    for _, y in ipairs(ys or {}) do
        xs[#xs + 1] = y
    end
    return xs
end

-- Unexported constants of completions.go (consts_generated.lua only carries exported ones).
ls.symbolOriginInfoKind = {
    ThisType = 1 << 0,
    SymbolMember = 1 << 1,
    Promise = 1 << 2,
    Nullable = 1 << 3,
    TypeOnlyAlias = 1 << 4,
    ObjectLiteralMethod = 1 << 5,
    Ignore = 1 << 6,
    ComputedPropertyName = 1 << 7,
}
local symbolOriginInfoKind = ls.symbolOriginInfoKind

ls.completionSource = {
    -- Completions that require `this.` insertion text.
    ThisProperty = "ThisProperty/",
    -- Auto-import that comes attached to a class member snippet.
    ClassMemberSnippet = "ClassMemberSnippet/",
    -- A type-only import that needs to be promoted in order to be used at the completion location.
    TypeOnlyAlias = "TypeOnlyAlias/",
    -- Auto-import that comes attached to an object literal method snippet.
    ObjectLiteralMethodSnippet = "ObjectLiteralMethodSnippet/",
    -- Case completions for switch statements.
    SwitchCases = "SwitchCases/",
    -- Completions for an object literal expression.
    ObjectLiteralMemberWithComma = "ObjectLiteralMemberWithComma/",
}

ls.globalsSearch = {
    Continue = 0,
    Success = 1,
    Fail = 2,
}
local globalsSearch = ls.globalsSearch

ls.ErrNeedsAutoImports = {
    Error = function()
        return "completion list needs auto imports"
    end,
}

function LanguageService:ProvideCompletion(ctx, documentURI, LSPPosition, context)
    local program, file = self:getProgramAndFile(documentURI)
    local triggerCharacter = nil
    if context ~= nil then
        triggerCharacter = context.triggerCharacter
    end
    ctx = format.WithFormatCodeSettings(ctx, self:FormatOptions(), self:FormatOptions().newLineCharacter)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, LSPPosition, spanmap.Feature.Completion)
    if #positions == 0 or not spanmap.Fidelity_IsExact(positions[1].fidelity) then
        -- In a content-mapped file the cursor is outside a verbatim span, so any completion committed here
        -- could not be applied to the original text. Offer nothing rather than edits at a bogus location.
        return {}, nil
    end
    file = positions[1].script
    local position = positions[1].position
    local completionListInternal, err = self:getCompletionsAtPosition(
        ctx,
        file,
        position,
        triggerCharacter,
        false --[[includeSymbols]]
    )
    if err ~= nil then
        return {}, err
    end
    local completionList = ls.ensureItemData(file, position, ls.CompletionList.toLSP(completionListInternal))
    if file:SpanMap() ~= nil then
        self:filterContentMappedAutoImports(ctx, program, file, completionList)
    end
    return { list = completionList }, nil
end

-- filterContentMappedAutoImports eagerly resolves auto-import edits for a content-mapped file and drops any
-- completion whose import edit cannot be placed entirely within verbatim spans (it would otherwise insert
-- an import into synthesized virtual code with no counterpart in the original file). Surviving auto-imports carry
-- their additional edits directly so the client applies correct original-text positions on commit.
function LanguageService:filterContentMappedAutoImports(ctx, program, file, list)
    if list == nil then
        return
    end
    local filtered = {}
    for _, item in ipairs(list.items or {}) do
        if item.data == nil or item.data.autoImport == nil then
            filtered[#filtered + 1] = item
            goto continue
        end
        do
            local edits, description, ok = newAutoImportFix(item.data.autoImport):Edits(
                ctx,
                file,
                program:Options(),
                self:FormatOptions(),
                self.converters,
                self:UserPreferences()
            )
            if not ok then
                goto continue
            end
            item.additionalTextEdits = edits
            item.detail = ls.strPtrTo(description)
            filtered[#filtered + 1] = item
        end
        ::continue::
    end
    list.items = filtered
end

function LanguageService:GetCompletionsAtPosition(ctx, file, position, triggerCharacter, includeSymbols)
    return self:getCompletionsAtPosition(ctx, file, position, triggerCharacter, includeSymbols)
end

-- CompletionItem embeds *lsproto.CompletionItem: every field other than `completionItem` and `symbol`
-- reads and writes through to the embedded item (shared, like Go's embedded pointer).
local CompletionItem = {}
ls.CompletionItem = CompletionItem
CompletionItem.__index = function(t, k)
    local ci = rawget(t, "completionItem")
    if ci ~= nil then
        return ci[k]
    end
    return nil
end
CompletionItem.__newindex = function(t, k, v)
    rawget(t, "completionItem")[k] = v
end

function ls.NewCompletionItem(item, symbol)
    local t = { completionItem = item, symbol = symbol }
    return setmetatable(t, CompletionItem)
end

-- CompletionList: { isIncomplete, itemDefaults, applyKind, items }
local CompletionList = {}
CompletionList.__index = CompletionList
ls.CompletionList = CompletionList

function ls.ensureItemData(file, pos, list)
    if list == nil then
        return nil
    end
    for _, item in ipairs(list.items or {}) do
        if item.data == nil then
            item.data = {
                fileName = file:OriginalFileName(),
                position = pos,
                supplementalFileIndex = ls.supplementalFileIndex(file),
                source = "",
                name = item.label,
                autoImport = nil,
                isImportStatementCompletion = false,
            }
        end
    end
    return list
end

function ls.supplementalFileIndex(file)
    local canonical = file:CanonicalSourceFile()
    if canonical == nil then
        return nil
    end
    for i, supplemental in ipairs(canonical:SupplementalSourceFiles() or {}) do
        if supplemental == file then
            return i - 1
        end
    end
    error("supplemental source file is not linked from its canonical source file", 0)
end

function ls.sourceFileForSupplementalFileIndex(file, index)
    if index == nil then
        return file
    end
    local supplemental = file:SupplementalSourceFiles() or {}
    if index >= 0 and index < #supplemental then
        return supplemental[index + 1]
    end
    return nil
end

-- completionData = *completionDataData | *completionDataKeyword | *completionDataJSDocTagName |
-- *completionDataJSDocTag | *completionDataJSDocParameterName (discriminated by metatable).
ls.completionDataData = {}
ls.completionDataData.__index = ls.completionDataData
ls.completionDataKeyword = {}
ls.completionDataKeyword.__index = ls.completionDataKeyword
ls.completionDataJSDocTagName = {}
ls.completionDataJSDocTagName.__index = ls.completionDataJSDocTagName
ls.completionDataJSDocTag = {}
ls.completionDataJSDocTag.__index = ls.completionDataJSDocTag
ls.completionDataJSDocParameterName = {}
ls.completionDataJSDocParameterName.__index = ls.completionDataJSDocParameterName

-- importStatementCompletionInfo is a Go value struct.
function ls.newImportStatementCompletionInfo()
    return {
        isKeywordOnlyCompletion = false,
        keywordCompletion = Kind.Unknown,
        isNewIdentifierLocation = false,
        isTopLevelTypeOnly = false,
        couldBeTypeOnlyImportSpecifier = false,
        replacementSpan = nil,
    }
end

-- jsxInitializer: if we're after the `=` sign but no identifier has been typed yet,
-- value will be `true` but initializer will be `nil`.
function ls.newJsxInitializer()
    return { isInitializer = false, initializer = nil }
end

function ls.keywordFiltersFromSyntaxKind(keywordCompletion)
    if keywordCompletion == Kind.TypeKeyword then
        return KeywordCompletionFilters.TypeKeyword
    end
    error("Unknown mapping from ast.Kind `" .. ast.Kind_String(keywordCompletion) .. "` to KeywordCompletionFilters", 0)
end

ls.CompletionTriggerCharacters = { ".", '"', "'", "`", "/", "@", "<", "#", " ", "*" }

-- All commit characters, valid when `isNewIdentifierLocation` is false.
ls.allCommitCharacters = { ".", ",", ";" }

-- Commit characters valid at expression positions where we could be inside a parameter list.
ls.noCommaCommitCharacters = { ".", ";" }

ls.emptyCommitCharacters = {}

function ls.DeprecateSortText(original)
    return "z" .. original
end

function ls.ObjectLiteralPropertySortText(presetSortText, symbolDisplayName)
    return presetSortText .. "\0" .. symbolDisplayName .. "\0"
end

function ls.SortBelow(original)
    return original .. "1"
end

-- symbolOriginInfo: { kind, isDefaultExport, isFromPackageJson, fileName, data }
local symbolOriginInfo = {}
symbolOriginInfo.__index = symbolOriginInfo
ls.symbolOriginInfo = symbolOriginInfo

function ls.newSymbolOriginInfo(t)
    t.kind = t.kind or 0
    if t.isDefaultExport == nil then
        t.isDefaultExport = false
    end
    if t.isFromPackageJson == nil then
        t.isFromPackageJson = false
    end
    t.fileName = t.fileName or ""
    return setmetatable(t, symbolOriginInfo)
end

function symbolOriginInfo:symbolName()
    if self.data ~= nil and getmetatable(self.data) == ls.symbolOriginInfoComputedPropertyName then
        return self.data.symbolName
    end
    error("symbolOriginInfo: unknown data type for symbolName()", 0)
end

-- symbolOriginInfoObjectLiteralMethod: { insertText, labelDetails, isSnippet }
ls.symbolOriginInfoObjectLiteralMethod = {}
ls.symbolOriginInfoObjectLiteralMethod.__index = ls.symbolOriginInfoObjectLiteralMethod

function symbolOriginInfo:asObjectLiteralMethod()
    if getmetatable(self.data) ~= ls.symbolOriginInfoObjectLiteralMethod then
        error("interface conversion: symbolOriginInfo.data is not *symbolOriginInfoObjectLiteralMethod", 0)
    end
    return self.data
end

-- symbolOriginInfoTypeOnlyAlias: { declaration }
ls.symbolOriginInfoTypeOnlyAlias = {}
ls.symbolOriginInfoTypeOnlyAlias.__index = ls.symbolOriginInfoTypeOnlyAlias

-- symbolOriginInfoComputedPropertyName: { symbolName }
ls.symbolOriginInfoComputedPropertyName = {}
ls.symbolOriginInfoComputedPropertyName.__index = ls.symbolOriginInfoComputedPropertyName

function CompletionList.toLSP(l)
    if l == nil then
        return nil
    end
    local items = {}
    for _, entry in ipairs(l.items or {}) do
        if entry ~= nil and entry.completionItem ~= nil then
            items[#items + 1] = entry.completionItem
        end
    end
    return {
        isIncomplete = l.isIncomplete or false,
        itemDefaults = l.itemDefaults,
        applyKind = l.applyKind,
        items = items,
    }
end

function LanguageService:getCompletionsAtPosition(ctx, file, position, triggerCharacter, includeSymbols)
    local _, previousToken = ls.getRelevantTokens(position, file)
    if triggerCharacter ~= nil and not ls.IsInString(file, position, previousToken) and
        not ls.isValidTrigger(file, triggerCharacter, previousToken, position) then
        return nil, nil
    end

    if triggerCharacter ~= nil and triggerCharacter == " " then
        -- `isValidTrigger` ensures we are at `import |`
        if core.Tristate_IsTrue(self:UserPreferences().includeCompletionsForImportStatements) then
            return setmetatable({ isIncomplete = true }, CompletionList), nil
        end
        return nil, nil
    end

    local jsDocSnippetCompletion = self:getJSDocSnippetCompletion(ctx, file, position)
    if jsDocSnippetCompletion ~= nil then
        return jsDocSnippetCompletion, nil
    end

    local compilerOptions = self:GetProgram():Options()

    -- !!! see if incomplete completion list and continue or clean

    local typeChecker, done = self:GetProgram():GetTypeCheckerForFile(ctx, file)
    local function finish(...)
        if done ~= nil then
            done()
        end
        return ...
    end

    local stringCompletions = self:getStringLiteralCompletions(
        ctx,
        file,
        position,
        previousToken,
        typeChecker,
        compilerOptions,
        includeSymbols
    )
    if stringCompletions ~= nil then
        return finish(stringCompletions, nil)
    end

    if previousToken ~= nil and (previousToken.kind == Kind.BreakKeyword or
            previousToken.kind == Kind.ContinueKeyword or
            previousToken.kind == Kind.Identifier) and
        ast.IsBreakOrContinueStatement(previousToken.parent) then
        return finish(self:getLabelCompletionsAtPosition(
            ctx,
            previousToken.parent,
            file,
            position,
            self:getOptionalReplacementSpan(previousToken, file)
        ), nil)
    end

    local preferences = self:UserPreferences()
    local data, err = self:getCompletionData(ctx, typeChecker, file, position, preferences, false --[[forItemResolve]])
    if err ~= nil then
        return finish(nil, err)
    end
    if data == nil then
        return finish(nil, nil)
    end

    local mt = getmetatable(data)
    if mt == ls.completionDataData then
        local optionalReplacementSpan = self:getOptionalReplacementSpan(data.location, file)
        local response, err2 = self:completionInfoFromData(
            ctx,
            typeChecker,
            file,
            compilerOptions,
            data,
            position,
            optionalReplacementSpan,
            includeSymbols
        )
        if err2 ~= nil then
            return finish(nil, err2)
        end
        return finish(response, nil)
    elseif mt == ls.completionDataKeyword then
        local optionalReplacementSpan = self:getOptionalReplacementSpan(previousToken, file)
        return finish(self:specificKeywordCompletionInfo(
            ctx,
            position,
            file,
            data.keywordCompletions,
            data.isNewIdentifierLocation,
            optionalReplacementSpan
        ), nil)
    elseif mt == ls.completionDataJSDocTagName then
        -- If the current position is a jsDoc tag name, only tag names should be provided for completion
        local items = ls.getJSDocTagNameCompletions() or {}
        items = appendAll(items, ls.getJSDocParameterCompletions(
            ctx,
            file,
            position,
            typeChecker,
            compilerOptions,
            preferences,
            true --[[tagNameOnly]]
        ))
        return finish(self:jsDocCompletionInfo(ctx, position, file, items), nil)
    elseif mt == ls.completionDataJSDocTag then
        -- If the current position is a jsDoc tag, only tags should be provided for completion
        local items = ls.getJSDocTagCompletions() or {}
        items = appendAll(items, ls.getJSDocParameterCompletions(
            ctx,
            file,
            position,
            typeChecker,
            compilerOptions,
            preferences,
            false --[[tagNameOnly]]
        ))
        return finish(self:jsDocCompletionInfo(ctx, position, file, items), nil)
    elseif mt == ls.completionDataJSDocParameterName then
        return finish(self:jsDocCompletionInfo(ctx, position, file, ls.getJSDocParameterNameCompletions(data.tag)), nil)
    else
        finish()
        error("getCompletionData() returned unexpected type", 0)
    end
end

function LanguageService:getCompletionData(ctx, typeChecker, file, position, preferences, forItemResolve)
    local l = self
    local inCheckedFile = ls.isCheckedFile(file, l:GetProgram():Options())

    local currentToken = astnav.GetTokenAtPosition(file, position)

    local insideComment = ls.isInComment(file, position, currentToken)

    local insideJSDocTagTypeExpression = false
    local insideJsDocImportTag = false
    local isInSnippetScope = false
    if insideComment ~= nil then
        if ls.hasDocComment(file, position) then
            if position > 0 and string.byte(file:Text(), position) == 64 --[[@]] then
                -- The current position is next to the '@' sign, when no tag name being provided yet.
                -- Provide a full list of tag names
                return setmetatable({}, ls.completionDataJSDocTagName), nil
            else
                -- When completion is requested without "@", we will have check to make sure that
                -- there are no comments prefix the request position. We will only allow "*" and space.
                -- e.g
                --   /** |c| /*
                --
                --   /**
                --     |c|
                --    */
                --
                --   /**
                --    * |c|
                --    */
                --
                --   /**
                --    *         |c|
                --    */
                local lineStart = format.GetLineStartPositionForPosition(position, file)
                local noCommentPrefix = true
                local text = file:Text()
                local i = lineStart
                while i < position do
                    local r, size = stringutil.DecodeRune(text, i)
                    if not (stringutil.IsWhiteSpaceSingleLine(r) or r == 42 --[[*]] or r == 47 --[[/]] or
                            r == 40 --[[(]] or r == 41 --[[)]] or r == 124 --[[|]]) then
                        noCommentPrefix = false
                        break
                    end
                    i = i + size
                end
                if noCommentPrefix then
                    return setmetatable({}, ls.completionDataJSDocTag), nil
                end
            end
        end

        -- Completion should work inside certain JSDoc tags. For example:
        --     /** @type {number | string} */
        -- Completion should work in the brackets
        local tag = ls.getJSDocTagAtPosition(currentToken, position)
        if tag ~= nil then
            if tag:TagName():Pos() <= position and position <= tag:TagName():End() then
                return setmetatable({}, ls.completionDataJSDocTagName), nil
            end
            if ast.IsJSDocImportTag(tag) then
                insideJsDocImportTag = true
            else
                local typeExpression = ls.tryGetTypeExpressionFromTag(tag)
                if typeExpression ~= nil then
                    currentToken = astnav.GetTokenAtPosition(file, position)
                    if currentToken == nil or
                        (not ast.IsDeclarationName(currentToken) and
                            (currentToken.parent.kind ~= Kind.JSDocPropertyTag or
                                currentToken.parent:Name() ~= currentToken)) then
                        -- Use as type location if inside tag's type expression
                        insideJSDocTagTypeExpression = ls.isCurrentlyEditingNode(typeExpression, file, position)
                    end
                end
                if not insideJSDocTagTypeExpression and
                    ast.IsJSDocParameterTag(tag) and
                    (ast.NodeIsMissing(tag:Name()) or tag:Name():Pos() <= position and position <= tag:Name():End()) then
                    return setmetatable({
                        tag = tag:AsJSDocParameterOrPropertyTag(),
                    }, ls.completionDataJSDocParameterName), nil
                end
            end
        end

        if not insideJSDocTagTypeExpression and not insideJsDocImportTag then
            -- Proceed if the current position is in JSDoc tag expression; otherwise it is a normal
            -- comment or the plain text part of a JSDoc comment, so no completion should be available
            return nil, nil
        end
    end

    -- The decision to provide completion depends on the contextToken, which is determined through the previousToken.
    -- Note: 'previousToken' (and thus 'contextToken') can be undefined if we are the beginning of the file
    local isJSOnlyLocation = not insideJSDocTagTypeExpression and not insideJsDocImportTag and ast.IsSourceFileJS(file)
    local contextToken, previousToken = ls.getRelevantTokens(position, file)

    -- Find the node where completion is requested on.
    -- Also determine whether we are trying to complete with members of that node
    -- or attributes of a JSX tag.
    local node = currentToken
    local propertyAccessToConvert = nil
    local isRightOfDot = false
    local isRightOfQuestionDot = false
    local isRightOfOpenTag = false
    local isStartingCloseTag = false
    local jsxInitializer = ls.newJsxInitializer()
    local isJsxIdentifierExpected = false
    local importStatementCompletion = nil
    local location = astnav.GetTouchingPropertyName(file, position)
    local keywordFilters = KeywordCompletionFilters.None
    local isNewIdentifierLocation = false
    -- !!! flags := CompletionInfoFlagsNone
    local defaultCommitCharacters = nil

    if contextToken ~= nil then
        local importStatementCompletionInfo = l:getImportStatementCompletionInfo(contextToken, file)
        if importStatementCompletionInfo.keywordCompletion ~= Kind.Unknown then
            if importStatementCompletionInfo.isKeywordOnlyCompletion then
                return setmetatable({
                    keywordCompletions = { ls.NewCompletionItem({
                        label = scanner.TokenToString(importStatementCompletionInfo.keywordCompletion),
                        kind = lsproto.CompletionItemKind.Keyword,
                        sortText = SortText.GlobalsOrKeywords,
                    }, nil) },
                    isNewIdentifierLocation = importStatementCompletionInfo.isNewIdentifierLocation,
                }, ls.completionDataKeyword), nil
            end
            keywordFilters = ls.keywordFiltersFromSyntaxKind(importStatementCompletionInfo.keywordCompletion)
        end
        if importStatementCompletionInfo.replacementSpan ~= nil and core.Tristate_IsTrue(preferences.includeCompletionsForImportStatements) then
            -- !!! flags |= CompletionInfoFlags.IsImportStatementCompletion;
            importStatementCompletion = importStatementCompletionInfo
            isNewIdentifierLocation = importStatementCompletionInfo.isNewIdentifierLocation
        end
        -- Bail out if this is a known invalid completion location.
        if importStatementCompletionInfo.replacementSpan == nil and ls.isCompletionListBlocker(contextToken, previousToken, location, file, position, typeChecker) then
            if keywordFilters ~= KeywordCompletionFilters.None then
                local isNewIdentifierLocation2 = ls.computeCommitCharactersAndIsNewIdentifier(contextToken, file, position)
                return ls.keywordCompletionData(keywordFilters, isJSOnlyLocation, isNewIdentifierLocation2), nil
            end
            return nil, nil
        end

        local parent = contextToken.parent
        if contextToken.kind == Kind.DotToken or contextToken.kind == Kind.QuestionDotToken then
            isRightOfDot = contextToken.kind == Kind.DotToken
            isRightOfQuestionDot = contextToken.kind == Kind.QuestionDotToken
            local pk = parent.kind
            if pk == Kind.PropertyAccessExpression then
                propertyAccessToConvert = parent
                node = propertyAccessToConvert:Expression()
                local leftMostAccessExpression = ast.GetLeftmostAccessExpression(parent)
                if ast.NodeIsMissing(leftMostAccessExpression) or
                    ((ast.IsCallExpression(node) or ast.IsFunctionLike(node)) and
                        node:End() == contextToken:Pos() and
                        lsutil.GetLastChild(node, file).kind ~= Kind.CloseParenToken) then
                    -- This is likely dot from incorrectly parsed expression and user is starting to write spread
                    -- eg: Math.min(./**/)
                    -- const x = function (./**/) {}
                    -- ({./**/})
                    return nil, nil
                end
            elseif pk == Kind.QualifiedName then
                node = parent:AsQualifiedName().left
            elseif pk == Kind.ModuleDeclaration then
                node = parent:Name()
            elseif pk == Kind.ImportType then
                node = parent
            elseif pk == Kind.MetaProperty then
                node = lsutil.GetFirstToken(parent, file)
                if node.kind ~= Kind.ImportKeyword and node.kind ~= Kind.NewKeyword then
                    error("Unexpected token kind: " .. ast.Kind_String(node.kind), 0)
                end
            else
                -- There is nothing that precedes the dot, so this likely just a stray character
                -- or leading into a '...' token. Just bail out instead.
                return nil, nil
            end
        elseif importStatementCompletion == nil then
            -- <UI.Test /* completion position */ />
            -- If the tagname is a property access expression, we will then walk up to the top most of property access expression.
            -- Then, try to get a JSX container and its associated attributes type.
            if parent ~= nil and parent.kind == Kind.PropertyAccessExpression then
                contextToken = parent
                parent = parent.parent
            end

            -- Fix location
            if parent == location then
                if currentToken.kind == Kind.GreaterThanToken then
                    if parent.kind == Kind.JsxElement or parent.kind == Kind.JsxOpeningElement then
                        location = currentToken
                    end
                elseif currentToken.kind == Kind.LessThanSlashToken then
                    if parent.kind == Kind.JsxSelfClosingElement then
                        location = currentToken
                    end
                end
            end

            local pk = parent.kind
            local jsxOpenCase = false
            if pk == Kind.JsxClosingElement then
                if contextToken.kind == Kind.LessThanSlashToken then
                    isStartingCloseTag = true
                    location = contextToken
                end
            elseif pk == Kind.BinaryExpression then
                if ls.binaryExpressionMayBeOpenTag(parent:AsBinaryExpression()) then
                    jsxOpenCase = true -- fallthrough
                end
            elseif pk == Kind.JsxSelfClosingElement or pk == Kind.JsxElement or pk == Kind.JsxOpeningElement then
                jsxOpenCase = true
            elseif pk == Kind.JsxExpression or pk == Kind.JsxSpreadAttribute then
                -- First case is for `<div foo={true} [||] />` or `<div foo={true} [||] ></div>`,
                -- `parent` will be `{true}` and `previousToken` will be `}`.
                -- Second case is for `<div foo={true} t[||] ></div>`.
                -- Second case must not match for `<div foo={undefine[||]}></div>`.
                if previousToken.kind == Kind.CloseBraceToken or
                    previousToken.kind == Kind.Identifier and previousToken.parent.kind == Kind.JsxAttribute then
                    isJsxIdentifierExpected = true
                end
            elseif pk == Kind.JsxAttribute then
                -- For `<div className="x" [||] ></div>`, `parent` will be JsxAttribute and `previousToken` will be its initializer.
                if parent:Initializer() == previousToken and previousToken:End() < position then
                    isJsxIdentifierExpected = true
                else
                    if previousToken.kind == Kind.EqualsToken then
                        jsxInitializer.isInitializer = true
                    elseif previousToken.kind == Kind.Identifier then
                        isJsxIdentifierExpected = true
                        -- For `<div x=[|f/**/|]`, `parent` will be `x` and `previousToken.parent` will be `f` (which is its own JsxAttribute).
                        -- Note for `<div someBool f>` we don't want to treat this as a jsx inializer, instead it's the attribute name.
                        if parent ~= previousToken.parent and
                            parent:Initializer() == nil and
                            astnav.FindChildOfKind(parent, Kind.EqualsToken, file) ~= nil then
                            jsxInitializer.initializer = previousToken
                        end
                    end
                end
            end
            if jsxOpenCase then
                isJsxIdentifierExpected = true
                if contextToken.kind == Kind.LessThanToken then
                    isRightOfOpenTag = true
                    location = contextToken
                end
            end
        end
    end

    local completionKind = CompletionKind.None
    local hasUnresolvedAutoImports = false
    -- This also gets mutated in nested-functions after the return
    local symbols = {}
    local autoImports = nil
    -- Keys are indexes of `symbols`.
    local symbolToOriginInfoMap = {}
    local symbolToSortTextMap = {}
    local seenPropertySymbols = collections.NewSet()
    local isTypeOnlyLocation = insideJSDocTagTypeExpression or insideJsDocImportTag or
        importStatementCompletion ~= nil and location.parent ~= nil and ast.IsTypeOnlyImportOrExportDeclaration(location.parent) or
        not ls.isContextTokenValueLocation(contextToken) and
            (ls.isPossiblyTypeArgumentPosition(contextToken, file, typeChecker) or
                ast.IsPartOfTypeNode(location) or
                ls.isContextTokenTypeLocation(contextToken))

    local function addSymbolOriginInfo(symbol, insertQuestionDot, insertAwait)
        local symbolId = ast.GetSymbolId(symbol)
        if insertAwait and seenPropertySymbols:AddIfAbsent(symbolId) then
            symbolToOriginInfoMap[#symbols - 1] = ls.newSymbolOriginInfo({ kind = ls.getNullableSymbolOriginInfoKind(symbolOriginInfoKind.Promise, insertQuestionDot) })
        elseif insertQuestionDot then
            symbolToOriginInfoMap[#symbols - 1] = ls.newSymbolOriginInfo({ kind = symbolOriginInfoKind.Nullable })
        end
    end

    local function addSymbolSortInfo(symbol)
        local symbolId = ast.GetSymbolId(symbol)
        if ls.isStaticProperty(symbol) then
            symbolToSortTextMap[symbolId] = SortText.LocalDeclarationPriority
        end
    end

    local function addPropertySymbol(symbol, insertAwait, insertQuestionDot)
        -- For a computed property with an accessible name like `Symbol.iterator`,
        -- we'll add a completion for the *name* `Symbol` instead of for the property.
        -- If this is e.g. [Symbol.iterator], add a completion for `Symbol`.
        local computedPropertyName = core.FirstNonNil(symbol.declarations, function(decl)
            local name = ast.GetNameOfDeclaration(decl)
            if name ~= nil and name.kind == Kind.ComputedPropertyName then
                return name
            end
            return nil
        end)

        if computedPropertyName ~= nil then
            local leftMostName = ls.getLeftMostName(computedPropertyName:Expression()) -- The completion is for `Symbol`, not `iterator`.
            local nameSymbol = nil
            if leftMostName ~= nil then
                nameSymbol = typeChecker:GetSymbolAtLocation(leftMostName)
            end
            -- If this is nested like for `namespace N { export const sym = Symbol(); }`, we'll add the completion for `N`.
            local firstAccessibleSymbol = nil
            if nameSymbol ~= nil then
                firstAccessibleSymbol = ls.getFirstSymbolInChain(nameSymbol, contextToken, typeChecker)
            end
            local firstAccessibleSymbolId = 0
            if firstAccessibleSymbol ~= nil then
                firstAccessibleSymbolId = ast.GetSymbolId(firstAccessibleSymbol)
            end
            if firstAccessibleSymbolId ~= 0 and seenPropertySymbols:AddIfAbsent(firstAccessibleSymbolId) then
                symbols[#symbols + 1] = firstAccessibleSymbol
                symbolToSortTextMap[firstAccessibleSymbolId] = SortText.GlobalsOrKeywords
                local moduleSymbol = firstAccessibleSymbol.parent
                if moduleSymbol == nil or
                    not checker.IsExternalModuleSymbol(moduleSymbol) or
                    typeChecker:TryGetMemberInModuleExportsAndProperties(firstAccessibleSymbol.name, moduleSymbol) ~= firstAccessibleSymbol then
                    symbolToOriginInfoMap[#symbols - 1] = ls.newSymbolOriginInfo({ kind = ls.getNullableSymbolOriginInfoKind(symbolOriginInfoKind.SymbolMember, insertQuestionDot) })
                else -- luacheck: ignore 542
                    -- !!! auto-import symbol
                end
            elseif firstAccessibleSymbolId == 0 or not seenPropertySymbols:Has(firstAccessibleSymbolId) then
                symbols[#symbols + 1] = symbol
                addSymbolOriginInfo(symbol, insertQuestionDot, insertAwait)
                addSymbolSortInfo(symbol)
            end
        else
            symbols[#symbols + 1] = symbol
            addSymbolOriginInfo(symbol, insertQuestionDot, insertAwait)
            addSymbolSortInfo(symbol)
        end
    end

    local function addTypeProperties(t, insertAwait, insertQuestionDot)
        if typeChecker:GetStringIndexType(t) ~= nil then
            isNewIdentifierLocation = true
            defaultCommitCharacters = {}
        end
        if isRightOfQuestionDot and #(typeChecker:GetCallSignatures(t) or {}) ~= 0 then
            isNewIdentifierLocation = true
            if defaultCommitCharacters == nil then
                defaultCommitCharacters = core.Slice(ls.allCommitCharacters, 0, #ls.allCommitCharacters) -- Only invalid commit character here would be `(`.
            end
        end

        local propertyAccess
        if node.kind == Kind.ImportType then
            propertyAccess = node
        else
            propertyAccess = node.parent
        end

        if inCheckedFile then
            for _, symbol in ipairs(typeChecker:GetApparentProperties(t) or {}) do
                if typeChecker:IsValidPropertyAccessForCompletions(propertyAccess, t, symbol) then
                    addPropertySymbol(symbol, false --[[insertAwait]], insertQuestionDot)
                end
            end
        else
            -- In javascript files, for union types, we don't just get the members that
            -- the individual types have in common, we also include all the members that
            -- each individual type has. This is because we're going to add all identifiers
            -- anyways. So we might as well elevate the members that were at least part
            -- of the individual types to a higher status since we know what they are.
            for _, symbol in ipairs(ls.getPropertiesForCompletion(t, typeChecker) or {}) do
                if typeChecker:IsValidPropertyAccessForCompletions(propertyAccess, t, symbol) then
                    symbols[#symbols + 1] = symbol
                end
            end
        end

        if insertAwait then
            local promiseType = typeChecker:GetPromisedTypeOfPromise(t)
            if promiseType ~= nil then
                for _, symbol in ipairs(typeChecker:GetApparentProperties(promiseType) or {}) do
                    if typeChecker:IsValidPropertyAccessForCompletions(propertyAccess, promiseType, symbol) then
                        addPropertySymbol(symbol, true --[[insertAwait]], insertQuestionDot)
                    end
                end
            end
        end
    end

    local function getTypeScriptMemberSymbols()
        -- Right of dot member completion list
        completionKind = CompletionKind.PropertyAccess

        -- Since this is qualified name check it's a type node location
        local isImportType = ast.IsLiteralImportTypeNode(node)
        local isTypeLocation = (isImportType and not node:AsImportTypeNode().isTypeOf) or
            ast.IsPartOfTypeNode(node.parent) or
            ls.isPossiblyTypeArgumentPosition(contextToken, file, typeChecker)
        local isRhsOfImportDeclaration = ls.isInRightSideOfInternalImportEqualsDeclaration(node)
        if ast.IsEntityName(node) or isImportType or ast.IsPropertyAccessExpression(node) then
            local isNamespaceName = ast.IsModuleDeclaration(node.parent)
            if isNamespaceName then
                isNewIdentifierLocation = true
                defaultCommitCharacters = {}
            end
            local symbol = typeChecker:GetSymbolAtLocation(node)
            if symbol ~= nil then
                symbol = checker.SkipAlias(symbol, typeChecker)
                if symbol.flags & (SymbolFlags.Module | SymbolFlags.Enum) ~= 0 then
                    local valueAccessNode
                    if isImportType then
                        valueAccessNode = node
                    else
                        valueAccessNode = node.parent
                    end
                    -- Extract module or enum members
                    local exportedSymbols = typeChecker:GetExportsOfModule(symbol)
                    for _, exportedSymbol in ipairs(exportedSymbols or {}) do
                        if exportedSymbol == nil then
                            error("getExporsOfModule() should all be defined", 0)
                        end
                        local function isValidValueAccess(s)
                            return typeChecker:IsValidPropertyAccess(valueAccessNode, s.name)
                        end
                        local function isValidTypeAccess(s)
                            return ls.symbolCanBeReferencedAtTypeLocation(s, typeChecker, collections.NewSet())
                        end
                        local isValidAccess
                        if isNamespaceName then
                            -- At `namespace N.M/**/`, if this is the only declaration of `M`, don't include `M` as a completion.
                            isValidAccess = exportedSymbol.flags & SymbolFlags.Namespace ~= 0 and
                                not core.Every(exportedSymbol.declarations, function(declaration)
                                    return declaration.parent == node.parent
                                end)
                        elseif isRhsOfImportDeclaration then
                            -- Any kind is allowed when dotting off namespace in internal import equals declaration
                            isValidAccess = isValidTypeAccess(exportedSymbol) or isValidValueAccess(exportedSymbol)
                        elseif isTypeLocation or insideJSDocTagTypeExpression then
                            isValidAccess = isValidTypeAccess(exportedSymbol)
                        else
                            isValidAccess = isValidValueAccess(exportedSymbol)
                        end
                        if isValidAccess then
                            symbols[#symbols + 1] = exportedSymbol
                        end
                    end

                    -- If the module is merged with a value, we must get the type of the class and add its properties (for inherited static methods).
                    if not isTypeLocation and not insideJSDocTagTypeExpression and
                        core.Some(
                            symbol.declarations,
                            function(decl)
                                return decl.kind ~= Kind.SourceFile and decl.kind ~= Kind.ModuleDeclaration and decl.kind ~= Kind.EnumDeclaration
                            end
                        ) then
                        local t = typeChecker:GetNonOptionalType(typeChecker:GetTypeOfSymbolAtLocation(symbol, node))
                        local insertQuestionDot = false
                        if typeChecker:IsNullableType(t) then
                            local canCorrectToQuestionDot = isRightOfDot and not isRightOfQuestionDot and
                                not core.Tristate_IsFalse(preferences.includeAutomaticOptionalChainCompletions)
                            if canCorrectToQuestionDot or isRightOfQuestionDot then
                                t = typeChecker:GetNonNullableType(t)
                                if canCorrectToQuestionDot then
                                    insertQuestionDot = true
                                end
                            end
                        end
                        addTypeProperties(t, node.flags & NodeFlags.AwaitContext ~= 0, insertQuestionDot)
                    end

                    return
                end
            end
        end

        if not isTypeLocation or checker.IsInTypeQuery(node) then
            -- microsoft/TypeScript#39946. Pulling on the type of a node inside of a function with a contextual `this` parameter can result in a circularity
            -- if the `node` is part of the exprssion of a `yield` or `return`. This circularity doesn't exist at compile time because
            -- we will check (and cache) the type of `this` *before* checking the type of the node.
            typeChecker:TryGetThisTypeAtEx(node, false --[[includeGlobalThis]], nil)
            local t = typeChecker:GetNonOptionalType(typeChecker:GetTypeAtLocation(node))

            if not isTypeLocation then
                local insertQuestionDot = false
                if typeChecker:IsNullableType(t) then
                    local canCorrectToQuestionDot = isRightOfDot and not isRightOfQuestionDot and
                        not core.Tristate_IsFalse(preferences.includeAutomaticOptionalChainCompletions)

                    if canCorrectToQuestionDot or isRightOfQuestionDot then
                        t = typeChecker:GetNonNullableType(t)
                        if canCorrectToQuestionDot then
                            insertQuestionDot = true
                        end
                    end
                end
                addTypeProperties(t, node.flags & NodeFlags.AwaitContext ~= 0, insertQuestionDot)
            else
                addTypeProperties(typeChecker:GetNonNullableType(t), false --[[insertAwait]], false --[[insertQuestionDot]])
            end
        end
    end

    -- Aggregates relevant symbols for completion in object literals in type argument positions.
    local function tryGetObjectTypeLiteralInTypeArgumentCompletionSymbols()
        local typeLiteralNode = ls.tryGetTypeLiteralNode(contextToken)
        if typeLiteralNode == nil then
            return globalsSearch.Continue, nil
        end

        local intersectionTypeNode = nil
        if ast.IsIntersectionTypeNode(typeLiteralNode.parent) then
            intersectionTypeNode = typeLiteralNode.parent
        end
        local containerTypeNode
        if intersectionTypeNode ~= nil then
            containerTypeNode = intersectionTypeNode
        else
            containerTypeNode = typeLiteralNode
        end

        local containerExpectedType = ls.getConstraintOfTypeArgumentProperty(containerTypeNode, typeChecker)
        if containerExpectedType == nil then
            return globalsSearch.Continue, nil
        end

        local containerActualType = typeChecker:GetTypeFromTypeNode(containerTypeNode)

        local members = ls.getPropertiesForCompletion(containerExpectedType, typeChecker)
        local existingMembers = ls.getPropertiesForCompletion(containerActualType, typeChecker)

        local existingMemberNames = collections.NewSet()
        for _, member in ipairs(existingMembers or {}) do
            existingMemberNames:Add(member.name)
        end

        appendAll(symbols, core.Filter(members, function(member) return not existingMemberNames:Has(member.name) end))

        completionKind = CompletionKind.ObjectPropertyDeclaration
        isNewIdentifierLocation = true

        return globalsSearch.Success, nil
    end

    -- Aggregates relevant symbols for completion in object literals and object binding patterns.
    -- Relevant symbols are stored in the captured 'symbols' variable.
    local function tryGetObjectLikeCompletionSymbols()
        if contextToken ~= nil and contextToken.kind == Kind.DotDotDotToken then
            return globalsSearch.Continue, nil
        end
        local objectLikeContainer = ls.tryGetObjectLikeCompletionContainer(contextToken, position, file)
        if objectLikeContainer == nil then
            return globalsSearch.Continue, nil
        end

        -- We're looking up possible property names from contextual/inferred/declared type.
        completionKind = CompletionKind.ObjectPropertyDeclaration

        local typeMembers = nil
        local existingMembers = nil

        if objectLikeContainer.kind == Kind.ObjectLiteralExpression then
            local instantiatedType = ls.tryGetObjectLiteralContextualType(objectLikeContainer, typeChecker)

            -- Check completions for Object property value shorthand
            if instantiatedType == nil then
                if objectLikeContainer.flags & NodeFlags.InWithStatement ~= 0 then
                    return globalsSearch.Fail, nil
                end
                return globalsSearch.Continue, nil
            end
            local completionsType = typeChecker:GetContextualType(objectLikeContainer, checker.ContextFlags.IgnoreNodeInferences)
            local t
            if completionsType ~= nil then
                t = completionsType
            else
                t = instantiatedType
            end
            local stringIndexType = typeChecker:GetStringIndexType(t)
            local numberIndexType = typeChecker:GetNumberIndexType(t)
            isNewIdentifierLocation = stringIndexType ~= nil or numberIndexType ~= nil
            typeMembers = ls.getPropertiesForObjectExpression(instantiatedType, completionsType, objectLikeContainer, typeChecker)
            existingMembers = objectLikeContainer:Properties()

            if core.Len(typeMembers) == 0 then
                -- Edge case: If NumberIndexType exists
                if numberIndexType == nil then
                    return globalsSearch.Continue, nil
                end
            end
        else
            if objectLikeContainer.kind ~= Kind.ObjectBindingPattern then
                error("Expected 'objectLikeContainer' to be an object binding pattern.", 0)
            end
            -- We are *only* completing on properties from the type being destructured.
            isNewIdentifierLocation = false
            local rootDeclaration = ast.GetRootDeclaration(objectLikeContainer.parent)
            if not ast.IsVariableLike(rootDeclaration) then
                error("Root declaration is not variable-like.", 0)
            end

            -- We don't want to complete using the type acquired by the shape
            -- of the binding pattern; we are only interested in types acquired
            -- through type declaration or inference.
            -- Also proceed if rootDeclaration is a parameter and if its containing function expression/arrow function is contextually typed -
            -- type of parameter will flow in from the contextual type of the function.
            local canGetType = ast.HasInitializer(rootDeclaration) or
                ast.GetTypeAnnotationNode(rootDeclaration) ~= nil or
                rootDeclaration.parent.parent.kind == Kind.ForOfStatement
            if not canGetType and rootDeclaration.kind == Kind.Parameter then
                if ast.IsExpression(rootDeclaration.parent) then
                    canGetType = typeChecker:GetContextualType(rootDeclaration.parent, checker.ContextFlags.None) ~= nil
                elseif rootDeclaration.parent.kind == Kind.MethodDeclaration or
                    rootDeclaration.parent.kind == Kind.SetAccessor then
                    canGetType = ast.IsExpression(rootDeclaration.parent.parent) and
                        typeChecker:GetContextualType(rootDeclaration.parent.parent, checker.ContextFlags.None) ~= nil
                end
            end
            if canGetType then
                local typeForObject = typeChecker:GetTypeAtLocation(objectLikeContainer)
                if typeForObject == nil then
                    return globalsSearch.Fail, nil
                end
                typeMembers = core.Filter(
                    typeChecker:GetPropertiesOfType(typeForObject),
                    function(propertySymbol)
                        return typeChecker:IsPropertyAccessible(
                            objectLikeContainer,
                            false, --[[isSuper]]
                            false, --[[isWrite]]
                            typeForObject,
                            propertySymbol
                        )
                    end
                )
                existingMembers = objectLikeContainer:Elements()
            end
        end

        if core.Len(typeMembers) > 0 then
            -- Add filtered items to the completion list.
            local filteredMembers, spreadMemberNames = ls.filterObjectMembersList(
                typeMembers,
                core.CheckEachDefined(existingMembers, "object like properties or elements should all be defined"),
                file,
                position,
                typeChecker
            )
            appendAll(symbols, filteredMembers)

            -- Set sort texts.
            for _, member in ipairs(filteredMembers or {}) do
                local symbolId = ast.GetSymbolId(member)
                if spreadMemberNames:Has(member.name) then
                    symbolToSortTextMap[symbolId] = SortText.MemberDeclaredBySpreadAssignment
                end
                if member.flags & SymbolFlags.Optional ~= 0 then
                    if symbolToSortTextMap[symbolId] == nil then
                        symbolToSortTextMap[symbolId] = SortText.OptionalMember
                    end
                end
                if objectLikeContainer.kind == Kind.ObjectLiteralExpression and core.Tristate_IsTrue(preferences.includeCompletionsWithObjectLiteralMethodSnippets) then
                    local displayName = ls.getCompletionEntryDisplayNameForSymbol(member, nil --[[origin]], CompletionKind.ObjectPropertyDeclaration, false --[[isJsxIdentifierExpected]])
                    if displayName ~= "" then
                        local originalSortText = core.OrElse(symbolToSortTextMap[symbolId], SortText.LocationPriority)
                        symbolToSortTextMap[symbolId] = ls.ObjectLiteralPropertySortText(originalSortText, displayName)
                    end
                end
            end

            if objectLikeContainer.kind == Kind.ObjectLiteralExpression and core.Tristate_IsTrue(preferences.includeCompletionsWithObjectLiteralMethodSnippets) then
                for _, entry in ipairs(l:collectObjectLiteralMethodSymbols(ctx, typeChecker, filteredMembers, objectLikeContainer, file) or {}) do
                    symbolToOriginInfoMap[#symbols] = entry.origin
                    symbols[#symbols + 1] = entry.symbol
                end
            end
        end

        return globalsSearch.Success, nil
    end

    local function shouldOfferImportCompletions()
        if tspath.IsDynamicFileName(file:FileName()) then
            return false
        end
        -- If already typing an import statement, provide completions for it.
        if importStatementCompletion ~= nil then
            return true
        end
        -- If not already a module, must have modules enabled.
        if core.Tristate_IsFalse(preferences.includeCompletionsForModuleExports) then
            return false
        end
        -- Always using ES modules in 6.0+
        return true
    end

    -- Mutates `symbols`, `symbolToOriginInfoMap`, and `symbolToSortTextMap`
    local function collectAutoImports()
        -- `completionItem/resolve` for auto-import completions should be resolved via the completion item data,
        -- so we don't need to collect auto-import entries again.
        if forItemResolve then
            return nil
        end
        if not shouldOfferImportCompletions() then
            return nil
        end

        -- import { type | -> token text should be blank
        local lowerCaseTokenText = ""
        local usagePosition, fidelity = l:createLspPosition(position, file)
        if not spanmap.Fidelity_IsExact(fidelity) then
            return nil
        end
        if previousToken ~= nil and ast.IsIdentifier(previousToken) then
            usagePosition, fidelity = l:createLspPosition(scanner.GetTokenPosOfNode(previousToken, file, false --[[includeJSDoc]]), file)
            if not spanmap.Fidelity_IsExact(fidelity) then
                return nil
            end
            if not (previousToken == contextToken and importStatementCompletion ~= nil) then
                lowerCaseTokenText = stringutil.StringsToLower(previousToken:Text())
            end
        end

        local view, err = l:getPreparedAutoImportView(file)
        if err ~= nil then
            return err
        end
        if view == nil then
            return nil
        end

        autoImports = view:GetCompletions(ctx, lowerCaseTokenText, usagePosition, isRightOfOpenTag, isTypeOnlyLocation)
        return nil
    end

    local function tryGetImportCompletionSymbols()
        if importStatementCompletion == nil then
            return globalsSearch.Continue, nil
        end
        isNewIdentifierLocation = true
        local err = collectAutoImports()
        if err ~= nil then
            return globalsSearch.Fail, err
        end
        return globalsSearch.Success, nil
    end

    -- Aggregates relevant symbols for completion in import clauses and export clauses
    -- whose declarations have a module specifier; for instance, symbols will be aggregated for
    --
    --      import { | } from "moduleName";
    --      export { a as foo, | } from "moduleName";
    --
    -- but not for
    --
    --      export { | };
    --
    -- Relevant symbols are stored in the captured 'symbols' variable.
    local function tryGetImportOrExportClauseCompletionSymbols()
        if contextToken == nil then
            return globalsSearch.Continue, nil
        end

        -- `import { |` or `import { a as 0, | }` or `import { type | }`
        local namedImportsOrExports = nil
        if contextToken.kind == Kind.OpenBraceToken or contextToken.kind == Kind.CommaToken then
            if ls.isNamedImportsOrExports(contextToken.parent) then
                namedImportsOrExports = contextToken.parent
            end
        elseif ls.isTypeKeywordTokenOrIdentifier(contextToken) then
            if ls.isNamedImportsOrExports(contextToken.parent.parent) then
                namedImportsOrExports = contextToken.parent.parent
            end
        end

        if namedImportsOrExports == nil then
            return globalsSearch.Continue, nil
        end

        -- We can at least offer `type` at `import { |`
        if not ls.isTypeKeywordTokenOrIdentifier(contextToken) then
            keywordFilters = KeywordCompletionFilters.TypeKeyword
        end

        -- try to show exported member for imported/re-exported module
        local moduleSpecifierOwner
        if namedImportsOrExports.kind == Kind.NamedImports then
            moduleSpecifierOwner = namedImportsOrExports.parent.parent
        else
            moduleSpecifierOwner = namedImportsOrExports.parent
        end
        local moduleSpecifier = moduleSpecifierOwner:ModuleSpecifier()
        if moduleSpecifier == nil then
            isNewIdentifierLocation = true
            if namedImportsOrExports.kind == Kind.NamedImports then
                return globalsSearch.Fail, nil
            end
            return globalsSearch.Continue, nil
        end

        local moduleSpecifierSymbol = typeChecker:GetSymbolAtLocation(moduleSpecifier)
        if moduleSpecifierSymbol == nil then
            isNewIdentifierLocation = true
            return globalsSearch.Fail, nil
        end

        completionKind = CompletionKind.MemberLike
        isNewIdentifierLocation = false
        local exports = typeChecker:GetExportsAndPropertiesOfModule(moduleSpecifierSymbol)

        local existing = collections.NewSet()
        for _, element in ipairs(namedImportsOrExports:Elements() or {}) do
            if not ls.isCurrentlyEditingNode(element, file, position) then
                existing:Add(element:PropertyNameOrName():Text())
            end
        end
        local uniques = core.Filter(exports, function(symbol)
            return ast.SymbolName(symbol) ~= ast.InternalSymbolNameDefault and not existing:Has(ast.SymbolName(symbol))
        end)

        appendAll(symbols, uniques)
        if core.Len(uniques) == 0 then
            -- If there's nothing else to import, don't offer `type` either.
            keywordFilters = KeywordCompletionFilters.None
        end
        return globalsSearch.Success, nil
    end

    -- import { x } from "foo" with { | }
    local function tryGetImportAttributesCompletionSymbols()
        if contextToken == nil then
            return globalsSearch.Continue, nil
        end

        local importAttributes = nil
        if contextToken.kind == Kind.OpenBraceToken or contextToken.kind == Kind.CommaToken then
            importAttributes = contextToken.parent
        elseif contextToken.kind == Kind.ColonToken then
            importAttributes = contextToken.parent.parent
        end
        if importAttributes == nil or not ast.IsImportAttributes(importAttributes) then
            return globalsSearch.Continue, nil
        end

        local elements = nil
        if importAttributes:AsImportAttributes().attributes ~= nil then
            elements = importAttributes:AsImportAttributes().attributes.nodes
        end
        local attributeNames = core.Map(elements, function(el)
            return el:AsImportAttribute():Name():Text()
        end)
        local existing = collections.NewSetFromItems(table.unpack(attributeNames or {}))
        local uniques = core.Filter(
            typeChecker:GetApparentProperties(typeChecker:GetTypeAtLocation(importAttributes)),
            function(symbol)
                return not existing:Has(ast.SymbolName(symbol))
            end
        )
        appendAll(symbols, uniques)
        return globalsSearch.Success, nil
    end

    -- Adds local declarations for completions in named exports:
    --   export { | };
    -- Does not check for the absence of a module specifier (`export {} from "./other"`)
    -- because `tryGetImportOrExportClauseCompletionSymbols` runs first and handles that,
    -- preventing this function from running.
    local function tryGetLocalNamedExportCompletionSymbols()
        if contextToken == nil then
            return globalsSearch.Continue, nil
        end
        local namedExports = nil
        if contextToken.kind == Kind.OpenBraceToken or contextToken.kind == Kind.CommaToken then
            if ast.IsNamedExports(contextToken.parent) then
                namedExports = contextToken.parent
            end
        end

        if namedExports == nil then
            return globalsSearch.Continue, nil
        end

        local localsContainer = ast.FindAncestor(namedExports, function(n)
            return ast.IsSourceFile(n) or ast.IsModuleDeclaration(n)
        end)
        completionKind = CompletionKind.None
        isNewIdentifierLocation = false
        local localSymbol = localsContainer:Symbol()
        local localExports = nil
        if localSymbol ~= nil then
            localExports = localSymbol.exports
        end
        -- Go iterates the locals map in random order; iterate by name for determinism.
        local locals = localsContainer:Locals() or {}
        local names = {}
        for name in pairs(locals) do
            names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local symbol = locals[name]
            symbols[#symbols + 1] = symbol
            if localExports ~= nil and localExports[name] ~= nil then
                local symbolId = ast.GetSymbolId(symbol)
                symbolToSortTextMap[symbolId] = SortText.OptionalMember
            end
        end

        return globalsSearch.Success, nil
    end

    local function tryGetConstructorCompletion()
        if ls.tryGetConstructorLikeCompletionContainer(contextToken) == nil then
            return globalsSearch.Continue, nil
        end

        -- no members, only keywords
        completionKind = CompletionKind.None
        -- Declaring new property/method/accessor
        isNewIdentifierLocation = true
        -- Has keywords for constructor parameter
        keywordFilters = KeywordCompletionFilters.ConstructorParameterKeywords
        return globalsSearch.Success, nil
    end

    -- Aggregates relevant symbols for completion in class declaration
    -- Relevant symbols are stored in the captured 'symbols' variable.
    local function tryGetClassLikeCompletionSymbols()
        local decl = ls.tryGetObjectTypeDeclarationCompletionContainer(file, contextToken, location, position)
        if decl == nil then
            return globalsSearch.Continue, nil
        end

        -- We're looking up possible property names from parent type.
        completionKind = CompletionKind.MemberLike
        -- Declaring new property/method/accessor
        isNewIdentifierLocation = true
        if contextToken.kind == Kind.AsteriskToken then
            keywordFilters = KeywordCompletionFilters.None
        elseif ast.IsClassLike(decl) then
            keywordFilters = KeywordCompletionFilters.ClassElementKeywords
        else
            keywordFilters = KeywordCompletionFilters.InterfaceElementKeywords
        end

        -- If you're in an interface you don't want to repeat things from super-interface. So just stop here.
        if not ast.IsClassLike(decl) then
            return globalsSearch.Success, nil
        end

        local classElement
        if contextToken.kind == Kind.SemicolonToken then
            classElement = contextToken.parent.parent
        else
            classElement = contextToken.parent
        end
        local classElementModifierFlags = ModifierFlags.None
        if ast.IsClassElement(classElement) then
            classElementModifierFlags = classElement:ModifierFlags()
        end
        -- If this is context token is not something we are editing now, consider if this would lead to be modifier.
        if contextToken.kind == Kind.Identifier and not ls.isCurrentlyEditingNode(contextToken, file, position) then
            local text = contextToken:Text()
            if text == "private" then
                classElementModifierFlags = classElementModifierFlags | ModifierFlags.Private
            elseif text == "static" then
                classElementModifierFlags = classElementModifierFlags | ModifierFlags.Static
            elseif text == "override" then
                classElementModifierFlags = classElementModifierFlags | ModifierFlags.Override
            end
        end
        if ast.IsClassStaticBlockDeclaration(classElement) then
            classElementModifierFlags = classElementModifierFlags | ModifierFlags.Static
        end

        -- No member list for private methods
        if classElementModifierFlags & ModifierFlags.Private == 0 then
            -- List of property symbols of base type that are not private and already implemented
            local baseTypeNodes
            if ast.IsClassLike(decl) and classElementModifierFlags & ModifierFlags.Override ~= 0 then
                baseTypeNodes = core.SingleElementSlice(ast.GetClassExtendsHeritageElement(decl))
            else
                baseTypeNodes = ls.getAllSuperTypeNodes(decl)
            end
            local baseSymbols = {}
            for _, baseTypeNode in ipairs(baseTypeNodes or {}) do
                local t = typeChecker:GetTypeAtLocation(baseTypeNode)
                if classElementModifierFlags & ModifierFlags.Static ~= 0 then
                    if t:Symbol() ~= nil then
                        appendAll(
                            baseSymbols,
                            typeChecker:GetPropertiesOfType(typeChecker:GetTypeOfSymbolAtLocation(t:Symbol(), decl))
                        )
                    end
                elseif t ~= nil then
                    appendAll(baseSymbols, typeChecker:GetPropertiesOfType(t))
                end
            end

            appendAll(symbols,
                ls.filterClassMembersList(baseSymbols, decl:Members(), classElementModifierFlags, file, position))
            for i, symbol in ipairs(symbols) do
                local index = i - 1
                local declaration = symbol.valueDeclaration
                if declaration ~= nil and ast.IsClassElement(declaration) and
                    declaration:Name() ~= nil and
                    ast.IsComputedPropertyName(declaration:Name()) then
                    local origin = ls.newSymbolOriginInfo({
                        kind = symbolOriginInfoKind.ComputedPropertyName,
                        data = setmetatable({ symbolName = typeChecker:SymbolToString(symbol) }, ls.symbolOriginInfoComputedPropertyName),
                    })
                    symbolToOriginInfoMap[index] = origin
                end
            end
        end

        return globalsSearch.Success, nil
    end

    local function tryGetJsxCompletionSymbols()
        local jsxContainer = ls.tryGetContainingJsxElement(contextToken, file)
        if jsxContainer == nil then
            return globalsSearch.Continue, nil
        end
        -- Cursor is inside a JSX self-closing element or opening element.
        local attrsType = typeChecker:GetContextualType(jsxContainer:Attributes(), checker.ContextFlags.None)
        if attrsType == nil then
            return globalsSearch.Continue, nil
        end
        local completionsType = typeChecker:GetContextualType(jsxContainer:Attributes(), checker.ContextFlags.IgnoreNodeInferences)
        local filteredSymbols, spreadMemberNames = ls.filterJsxAttributes(
            ls.getPropertiesForObjectExpression(attrsType, completionsType, jsxContainer:Attributes(), typeChecker),
            jsxContainer:Attributes():Properties(),
            file,
            position,
            typeChecker
        )

        appendAll(symbols, filteredSymbols)
        -- Set sort texts.
        for _, symbol in ipairs(filteredSymbols or {}) do
            local symbolId = ast.GetSymbolId(symbol)
            if spreadMemberNames:Has(ast.SymbolName(symbol)) then
                symbolToSortTextMap[symbolId] = SortText.MemberDeclaredBySpreadAssignment
            end
            if symbol.flags & SymbolFlags.Optional ~= 0 then
                if symbolToSortTextMap[symbolId] == nil then
                    symbolToSortTextMap[symbolId] = SortText.OptionalMember
                end
            end
        end

        completionKind = CompletionKind.MemberLike
        isNewIdentifierLocation = false
        return globalsSearch.Success, nil
    end

    local function getGlobalCompletions()
        if ls.tryGetFunctionLikeBodyCompletionContainer(contextToken) ~= nil then
            keywordFilters = KeywordCompletionFilters.FunctionLikeBodyKeywords
        else
            keywordFilters = KeywordCompletionFilters.All
        end
        -- Get all entities in the current scope.
        completionKind = CompletionKind.Global
        isNewIdentifierLocation, defaultCommitCharacters = ls.computeCommitCharactersAndIsNewIdentifier(contextToken, file, position)

        if previousToken ~= contextToken then
            if previousToken == nil then
                error("Expected 'contextToken' to be defined when different from 'previousToken'.", 0)
            end
        end

        -- We need to find the node that will give us an appropriate scope to begin
        -- aggregating completion candidates. This is achieved in 'getScopeNode'
        -- by finding the first node that encompasses a position, accounting for whether a node
        -- is "complete" to decide whether a position belongs to the node.
        --
        -- However, at the end of an identifier, we are interested in the scope of the identifier
        -- itself, but fall outside of the identifier. For instance:
        --
        --      xyz => x$
        --
        -- the cursor is outside of both the 'x' and the arrow function 'xyz => x',
        -- so 'xyz' is not returned in our results.
        --
        -- We define 'adjustedPosition' so that we may appropriately account for
        -- being at the end of an identifier. The intention is that if requesting completion
        -- at the end of an identifier, it should be effectively equivalent to requesting completion
        -- anywhere inside/at the beginning of the identifier. So in the previous case, the
        -- 'adjustedPosition' will work as if requesting completion in the following:
        --
        --      xyz => $x
        --
        -- If previousToken !== contextToken, then
        --   - 'contextToken' was adjusted to the token prior to 'previousToken'
        --      because we were at the end of an identifier.
        --   - 'previousToken' is defined.
        local adjustedPosition
        if previousToken ~= contextToken then
            adjustedPosition = astnav.GetStartOfNode(previousToken, file, false --[[includeJSDoc]])
        else
            adjustedPosition = position
        end

        local scopeNode = ls.getScopeNode(contextToken, adjustedPosition, file)
        if scopeNode == nil then
            scopeNode = file:AsNode()
        end
        isInSnippetScope = ls.isSnippetScope(scopeNode)

        local symbolMeanings = (isTypeOnlyLocation and SymbolFlags.None or SymbolFlags.Value) |
            SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias
        local typeOnlyAliasNeedsPromotion = previousToken ~= nil and not ast.IsValidTypeOnlyAliasUseSite(previousToken)

        appendAll(symbols, typeChecker:GetSymbolsInScope(scopeNode, symbolMeanings))
        core.CheckEachDefined(symbols, "getSymbolsInScope() should all be defined")
        for i, symbol in ipairs(symbols) do
            local index = i - 1
            local symbolId = ast.GetSymbolId(symbol)
            if not typeChecker:IsArgumentsSymbol(symbol) and
                not core.Some(symbol.declarations, function(decl)
                    return ast.GetSourceFileOfNode(decl) == file
                end) then
                symbolToSortTextMap[symbolId] = SortText.GlobalsOrKeywords
            end
            if typeOnlyAliasNeedsPromotion and symbol.flags & SymbolFlags.Value == 0 then
                local typeOnlyAliasDeclaration = core.Find(symbol.declarations, ast.IsTypeOnlyImportDeclaration)
                if typeOnlyAliasDeclaration ~= nil then
                    local origin = ls.newSymbolOriginInfo({
                        kind = symbolOriginInfoKind.TypeOnlyAlias,
                        data = setmetatable({ declaration = typeOnlyAliasDeclaration }, ls.symbolOriginInfoTypeOnlyAlias),
                    })
                    symbolToOriginInfoMap[index] = origin
                end
            end
        end

        -- Need to insert 'this.' before properties of `this` type.
        if scopeNode.kind ~= Kind.SourceFile then
            local thisType = typeChecker:TryGetThisTypeAtEx(
                scopeNode,
                false, --[[includeGlobalThis]]
                ast.IsClassLike(scopeNode.parent) and scopeNode or nil
            )
            if thisType ~= nil and not ls.isProbablyGlobalType(thisType, file, typeChecker) then
                for _, symbol in ipairs(ls.getPropertiesForCompletion(thisType, typeChecker) or {}) do
                    local symbolId = ast.GetSymbolId(symbol)
                    symbols[#symbols + 1] = symbol
                    symbolToOriginInfoMap[#symbols - 1] = ls.newSymbolOriginInfo({ kind = symbolOriginInfoKind.ThisType })
                    symbolToSortTextMap[symbolId] = SortText.SuggestedClassMembers
                end
            end
        end

        local err = collectAutoImports()
        if err ~= nil then
            return globalsSearch.Fail, err
        end
        if isTypeOnlyLocation then
            if contextToken ~= nil and ast.IsAssertionExpression(contextToken.parent) then
                keywordFilters = KeywordCompletionFilters.TypeAssertionKeywords
            else
                keywordFilters = KeywordCompletionFilters.TypeKeywords
            end
        end

        return globalsSearch.Success, nil
    end

    local function tryGetGlobalSymbols()
        local result = globalsSearch.Continue
        local err
        local globalSearchFuncs = {
            tryGetObjectTypeLiteralInTypeArgumentCompletionSymbols,
            tryGetObjectLikeCompletionSymbols,
            tryGetImportCompletionSymbols,
            tryGetImportOrExportClauseCompletionSymbols,
            tryGetImportAttributesCompletionSymbols,
            tryGetLocalNamedExportCompletionSymbols,
            tryGetConstructorCompletion,
            tryGetClassLikeCompletionSymbols,
            tryGetJsxCompletionSymbols,
            getGlobalCompletions,
        }
        for _, globalSearchFunc in ipairs(globalSearchFuncs) do
            result, err = globalSearchFunc()
            if err ~= nil then
                return false, err
            end
            if result ~= globalsSearch.Continue then
                break
            end
        end
        return result == globalsSearch.Success, nil
    end

    if isRightOfDot or isRightOfQuestionDot then
        getTypeScriptMemberSymbols()
    elseif isRightOfOpenTag then
        symbols = typeChecker:GetJsxIntrinsicTagNamesAt(location) or {}
        core.CheckEachDefined(symbols, "GetJsxIntrinsicTagNamesAt() should all be defined")
        local _, err = tryGetGlobalSymbols()
        if err ~= nil then
            return nil, err
        end
        completionKind = CompletionKind.Global
        keywordFilters = KeywordCompletionFilters.None
    elseif isStartingCloseTag then
        local tagName = contextToken.parent.parent:AsJsxElement().openingElement:TagName()
        local tagSymbol = typeChecker:GetSymbolAtLocation(tagName)
        if tagSymbol ~= nil then
            symbols = { tagSymbol }
        end
        completionKind = CompletionKind.Global
        keywordFilters = KeywordCompletionFilters.None
    else
        -- For JavaScript or TypeScript, if we're not after a dot, then just try to get the
        -- global symbols in scope.  These results should be valid for either language as
        -- the set of symbols that can be referenced from this location.
        local ok, err = tryGetGlobalSymbols()
        if not ok then
            if err ~= nil then
                return nil, err
            end
            if keywordFilters ~= KeywordCompletionFilters.None then
                return ls.keywordCompletionData(keywordFilters, isJSOnlyLocation, isNewIdentifierLocation), nil
            end
            return nil, nil
        end
    end

    local contextualTypeOrConstraint = nil
    if previousToken ~= nil then
        contextualTypeOrConstraint = ls.getContextualType(previousToken, position, file, typeChecker)
        if contextualTypeOrConstraint == nil then
            contextualTypeOrConstraint = ls.getConstraintOfTypeArgumentProperty(previousToken, typeChecker)
        end
    end

    -- exclude literal suggestions after <input type="text" [||] /> microsoft/TypeScript#51667) and after closing quote (microsoft/TypeScript#52675)
    -- for strings getStringLiteralCompletions handles completions
    local isLiteralExpected = not (previousToken ~= nil and ast.IsStringLiteralLike(previousToken)) and not isJsxIdentifierExpected
    local literals = nil
    if isLiteralExpected then
        local types = nil
        if contextualTypeOrConstraint ~= nil and contextualTypeOrConstraint:IsUnion() then
            types = contextualTypeOrConstraint:Types()
        elseif contextualTypeOrConstraint ~= nil then
            types = { contextualTypeOrConstraint }
        end
        -- Go core.MapNonNil over `any`: only nil interface values are dropped ("" and 0 are kept).
        for _, t in ipairs(types or {}) do
            if ls.isLiteral(t) and not t:IsEnumLiteral() then
                local value = t:AsLiteralType():Value()
                if value ~= nil then
                    literals = literals or {}
                    literals[#literals + 1] = value
                end
            end
        end
    end

    local recommendedCompletion = nil
    if previousToken ~= nil and contextualTypeOrConstraint ~= nil then
        recommendedCompletion = ls.getRecommendedCompletion(previousToken, contextualTypeOrConstraint, typeChecker)
    end

    if defaultCommitCharacters == nil then
        defaultCommitCharacters = ls.getDefaultCommitCharacters(isNewIdentifierLocation)
    end

    return setmetatable({
        symbols = symbols,
        autoImports = autoImports,
        completionKind = completionKind,
        isInSnippetScope = isInSnippetScope,
        propertyAccessToConvert = propertyAccessToConvert,
        isNewIdentifierLocation = isNewIdentifierLocation,
        location = location,
        keywordFilters = keywordFilters,
        literals = literals,
        symbolToOriginInfoMap = symbolToOriginInfoMap,
        symbolToSortTextMap = symbolToSortTextMap,
        recommendedCompletion = recommendedCompletion,
        previousToken = previousToken,
        contextToken = contextToken,
        jsxInitializer = jsxInitializer,
        insideJSDocTagTypeExpression = insideJSDocTagTypeExpression,
        isTypeOnlyLocation = isTypeOnlyLocation,
        isJsxIdentifierExpected = isJsxIdentifierExpected,
        isRightOfOpenTag = isRightOfOpenTag,
        isRightOfDotOrQuestionDot = isRightOfDot or isRightOfQuestionDot,
        importStatementCompletion = importStatementCompletion,
        hasUnresolvedAutoImports = hasUnresolvedAutoImports,
        defaultCommitCharacters = defaultCommitCharacters,
    }, ls.completionDataData), nil
end

function ls.keywordCompletionData(keywordFilters, filterOutTSOnlyKeywords, isNewIdentifierLocation)
    return setmetatable({
        keywordCompletions = ls.getKeywordCompletions(keywordFilters, filterOutTSOnlyKeywords),
        isNewIdentifierLocation = isNewIdentifierLocation,
    }, ls.completionDataKeyword)
end

function ls.getDefaultCommitCharacters(isNewIdentifierLocation)
    if isNewIdentifierLocation then
        return {}
    end
    return core.Slice(ls.allCommitCharacters, 0, #ls.allCommitCharacters)
end

function LanguageService:completionInfoFromData(
    ctx,
    typeChecker,
    file,
    compilerOptions,
    data,
    position,
    optionalReplacementSpan,
    includeSymbols
)
    local keywordFilters = data.keywordFilters
    local isNewIdentifierLocation = data.isNewIdentifierLocation
    local contextToken = data.contextToken
    local literals = data.literals
    local preferences = self:UserPreferences()

    -- Verify if the file is JSX language variant
    if file.languageVariant == core.LanguageVariant.JSX then
        local list = self:getJsxClosingTagCompletion(ctx, data.location, file, position)
        if list ~= nil then
            return list, nil
        end
    end

    -- When the completion is for the expression of a case clause (e.g. `case |`),
    -- filter literals & enum symbols whose values are already present in existing case clauses.
    local caseClause = ast.FindAncestor(contextToken, ast.IsCaseClause)
    if caseClause ~= nil and
        (contextToken.kind == Kind.CaseKeyword or
            ast.IsNodeDescendantOf(contextToken, caseClause:Expression())) then
        local tracker = ls.newCaseClauseTracker(typeChecker, caseClause.parent:AsCaseBlock().clauses.nodes)
        literals = core.Filter(literals, function(literal)
            return not tracker:hasValue(literal)
        end)
        data.symbols = core.Filter(data.symbols, function(symbol)
            if symbol.valueDeclaration ~= nil and ast.IsEnumMember(symbol.valueDeclaration) then
                local value = typeChecker:GetConstantValue(symbol.valueDeclaration)
                if value ~= nil and tracker:hasValue(value) then
                    return false
                end
            end
            return true
        end)
    end

    local isChecked = ls.isCheckedFile(file, compilerOptions)
    if isChecked and not isNewIdentifierLocation and core.Len(data.symbols) == 0 and keywordFilters == KeywordCompletionFilters.None then
        return nil, nil
    end

    local uniqueNames, sortedEntries, err = self:getCompletionEntriesFromSymbols(
        ctx,
        typeChecker,
        data,
        nil, --[[replacementToken]]
        position,
        file,
        compilerOptions,
        includeSymbols
    )
    if err ~= nil then
        return nil, err
    end
    sortedEntries = sortedEntries or {}

    if data.keywordFilters ~= KeywordCompletionFilters.None then
        local keywordCompletions = ls.getKeywordCompletions(data.keywordFilters, not data.insideJSDocTagTypeExpression and ast.IsSourceFileJS(file))
        for _, keywordEntry in ipairs(keywordCompletions or {}) do
            if data.isTypeOnlyLocation and ls.isTypeKeyword(scanner.StringToToken(keywordEntry.label)) or
                not data.isTypeOnlyLocation and ls.isContextualKeywordInAutoImportableExpressionSpace(keywordEntry.label) or
                not uniqueNames:Has(keywordEntry.label) then
                uniqueNames:Add(keywordEntry.label)
                sortedEntries[#sortedEntries + 1] = keywordEntry
            end
        end
    end

    for _, keywordEntry in ipairs(ls.getContextualKeywords(file, contextToken, position) or {}) do
        if not uniqueNames:Has(keywordEntry.label) then
            uniqueNames:Add(keywordEntry.label)
            sortedEntries[#sortedEntries + 1] = ls.NewCompletionItem(keywordEntry, nil)
        end
    end

    for _, literal in ipairs(literals or {}) do
        local literalEntry = ls.createCompletionItemForLiteral(file, preferences, literal)
        uniqueNames:Add(literalEntry.label)
        sortedEntries[#sortedEntries + 1] = ls.NewCompletionItem(literalEntry, nil)
    end

    if not isChecked then
        sortedEntries = self:getJSCompletionEntries(
            ctx,
            file,
            position,
            uniqueNames,
            sortedEntries
        )
    end

    if contextToken ~= nil and not data.isRightOfOpenTag and not data.isRightOfDotOrQuestionDot then
        local caseBlock = ast.FindAncestorKind(contextToken, Kind.CaseBlock)
        if caseBlock ~= nil then
            local casesItem, err2 = self:getExhaustiveCaseSnippets(
                ctx,
                caseBlock:AsCaseBlock(),
                file,
                position,
                compilerOptions,
                self.program,
                typeChecker
            )
            if err2 ~= nil then
                return nil, err2
            end
            if casesItem ~= nil then
                sortedEntries[#sortedEntries + 1] = ls.NewCompletionItem(casesItem, nil)
            end
        end
    end

    local itemDefaults = self:setItemDefaults(
        ctx,
        position,
        file,
        sortedEntries,
        data.defaultCommitCharacters,
        optionalReplacementSpan
    )

    return setmetatable({
        isIncomplete = data.hasUnresolvedAutoImports,
        itemDefaults = itemDefaults,
        items = sortedEntries,
    }, CompletionList), nil
end
