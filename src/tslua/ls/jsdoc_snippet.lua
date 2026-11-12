local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local format = require("tslua.format")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local parser = require("tslua.parser")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function hasPrefix(s, p)
    return #s >= #p and string.sub(s, 1, #p) == p
end

local function hasSuffix(s, p)
    return #s >= #p and (p == "" or string.sub(s, -#p) == p)
end

-- strings.TrimLeft(s, " \t")
local function trimLeftSpacesTabs(s)
    return (string.gsub(s, "^[ \t]+", ""))
end

-- strings.Split(s, sep) with a non-empty plain separator.
local function split(s, sep)
    local result = {}
    local start = 1
    while true do
        local i, j = string.find(s, sep, start, true)
        if i == nil then
            result[#result + 1] = string.sub(s, start)
            return result
        end
        result[#result + 1] = string.sub(s, start, i - 1)
        start = j + 1
    end
end

-- docCommentTemplate: { newText }
-- commentOwnerInfo: { commentOwner, parameters, hasReturn }

function LanguageService:getJSDocSnippetCompletion(ctx, file, position)
    if core.Tristate_IsFalse(self:UserPreferences().enableJSDocCompletions) then
        return nil
    end
    if not ls.isPotentiallyValidJSDocSnippetCompletionPosition(file, position) then
        return nil
    end
    local newLine = self:FormatOptions().newLineCharacter
    if newLine == "" then
        newLine = "\n"
    end
    local template = ls.getDocCommentTemplateAtPosition(file, position, core.Tristate_IsTrue(self:UserPreferences().generateReturnInDocTemplate), newLine)
    if template == nil then
        return nil
    end

    local insertText = template.newText
    local insertTextFormat
    if ls.clientSupportsItemSnippet(ctx) then
        insertText = ls.templateToSnippet(insertText, newLine)
        insertTextFormat = lsproto.InsertTextFormat.Snippet
    end

    local editRange = self:getJSDocSnippetCompletionRange(ctx, file, position, insertText)
    local commitCharacters
    if ls.clientSupportsItemCommitCharacters(ctx) then
        commitCharacters = {}
    end
    local item = ls.NewCompletionItem({
        label = "/** */",
        kind = lsproto.CompletionItemKind.Text,
        detail = diagnostics.JSDoc_comment:Localize(locale.FromContext(ctx)),
        sortText = "\0",
        insertTextFormat = insertTextFormat,
        textEdit = editRange,
        commitCharacters = commitCharacters,
    }, nil)
    return setmetatable({
        isIncomplete = false,
        items = { item },
    }, ls.CompletionList)
end

function ls.isPotentiallyValidJSDocSnippetCompletionPosition(file, position)
    local text = file:Text()
    local lineStart = format.GetLineStartPositionForPosition(position, file)
    local prefix = string.sub(text, lineStart + 1, position)
    if not ls.isJSDocSnippetPrefix(prefix) then
        return false
    end

    local lineEnd = ls.getLineEndOfPosition(file, position)
    local suffix = string.sub(text, position + 1, lineEnd)
    return ls.isJSDocSnippetSuffix(suffix)
end

function LanguageService:getJSDocSnippetCompletionRange(ctx, file, position, newText)
    local text = file:Text()
    local lineStart = format.GetLineStartPositionForPosition(position, file)
    local prefix = string.sub(text, lineStart + 1, position)
    local start = position
    local prefixStart, ok = ls.getJSDocSnippetPrefixStart(prefix)
    if ok then
        start = lineStart + prefixStart
    end

    local lineEnd = ls.getLineEndOfPosition(file, position)
    local suffix = string.sub(text, position + 1, lineEnd)
    local end_ = position
    local suffixEnd, ok2 = ls.getJSDocSnippetSuffixEnd(suffix)
    if ok2 then
        end_ = end_ + suffixEnd
    end

    local replacementRange, fidelity = self:createLspRangeFromBounds(start, end_, file)
    if not spanmap.Fidelity_IsExact(fidelity) then
        return nil
    end
    if ls.clientSupportsItemInsertReplace(ctx) then
        return {
            insertReplaceEdit = {
                newText = newText,
                insert = replacementRange,
                replace = replacementRange,
            },
        }
    end
    return {
        textEdit = {
            newText = newText,
            range = replacementRange,
        },
    }
end

function ls.getDocCommentTemplateAtPosition(sourceFile, position, generateReturnInDocTemplate, newLine)
    local tokenAtPos = astnav.GetTokenAtPosition(sourceFile, position)
    if tokenAtPos == nil then
        return nil
    end

    local existingDocComment = ast.FindAncestor(tokenAtPos, ast.IsJSDoc)
    local docCommentEnd, hasDocCommentAtPosition, hasClosingDocCommentAtPosition = ls.getDocCommentEndAtPosition(sourceFile, position)
    local isInEmptyDocComment = existingDocComment ~= nil or hasDocCommentAtPosition
    if ls.isNonEmptyJSDoc(existingDocComment) and hasDocCommentAtPosition and not hasClosingDocCommentAtPosition then
        local text = sourceFile:Text()
        local reparseText = string.sub(text, 1, position) .. " */" .. string.sub(text, position + 1)
        local reparse = parser.ParseSourceFile(sourceFile:ParseOptions(), reparseText, sourceFile.scriptKind)
        return ls.getDocCommentTemplateAtPosition(reparse, position, generateReturnInDocTemplate, newLine)
    end
    if ls.isNonEmptyJSDoc(existingDocComment) then
        return nil
    end
    if existingDocComment == nil and hasDocCommentAtPosition then
        tokenAtPos = astnav.GetTokenAtPosition(sourceFile, ls.skipWhitespace(sourceFile:Text(), docCommentEnd))
        if tokenAtPos == nil then
            return nil
        end
    end
    local tokenStart = astnav.GetStartOfNode(tokenAtPos, sourceFile, false --[[includeJSDoc]])
    if not isInEmptyDocComment and tokenStart < position then
        return nil
    end

    local commentOwnerInfo = ls.getCommentOwnerInfo(tokenAtPos, generateReturnInDocTemplate)
    if commentOwnerInfo == nil then
        return nil
    end

    local commentOwner = commentOwnerInfo.commentOwner
    local lastJSDoc = core.LastOrNil(commentOwner:JSDoc(sourceFile))
    local commentOwnerStart = astnav.GetStartOfNode(commentOwner, sourceFile, false --[[includeJSDoc]])
    if commentOwnerStart < position or
        lastJSDoc ~= nil and existingDocComment ~= nil and lastJSDoc ~= existingDocComment then
        return nil
    end

    local indentation = ls.getIndentationStringAtPosition(sourceFile, position)
    local tags = ls.parameterDocComments(commentOwnerInfo.parameters, ast.IsSourceFileJS(sourceFile), indentation, newLine)
    if commentOwnerInfo.hasReturn then
        tags = tags .. ls.returnsDocComment(indentation, newLine)
    end

    if tags ~= "" and not ls.hasJSDocTags(commentOwner, sourceFile) then
        local preamble = "/**" .. newLine .. indentation .. " * "
        local endLine = ""
        if tokenStart == position then
            endLine = newLine .. indentation
        end
        return { newText = preamble .. newLine .. tags .. indentation .. " */" .. endLine }
    end
    return { newText = "/** */" }
end

-- Returns end, ok, hasClosing.
function ls.getDocCommentEndAtPosition(file, position)
    local text = file:Text()
    local lineStart = format.GetLineStartPositionForPosition(position, file)
    local lineEnd = ls.getLineEndOfPosition(file, position)
    local prefix = string.sub(text, lineStart + 1, position)
    local suffix = string.sub(text, position + 1, lineEnd)
    if not hasSuffix(ls.trimRightSingleLineWhitespace(prefix), "/**") then
        return 0, false, false
    end
    local suffixEnd, hasClosing = ls.getJSDocSnippetSuffixEnd(suffix)
    return position + suffixEnd, true, hasClosing
end

function ls.skipWhitespace(text, position)
    while position < #text do
        local ch, size = stringutil.DecodeJSStringRune(text, position)
        if size == 0 then
            break
        end
        if not stringutil.IsWhiteSpaceLike(ch) then
            break
        end
        position = position + size
    end
    return position
end

function ls.getCommentOwnerInfo(tokenAtPos, generateReturnInDocTemplate)
    local node = tokenAtPos
    while node ~= nil do
        local info, quit = ls.getCommentOwnerInfoWorker(node, generateReturnInDocTemplate)
        if info ~= nil or quit then
            return info
        end
        node = node.parent
    end
    return nil
end

local functionLikeOwnerKinds = ast.kindSet(Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.MethodDeclaration, Kind.Constructor, Kind.MethodSignature, Kind.ArrowFunction)
local declarationOwnerKinds = ast.kindSet(Kind.ClassDeclaration, Kind.InterfaceDeclaration, Kind.EnumDeclaration, Kind.EnumMember, Kind.TypeAliasDeclaration)

function ls.getCommentOwnerInfoWorker(commentOwner, generateReturnInDocTemplate)
    if commentOwner == nil then
        return nil, false
    end
    local kind = commentOwner.kind
    if functionLikeOwnerKinds[kind] then
        return { commentOwner = commentOwner, parameters = commentOwner:Parameters(), hasReturn = ls.hasReturn(commentOwner, generateReturnInDocTemplate) }, false
    elseif kind == Kind.PropertyAssignment then
        return ls.getCommentOwnerInfoWorker(commentOwner:AsPropertyAssignment().initializer, generateReturnInDocTemplate)
    elseif declarationOwnerKinds[kind] then
        return { commentOwner = commentOwner, hasReturn = false }, false
    elseif kind == Kind.PropertySignature then
        local typeNode = commentOwner:AsPropertySignatureDeclaration().type
        if typeNode ~= nil and ast.IsFunctionTypeNode(typeNode) then
            return { commentOwner = commentOwner, parameters = typeNode:Parameters(), hasReturn = ls.hasReturn(typeNode, generateReturnInDocTemplate) }, false
        end
        return { commentOwner = commentOwner, hasReturn = false }, false
    elseif kind == Kind.VariableStatement then
        local declarations = commentOwner:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes
        if #declarations == 1 then
            local initializer = declarations[1]:AsVariableDeclaration().initializer
            if initializer ~= nil then
                local host = ls.getRightHandSideOfAssignment(initializer)
                if host ~= nil then
                    return { commentOwner = commentOwner, parameters = host:Parameters(), hasReturn = ls.hasReturn(host, generateReturnInDocTemplate) }, false
                end
            end
        end
        return { commentOwner = commentOwner, hasReturn = false }, false
    elseif kind == Kind.SourceFile then
        return nil, true
    elseif kind == Kind.ModuleDeclaration then
        if commentOwner.parent.kind == Kind.ModuleDeclaration then
            return nil, false
        end
        return { commentOwner = commentOwner, hasReturn = false }, false
    elseif kind == Kind.ExpressionStatement then
        return ls.getCommentOwnerInfoWorker(commentOwner:AsExpressionStatement().expression, generateReturnInDocTemplate)
    elseif kind == Kind.BinaryExpression then
        local binaryExpression = commentOwner:AsBinaryExpression()
        if ast.GetAssignmentDeclarationKind(commentOwner) == ast.JSDeclarationKind.None then
            return nil, true
        end
        if ast.IsFunctionLike(binaryExpression.right) then
            return { commentOwner = commentOwner, parameters = binaryExpression.right:Parameters(), hasReturn = ls.hasReturn(binaryExpression.right, generateReturnInDocTemplate) }, false
        end
        return { commentOwner = commentOwner, hasReturn = false }, false
    elseif kind == Kind.PropertyDeclaration then
        local initializer = commentOwner:AsPropertyDeclaration().initializer
        if initializer ~= nil and ast.IsFunctionExpressionOrArrowFunction(initializer) then
            return { commentOwner = commentOwner, parameters = initializer:Parameters(), hasReturn = ls.hasReturn(initializer, generateReturnInDocTemplate) }, false
        end
    end
    return nil, false
end

function ls.hasReturn(node, generateReturnInDocTemplate)
    if not generateReturnInDocTemplate then
        return false
    end
    if ast.IsFunctionTypeNode(node) then
        return true
    end
    if ast.IsArrowFunction(node) then
        local body = node:Body()
        if body ~= nil and ast.IsExpression(body) then
            return true
        end
    end
    return ast.IsFunctionLikeDeclaration(node) and node:Body() ~= nil and ast.IsBlock(node:Body()) and ast.ForEachReturnStatement(node:Body(), function(_)
        return true
    end)
end

function ls.getRightHandSideOfAssignment(rightHandSide)
    if rightHandSide == nil then
        return nil
    end
    while rightHandSide.kind == Kind.ParenthesizedExpression do
        rightHandSide = rightHandSide:AsParenthesizedExpression().expression
    end
    local kind = rightHandSide.kind
    if kind == Kind.FunctionExpression or kind == Kind.ArrowFunction then
        return rightHandSide
    elseif kind == Kind.ClassExpression then
        return core.Find(rightHandSide:Members(), ast.IsConstructorDeclaration)
    else
        return nil
    end
end

function ls.parameterDocComments(parameters, isJavaScriptFile, indentation, newLine)
    local b = {}
    for i1, parameter in ipairs(parameters or {}) do
        local paramName = string.format("param%d", i1 - 1)
        if ast.IsIdentifier(parameter:Name()) then
            paramName = parameter:Name():Text()
        end
        local paramType = ""
        if isJavaScriptFile then
            if parameter:AsParameterDeclaration().dotDotDotToken ~= nil then
                paramType = "{...any} "
            else
                paramType = "{any} "
            end
        end
        b[#b + 1] = indentation
        b[#b + 1] = " * @param "
        b[#b + 1] = paramType
        b[#b + 1] = paramName
        b[#b + 1] = newLine
    end
    return table.concat(b)
end

function ls.returnsDocComment(indentation, newLine)
    return indentation .. " * @returns" .. newLine
end

function ls.getIndentationStringAtPosition(sourceFile, position)
    local text = sourceFile:Text()
    local lineStart = format.GetLineStartPositionForPosition(position, sourceFile)
    local pos = lineStart
    while pos < position do
        local ch, size = stringutil.DecodeJSStringRune(text, pos)
        if size == 0 then
            break
        end
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            break
        end
        pos = pos + size
    end
    return string.sub(text, lineStart + 1, pos)
end

function ls.isNonEmptyJSDoc(jsdoc)
    if jsdoc == nil then
        return false
    end
    local data = jsdoc:AsJSDoc()
    return data.comment ~= nil and core.Len(data.comment.nodes) > 0 or data.tags ~= nil and core.Len(data.tags.nodes) > 0
end

function ls.hasJSDocTags(node, file)
    local jsdocs = node:JSDoc(file)
    if core.Len(jsdocs) == 0 then
        return false
    end
    local tags = jsdocs[#jsdocs]:AsJSDoc().tags
    return tags ~= nil and core.Len(tags.nodes) > 0
end

function ls.templateToSnippet(template, newLine)
    if template == "/** */" then
        return "/**" .. newLine .. " * $0" .. newLine .. " */"
    end

    local snippetIndex = { value = 1 }
    template = ls.escapeSnippetText(template)
    template = ls.stripJSDocTemplateIndentation(template, newLine)
    return ls.transformJSDocTemplateLines(template, newLine, snippetIndex)
end

function ls.stripJSDocTemplateIndentation(template, newLine)
    local lines = split(template, newLine)
    for i, line in ipairs(lines) do
        local trimmed = trimLeftSpacesTabs(line)
        if hasPrefix(trimmed, "/") then
            lines[i] = trimmed
        elseif hasPrefix(trimmed, "*") then
            lines[i] = " " .. trimmed
        end
    end
    return table.concat(lines, newLine)
end

-- snippetIndex is a box { value = int } (Go *int).
function ls.transformJSDocTemplateLines(template, newLine, snippetIndex)
    local lines = split(template, newLine)
    for i, line in ipairs(lines) do
        if i > 1 and hasPrefix(lines[i - 1], "/**") and ls.lineHasOnlyJSDocAsterisk(line) then
            lines[i] = line .. "$0"
            goto continue
        end
        do
            local transformed, ok = ls.transformJSDocParamLine(line, snippetIndex)
            if ok then
                lines[i] = transformed
                goto continue
            end
            transformed, ok = ls.transformJSDocReturnsLine(line, snippetIndex)
            if ok then
                lines[i] = transformed
            end
        end
        ::continue::
    end
    return table.concat(lines, newLine)
end

function ls.lineHasOnlyJSDocAsterisk(line)
    line = trimLeftSpacesTabs(line)
    return hasPrefix(line, "*") and ls.isOnlySpacesOrTabs(string.sub(line, 2))
end

function ls.transformJSDocParamLine(line, snippetIndex)
    local prefix = ""
    local rest = line
    if hasPrefix(rest, " ") then
        prefix = " "
        rest = string.sub(rest, 2)
    end
    if not hasPrefix(rest, "* @param") then
        return "", false
    end
    rest = string.sub(rest, #"* @param" + 1)
    if not ls.startsWithSingleLineWhitespace(rest) then
        return "", false
    end
    rest = trimLeftSpacesTabs(rest)

    local typeText = ""
    if hasPrefix(rest, "{") then
        local closeBrace = string.find(rest, "}", 1, true)
        if closeBrace == nil then
            return "", false
        end
        -- closeBrace is the 1-based index of '}' (Go closeBrace+1).
        typeText = " " .. string.sub(rest, 1, closeBrace)
        rest = string.sub(rest, closeBrace + 1)
        if not ls.startsWithSingleLineWhitespace(rest) then
            return "", false
        end
        rest = trimLeftSpacesTabs(rest)
    end

    local paramName, rest2, ok = ls.scanNonWhitespace(rest)
    if not ok or not ls.isOnlySpacesOrTabs(rest2) then
        return "", false
    end

    local out = prefix .. "* @param "
    if typeText == " {any}" or typeText == " {*}" then
        out = out .. string.format("{${%d:*}} ", snippetIndex.value)
        snippetIndex.value = snippetIndex.value + 1
    elseif typeText ~= "" then
        out = out .. typeText .. " "
    end
    out = out .. string.format("%s ${%d}", paramName, snippetIndex.value)
    snippetIndex.value = snippetIndex.value + 1
    return out, true
end

function ls.transformJSDocReturnsLine(line, snippetIndex)
    local prefix = ""
    local rest = line
    if hasPrefix(rest, " ") then
        prefix = " "
        rest = string.sub(rest, 2)
    end
    if not hasPrefix(rest, "* @returns") or not ls.isOnlySpacesOrTabs(string.sub(rest, #"* @returns" + 1)) then
        return "", false
    end
    local text = string.format("%s* @returns ${%d}", prefix, snippetIndex.value)
    snippetIndex.value = snippetIndex.value + 1
    return text, true
end

-- Returns word, rest, ok.
function ls.scanNonWhitespace(text)
    if text == "" then
        return "", "", false
    end
    local i = 0
    while i < #text do
        local ch, size = stringutil.DecodeJSStringRune(text, i)
        if size == 0 or stringutil.IsWhiteSpaceLike(ch) then
            if i == 0 then
                return "", "", false
            end
            return string.sub(text, 1, i), string.sub(text, i + 1), true
        end
        i = i + size
    end
    return text, "", true
end

function ls.isJSDocSnippetPrefix(prefix)
    local trimmed = ls.trimRightSingleLineWhitespace(prefix)
    if hasSuffix(trimmed, "/**") then
        return true
    end
    local start = ls.skipSingleLineWhitespace(prefix, 0)
    if start >= #trimmed or string.byte(trimmed, start + 1) ~= 0x2F --[[ '/' ]] then
        return false
    end
    if start + 3 > #trimmed then
        return false
    end
    for i = start + 1, #trimmed - 1 do
        if string.byte(trimmed, i + 1) ~= 0x2A --[[ '*' ]] then
            return false
        end
    end
    return #trimmed - start >= 3
end

-- Returns start, ok.
function ls.getJSDocSnippetPrefixStart(prefix)
    local trimmed = ls.trimRightSingleLineWhitespace(prefix)
    local i = #trimmed - 1
    while i >= 0 and string.byte(trimmed, i + 1) == 0x2A --[[ '*' ]] do
        if i > 0 and string.byte(trimmed, i) == 0x2F --[[ '/' ]] then
            return i - 1, true
        end
        i = i - 1
    end
    if hasSuffix(trimmed, "/") then
        return #trimmed - 1, true
    end
    return 0, false
end

function ls.isJSDocSnippetSuffix(suffix)
    local trimmed = ls.trimRightSingleLineWhitespace(string.sub(suffix, ls.skipSingleLineWhitespace(suffix, 0) + 1))
    if trimmed == "" then
        return true
    end
    if not hasSuffix(trimmed, "/") then
        return false
    end
    for i = 0, #trimmed - 2 do
        if string.byte(trimmed, i + 1) ~= 0x2A --[[ '*' ]] then
            return false
        end
    end
    return true
end

-- Returns end, ok.
function ls.getJSDocSnippetSuffixEnd(suffix)
    local pos = ls.skipSingleLineWhitespace(suffix, 0)
    while pos < #suffix and string.byte(suffix, pos + 1) == 0x2A --[[ '*' ]] do
        pos = pos + 1
    end
    if pos < #suffix and string.byte(suffix, pos + 1) == 0x2F --[[ '/' ]] then
        return pos + 1, true
    end
    return 0, false
end

function ls.trimRightSingleLineWhitespace(text)
    local end_ = 0
    local pos = 0
    while pos < #text do
        local ch, size = stringutil.DecodeJSStringRune(text, pos)
        if size == 0 then
            break
        end
        pos = pos + size
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            end_ = pos
        end
    end
    return string.sub(text, 1, end_)
end

function ls.skipSingleLineWhitespace(text, pos)
    while pos < #text do
        local ch, size = stringutil.DecodeJSStringRune(text, pos)
        if size == 0 or not stringutil.IsWhiteSpaceSingleLine(ch) then
            break
        end
        pos = pos + size
    end
    return pos
end

function ls.isOnlySingleLineWhitespace(text)
    return ls.skipSingleLineWhitespace(text, 0) == #text
end

function ls.startsWithSingleLineWhitespace(text)
    if text == "" then
        return false
    end
    local ch, size = stringutil.DecodeJSStringRune(text, 0)
    return size ~= 0 and stringutil.IsWhiteSpaceSingleLine(ch)
end

function ls.isOnlySpacesOrTabs(text)
    for i = 1, #text do
        local c = string.byte(text, i)
        if c ~= 0x20 and c ~= 0x09 then
            return false
        end
    end
    return true
end
