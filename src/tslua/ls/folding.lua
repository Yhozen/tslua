local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

local function compare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

-- Go strings.TrimLeftFunc(s, unicode.IsSpace)
local function trimLeftSpace(s)
    local i = 0
    while i < #s do
        local r, size = core.DecodeRune(s, i)
        if not stringutil.UnicodeIsSpace(r) then
            break
        end
        i = i + size
    end
    return string.sub(s, i + 1)
end

-- Go strings.TrimRightFunc(s, unicode.IsSpace)
local function trimRightSpace(s)
    local j = #s
    while j > 0 do
        local r, size = core.DecodeLastRune(s, j)
        if not stringutil.UnicodeIsSpace(r) then
            break
        end
        j = j - size
    end
    return string.sub(s, 1, j)
end

-- Go strings.TrimSpace
local function trimSpace(s)
    return trimRightSpace(trimLeftSpace(s))
end

function LanguageService:ProvideFoldingRange(ctx, documentURI)
    local _, sourceFile = self:getProgramAndFile(documentURI)
    local res = self:addNodeOutliningSpans(ctx, sourceFile)
    for _, r in ipairs(self:addRegionOutliningSpans(ctx, sourceFile)) do
        res[#res + 1] = r
    end
    if lsproto.GetClientCapabilities(ctx).textDocument.foldingRange.lineFoldingOnly then
        res = self:adjustFoldingEnd(res, sourceFile)
    end
    core.SortFunc(res, function(a, b)
        local c = compare(a.startLine, b.startLine)
        if c ~= 0 then
            return c
        end
        return compare(a.startCharacter, b.startCharacter)
    end)
    return { foldingRanges = res }, nil
end

-- adjustFoldingEnd adjusts the end line of folding ranges when the client signals lineFoldingOnly.
-- This mirrors the behavior of VS Code's built-in TypeScript extension (workaround for vscode#47240).
-- When lineFoldingOnly is true, we hide lines from startLine+1 to endLine. And to keep closing
-- brackets/braces visible, we subtract 1 from endLine when the range ends with a closing pair character.
function LanguageService:adjustFoldingEnd(ranges, sourceFile)
    local sourceText = sourceFile:Text()
    local result = {}
    for _, r in ipairs(ranges) do
        if r.endCharacter ~= nil and r.endCharacter > 0 then
            local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, {
                line = r.endLine,
                character = r.endCharacter,
            }, spanmap.Feature.FoldingRanges)
            if #positions == 1 and positions[1].script == sourceFile and not spanmap.Fidelity_IsNone(positions[1].fidelity) and positions[1].position > 0 and positions[1].position <= #sourceText then
                local endOffset = positions[1].position
                local foldEndChar = string.sub(sourceText, endOffset, endOffset)
                if foldEndChar == "}" or foldEndChar == "]" or foldEndChar == ")" or foldEndChar == "`" or foldEndChar == ">" then
                    if r.endLine > r.startLine then
                        r.endLine = r.endLine - 1
                    end
                end
            end
        end
        result[#result + 1] = r
    end
    return result
end

function LanguageService:addNodeOutliningSpans(ctx, sourceFile)
    local depthRemaining = 40
    local current = 0

    local statements = sourceFile.statements
    local n = #statements.nodes
    local foldingRange = {}
    local function appendAll(xs)
        for _, x in ipairs(xs or {}) do
            foldingRange[#foldingRange + 1] = x
        end
    end
    while current < n do
        while current < n and not ast.IsAnyImportSyntax(statements.nodes[current + 1]) do
            appendAll(ls.visitNode(ctx, statements.nodes[current + 1], depthRemaining, sourceFile, self))
            current = current + 1
        end
        if current == n then
            break
        end
        local firstImport = current
        while current < n and ast.IsAnyImportSyntax(statements.nodes[current + 1]) do
            appendAll(ls.visitNode(ctx, statements.nodes[current + 1], depthRemaining, sourceFile, self))
            current = current + 1
        end
        local lastImport = current - 1
        if lastImport ~= firstImport then
            local foldingRangeKind = lsproto.FoldingRangeKind.Imports
            local imports = ls.createFoldingRangeFromBounds(
                ctx,
                astnav.GetStartOfNode(astnav.FindChildOfKind(statements.nodes[firstImport + 1],
                    Kind.ImportKeyword, sourceFile), sourceFile, false --[[includeJSDoc]]),
                statements.nodes[lastImport + 1]:End(),
                foldingRangeKind,
                sourceFile,
                self
            )
            if imports ~= nil then
                foldingRange[#foldingRange + 1] = imports
            end
        end
    end

    -- Visit the EOF Token so that comments which aren't attached to statements are included.
    appendAll(ls.visitNode(ctx, sourceFile.endOfFileToken, depthRemaining, sourceFile, self))
    return foldingRange
end

function LanguageService:addRegionOutliningSpans(ctx, sourceFile)
    local regions = {}
    local out = {}
    local lineStarts = scanner.GetECMALineStarts(sourceFile)
    local text = sourceFile:Text()
    for _, currentLineStart in ipairs(lineStarts) do
        local lineEnd = ls.getLineEndOfPosition(sourceFile, currentLineStart)
        local lineText = string.sub(text, currentLineStart + 1, lineEnd)
        local result = ls.parseRegionDelimiter(lineText)
        if result == nil or ls.isInComment(sourceFile, currentLineStart, astnav.GetTokenAtPosition(sourceFile, currentLineStart)) ~= nil then
            goto continue
        end

        if result.isStart then
            local idx = string.find(lineText, "//", 1, true)
            local commentStart, fidelity = self:createLspPosition((idx ~= nil and idx - 1 or -1) + currentLineStart, sourceFile)
            if spanmap.Fidelity_IsNone(fidelity) then
                goto continue
            end
            local foldingRangeKindRegion = lsproto.FoldingRangeKind.Region
            local region = {
                startLine = commentStart.line,
                startCharacter = commentStart.character,
                kind = foldingRangeKindRegion,
            }
            if ls.supportsCollapsedText(ctx) then
                local collapsedText = "#region"
                if result.name ~= "" then
                    collapsedText = result.name
                end
                region.collapsedText = collapsedText
            end
            -- Our spans start out with some initial data.
            -- On every `#endregion`, we'll come back to these `FoldingRange`s
            -- and fill in their EndLine/EndCharacter.
            regions[#regions + 1] = region
        else
            if #regions > 0 then
                local region = regions[#regions]
                regions[#regions] = nil
                local endingPosition, fidelity = self:createLspPosition(lineEnd, sourceFile)
                if spanmap.Fidelity_IsNone(fidelity) then
                    goto continue
                end
                region.endLine = endingPosition.line
                region.endCharacter = endingPosition.character
                out[#out + 1] = region
            end
        end
        ::continue::
    end
    return out
end

function ls.visitNode(ctx, n, depthRemaining, sourceFile, l)
    if n.flags & NodeFlags.Reparsed ~= 0 or depthRemaining == 0 or ctxErr(ctx) then
        return nil
    end
    local foldingRange = {}
    local function appendAll(xs)
        for _, x in ipairs(xs or {}) do
            foldingRange[#foldingRange + 1] = x
        end
    end
    if (not ast.IsBinaryExpression(n) and ast.IsDeclaration(n)) or ast.IsVariableStatement(n) or ast.IsReturnStatement(n) or ast.IsCallOrNewExpression(n) or n.kind == Kind.EndOfFile then
        appendAll(ls.addOutliningForLeadingCommentsForNode(ctx, n, sourceFile, l))
    end
    if ast.IsFunctionLike(n) and n.parent ~= nil and ast.IsBinaryExpression(n.parent) and n.parent.left ~= nil and ast.IsPropertyAccessExpression(n.parent.left) then
        appendAll(ls.addOutliningForLeadingCommentsForNode(ctx, n.parent.left, sourceFile, l))
    end
    if ast.IsBlock(n) then
        local statements = n.statements
        if statements ~= nil then
            appendAll(ls.addOutliningForLeadingCommentsForPos(ctx, statements:End(), sourceFile, l))
        end
    end
    if ast.IsModuleBlock(n) then
        local statements = n.statements
        if statements ~= nil then
            appendAll(ls.addOutliningForLeadingCommentsForPos(ctx, statements:End(), sourceFile, l))
        end
    end
    if ast.IsClassLike(n) or ast.IsInterfaceDeclaration(n) then
        local members = n.members
        if members ~= nil then
            appendAll(ls.addOutliningForLeadingCommentsForPos(ctx, members:End(), sourceFile, l))
        end
    end

    local span = ls.getOutliningSpanForNode(ctx, n, sourceFile, l)
    if span ~= nil then
        foldingRange[#foldingRange + 1] = span
    end

    depthRemaining = depthRemaining - 1
    if ast.IsCallExpression(n) then
        depthRemaining = depthRemaining + 1
        local expressionNodes = ls.visitNode(ctx, n:Expression(), depthRemaining, sourceFile, l)
        if expressionNodes ~= nil then
            appendAll(expressionNodes)
        end
        depthRemaining = depthRemaining - 1
        for _, arg in ipairs(n:Arguments() or {}) do
            appendAll(ls.visitNode(ctx, arg, depthRemaining, sourceFile, l))
        end
        local typeArguments = n:TypeArguments()
        for _, typeArg in ipairs(typeArguments or {}) do
            appendAll(ls.visitNode(ctx, typeArg, depthRemaining, sourceFile, l))
        end
    elseif ast.IsIfStatement(n) and n.elseStatement ~= nil and ast.IsIfStatement(n.elseStatement) then
        -- Consider an 'else if' to be on the same depth as the 'if'.
        local ifStatement = n
        local expressionNodes = ls.visitNode(ctx, n:Expression(), depthRemaining, sourceFile, l)
        if expressionNodes ~= nil then
            appendAll(expressionNodes)
        end
        local thenNode = ls.visitNode(ctx, ifStatement.thenStatement, depthRemaining, sourceFile, l)
        if thenNode ~= nil then
            appendAll(thenNode)
        end
        depthRemaining = depthRemaining + 1
        local elseNode = ls.visitNode(ctx, ifStatement.elseStatement, depthRemaining, sourceFile, l)
        if elseNode ~= nil then
            appendAll(elseNode)
        end
        depthRemaining = depthRemaining - 1
    else
        n:ForEachChild(function(node)
            local childNode = ls.visitNode(ctx, node, depthRemaining, sourceFile, l)
            if childNode ~= nil then
                appendAll(childNode)
            end
            return false
        end)
    end
    return foldingRange
end

function ls.addOutliningForLeadingCommentsForNode(ctx, n, sourceFile, l)
    if ast.IsJsxText(n) then
        return nil
    end
    return ls.addOutliningForLeadingCommentsForPos(ctx, n:Pos(), sourceFile, l)
end

function ls.addOutliningForLeadingCommentsForPos(ctx, pos, sourceFile, l)
    local p = printer.NewEmitContext()
    local foldingRange = {}
    local firstSingleLineCommentStart = -1
    local lastSingleLineCommentEnd = -1
    local singleLineCommentCount = 0
    local foldingRangeKindComment = lsproto.FoldingRangeKind.Comment

    local function combineAndAddMultipleSingleLineComments()
        -- Only outline spans of two or more consecutive single line comments
        if singleLineCommentCount > 1 then
            return ls.createFoldingRangeFromBounds(ctx, firstSingleLineCommentStart, lastSingleLineCommentEnd, foldingRangeKindComment, sourceFile, l)
        end
        return nil
    end

    local sourceText = sourceFile:Text()
    for comment in scanner.GetLeadingCommentRanges(printer.NewNodeFactory(p):AsNodeFactory(), sourceText, pos) do
        local commentPos = comment:Pos()
        local commentEnd = comment:End()

        if ctxErr(ctx) then
            return nil
        end
        if comment.kind == Kind.SingleLineCommentTrivia then
            -- never fold region delimiters into single-line comment regions
            local commentText = string.sub(sourceText, commentPos + 1, commentEnd)
            if ls.parseRegionDelimiter(commentText) ~= nil then
                local comments = combineAndAddMultipleSingleLineComments()
                if comments ~= nil then
                    foldingRange[#foldingRange + 1] = comments
                end
                singleLineCommentCount = 0
            else
                -- For single line comments, combine consecutive ones (2 or more) into
                -- a single span from the start of the first till the end of the last
                if singleLineCommentCount == 0 then
                    firstSingleLineCommentStart = commentPos
                end
                lastSingleLineCommentEnd = commentEnd
                singleLineCommentCount = singleLineCommentCount + 1
            end
        elseif comment.kind == Kind.MultiLineCommentTrivia then
            local comments = combineAndAddMultipleSingleLineComments()
            if comments ~= nil then
                foldingRange[#foldingRange + 1] = comments
            end
            local commentRange = ls.createFoldingRangeFromBounds(ctx, commentPos, commentEnd, foldingRangeKindComment, sourceFile, l)
            if commentRange ~= nil then
                foldingRange[#foldingRange + 1] = commentRange
            end
            singleLineCommentCount = 0
        else
            debug.AssertNever(comment.kind)
        end
    end
    local addedComments = combineAndAddMultipleSingleLineComments()
    if addedComments ~= nil then
        foldingRange[#foldingRange + 1] = addedComments
    end
    return foldingRange
end

-- regionDelimiterResult: { isStart, name }

function ls.parseRegionDelimiter(lineText)
    -- We trim the leading whitespace and // without the regex since the
    -- multiple potential whitespace matches can make for some gnarly backtracking behavior
    lineText = trimLeftSpace(lineText)
    if not hasPrefix(lineText, "//") then
        return nil
    end
    lineText = trimSpace(string.sub(lineText, 3))
    if string.sub(lineText, -1) == "\r" then
        lineText = string.sub(lineText, 1, -2)
    end
    if not hasPrefix(lineText, "#") then
        return nil
    end
    lineText = string.sub(lineText, 2)
    local isStart = true
    if hasPrefix(lineText, "end") then
        isStart = false
        lineText = string.sub(lineText, 4)
    end
    if not hasPrefix(lineText, "region") then
        return nil
    end
    lineText = string.sub(lineText, 7)
    return {
        isStart = isStart,
        name = trimSpace(lineText),
    }
end

local blockAttachedParentKinds = ast.kindSet(Kind.DoStatement, Kind.ForInStatement, Kind.ForOfStatement, Kind.ForStatement, Kind.IfStatement, Kind.WhileStatement, Kind.WithStatement, Kind.CatchClause)
local openBraceSpanKinds = ast.kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration, Kind.EnumDeclaration, Kind.CaseBlock, Kind.TypeLiteral, Kind.ObjectBindingPattern)

function ls.getOutliningSpanForNode(ctx, n, sourceFile, l)
    local kind = n.kind
    if kind == Kind.Block then
        if ast.IsFunctionLike(n.parent) then
            return ls.functionSpan(ctx, n.parent, n, sourceFile, l)
        end
        -- Check if the block is standalone, or 'attached' to some parent statement.
        -- If the latter, we want to collapse the block, but consider its hint span
        -- to be the entire span of the parent.
        if blockAttachedParentKinds[n.parent.kind] then
            return ls.spanForNode(ctx, n, Kind.OpenBraceToken, true --[[useFullStart]], sourceFile, l)
        end
        if n.parent.kind == Kind.TryStatement then
            -- Could be the try-block, or the finally-block.
            local tryStatement = n.parent
            if tryStatement.tryBlock == n then
                return ls.spanForNode(ctx, n, Kind.OpenBraceToken, true --[[useFullStart]], sourceFile, l)
            elseif tryStatement.finallyBlock == n then
                local span = ls.spanForNode(ctx, n, Kind.OpenBraceToken, true --[[useFullStart]], sourceFile, l)
                if span ~= nil then
                    return span
                end
            end
            -- fallthrough
        end
        -- Block was a standalone block.  In this case we want to only collapse
        -- the span of the block, independent of any parent span.
        local textRange, fidelity = l:createLspRangeFromNodeForFeature(n, sourceFile, spanmap.Feature.FoldingRanges)
        if spanmap.Fidelity_IsNone(fidelity) then
            return nil
        end
        return ls.createFoldingRange(ctx, textRange, "", "")
    elseif kind == Kind.ModuleBlock then
        return ls.spanForNode(ctx, n, Kind.OpenBraceToken, true --[[useFullStart]], sourceFile, l)
    elseif openBraceSpanKinds[kind] then
        return ls.spanForNode(ctx, n, Kind.OpenBraceToken, true --[[useFullStart]], sourceFile, l)
    elseif kind == Kind.TupleType then
        return ls.spanForNode(ctx, n, Kind.OpenBracketToken, not ast.IsTupleTypeNode(n.parent) --[[useFullStart]], sourceFile, l)
    elseif kind == Kind.CaseClause or kind == Kind.DefaultClause then
        return ls.spanForNodeArray(ctx, n.statements, sourceFile, l)
    elseif kind == Kind.ObjectLiteralExpression then
        return ls.spanForNode(ctx, n, Kind.OpenBraceToken, not ast.IsArrayLiteralExpression(n.parent) and not ast.IsCallExpression(n.parent) --[[useFullStart]], sourceFile, l)
    elseif kind == Kind.ArrayLiteralExpression then
        return ls.spanForNode(ctx, n, Kind.OpenBracketToken, not ast.IsArrayLiteralExpression(n.parent) and not ast.IsCallExpression(n.parent) --[[useFullStart]], sourceFile, l)
    elseif kind == Kind.JsxElement or kind == Kind.JsxFragment then
        return ls.spanForJSXElement(ctx, n, sourceFile, l)
    elseif kind == Kind.JsxSelfClosingElement or kind == Kind.JsxOpeningElement then
        return ls.spanForJSXAttributes(ctx, n, sourceFile, l)
    elseif kind == Kind.TemplateExpression or kind == Kind.NoSubstitutionTemplateLiteral then
        return ls.spanForTemplateLiteral(ctx, n, sourceFile, l)
    elseif kind == Kind.ArrayBindingPattern then
        return ls.spanForNode(ctx, n, Kind.OpenBracketToken, not ast.IsBindingElement(n.parent) --[[useFullStart]], sourceFile, l)
    elseif kind == Kind.ArrowFunction then
        return ls.spanForArrowFunction(ctx, n, sourceFile, l)
    elseif kind == Kind.CallExpression then
        return ls.spanForCallExpression(ctx, n, sourceFile, l)
    elseif kind == Kind.ParenthesizedExpression then
        return ls.spanForParenthesizedExpression(ctx, n, sourceFile, l)
    elseif kind == Kind.NamedImports or kind == Kind.NamedExports or kind == Kind.ImportAttributes then
        return ls.spanForImportExportElements(ctx, n, sourceFile, l)
    end
    return nil
end

function ls.spanForImportExportElements(ctx, node, sourceFile, l)
    local elements
    if node.kind == Kind.NamedImports then
        elements = node.elements
    elseif node.kind == Kind.NamedExports then
        elements = node.elements
    elseif node.kind == Kind.ImportAttributes then
        elements = node.attributes
    end
    if elements == nil or #elements.nodes == 0 then
        return nil
    end
    local openToken = astnav.FindChildOfKind(node, Kind.OpenBraceToken, sourceFile)
    local closeToken = astnav.FindChildOfKind(node, Kind.CloseBraceToken, sourceFile)
    if openToken == nil or closeToken == nil or printer.PositionsAreOnSameLine(openToken:Pos(), closeToken:Pos(), sourceFile) then
        return nil
    end
    return ls.rangeBetweenTokens(ctx, openToken, closeToken, sourceFile, false --[[useFullStart]], l)
end

function ls.spanForParenthesizedExpression(ctx, node, sourceFile, l)
    local start = astnav.GetStartOfNode(node, sourceFile, false --[[includeJSDoc]])
    if printer.PositionsAreOnSameLine(start, node:End(), sourceFile) then
        return nil
    end
    local textRange, fidelity = l:createLspRangeFromBounds(start, node:End(), sourceFile)
    if spanmap.Fidelity_IsNone(fidelity) then
        return nil
    end
    return ls.createFoldingRange(ctx, textRange, "", "")
end

function ls.spanForCallExpression(ctx, node, sourceFile, l)
    if node.arguments == nil or #node.arguments.nodes == 0 then
        return nil
    end
    local openToken = astnav.FindChildOfKind(node, Kind.OpenParenToken, sourceFile)
    local closeToken = astnav.FindChildOfKind(node, Kind.CloseParenToken, sourceFile)
    if openToken == nil or closeToken == nil or printer.PositionsAreOnSameLine(openToken:Pos(), closeToken:Pos(), sourceFile) then
        return nil
    end

    return ls.rangeBetweenTokens(ctx, openToken, closeToken, sourceFile, true --[[useFullStart]], l)
end

function ls.spanForArrowFunction(ctx, node, sourceFile, l)
    local arrowFunctionNode = node
    if ast.IsBlock(arrowFunctionNode.body) or ast.IsParenthesizedExpression(arrowFunctionNode.body) or printer.PositionsAreOnSameLine(arrowFunctionNode.body:Pos(), arrowFunctionNode.body:End(), sourceFile) then
        return nil
    end
    local textRange, fidelity = l:createLspRangeFromBounds(arrowFunctionNode.body:Pos(), arrowFunctionNode.body:End(), sourceFile)
    if spanmap.Fidelity_IsNone(fidelity) then
        return nil
    end
    return ls.createFoldingRange(ctx, textRange, "", "")
end

function ls.spanForTemplateLiteral(ctx, node, sourceFile, l)
    if node.kind == Kind.NoSubstitutionTemplateLiteral and #node:Text() == 0 then
        return nil
    end
    return ls.createFoldingRangeFromBounds(ctx, astnav.GetStartOfNode(node, sourceFile, false --[[includeJSDoc]]), node:End(), "", sourceFile, l)
end

function ls.spanForJSXElement(ctx, node, sourceFile, l)
    if node.kind == Kind.JsxElement then
        local jsxElement = node
        local textRange, fidelity = l:createLspRangeFromBounds(astnav.GetStartOfNode(jsxElement.openingElement, sourceFile, false --[[includeJSDoc]]), jsxElement.closingElement:End(), sourceFile)
        if spanmap.Fidelity_IsNone(fidelity) then
            return nil
        end
        local tagName = scanner.GetTextOfNode(jsxElement.openingElement:TagName())
        local bannerText = "<" .. tagName .. ">...</" .. tagName .. ">"
        return ls.createFoldingRange(ctx, textRange, "", bannerText)
    end
    -- JsxFragment
    local jsxFragment = node
    local textRange, fidelity = l:createLspRangeFromBounds(astnav.GetStartOfNode(jsxFragment.openingFragment, sourceFile, false --[[includeJSDoc]]), jsxFragment.closingFragment:End(), sourceFile)
    if spanmap.Fidelity_IsNone(fidelity) then
        return nil
    end
    return ls.createFoldingRange(ctx, textRange, "", "<>...</>")
end

function ls.spanForJSXAttributes(ctx, node, sourceFile, l)
    local attributes = node.attributes
    if core.Len(attributes:Properties()) == 0 then
        return nil
    end
    return ls.createFoldingRangeFromBounds(ctx, astnav.GetStartOfNode(node, sourceFile, false --[[includeJSDoc]]), node:End(), "", sourceFile, l)
end

function ls.spanForNodeArray(ctx, statements, sourceFile, l)
    if statements ~= nil and #statements.nodes ~= 0 then
        local textRange, fidelity = l:createLspRangeFromBounds(statements:Pos(), statements:End(), sourceFile)
        if spanmap.Fidelity_IsNone(fidelity) then
            return nil
        end
        return ls.createFoldingRange(ctx, textRange, "", "")
    end
    return nil
end

function ls.spanForNode(ctx, node, open, useFullStart, sourceFile, l)
    local closeBrace = Kind.CloseBraceToken
    if open ~= Kind.OpenBraceToken then
        closeBrace = Kind.CloseBracketToken
    end
    local openToken = astnav.FindChildOfKind(node, open, sourceFile)
    local closeToken = astnav.FindChildOfKind(node, closeBrace, sourceFile)
    if openToken ~= nil and closeToken ~= nil then
        return ls.rangeBetweenTokens(ctx, openToken, closeToken, sourceFile, useFullStart, l)
    end
    return nil
end

function ls.rangeBetweenTokens(ctx, openToken, closeToken, sourceFile, useFullStart, l)
    local textRange, fidelity
    if useFullStart then
        textRange, fidelity = l:createLspRangeFromBounds(openToken:Pos(), closeToken:End(), sourceFile)
    else
        textRange, fidelity = l:createLspRangeFromBounds(astnav.GetStartOfNode(openToken, sourceFile, false --[[includeJSDoc]]), closeToken:End(), sourceFile)
    end
    if spanmap.Fidelity_IsNone(fidelity) then
        return nil
    end
    return ls.createFoldingRange(ctx, textRange, "", "")
end

function ls.supportsCollapsedText(ctx)
    return lsproto.GetClientCapabilities(ctx).textDocument.foldingRange.foldingRange.collapsedText
end

function ls.createFoldingRange(ctx, textRange, foldingRangeKind, collapsedText)
    local kind
    if foldingRangeKind ~= "" then
        kind = foldingRangeKind
    end
    local result = {
        startLine = textRange.start.line,
        startCharacter = textRange.start.character,
        endLine = textRange.end_.line,
        endCharacter = textRange.end_.character,
        kind = kind,
    }
    if collapsedText ~= "" and ls.supportsCollapsedText(ctx) then
        result.collapsedText = collapsedText
    end
    return result
end

function ls.createFoldingRangeFromBounds(ctx, pos, end_, foldingRangeKind, sourceFile, l)
    local textRange, fidelity = l:createLspRangeFromBounds(pos, end_, sourceFile)
    if spanmap.Fidelity_IsNone(fidelity) then
        return nil
    end
    return ls.createFoldingRange(ctx, textRange, foldingRangeKind, "")
end

function ls.functionSpan(ctx, node, body, sourceFile, l)
    local openToken = ls.tryGetFunctionOpenToken(node, body, sourceFile)
    local closeToken = astnav.FindChildOfKind(body, Kind.CloseBraceToken, sourceFile)
    if openToken ~= nil and closeToken ~= nil then
        return ls.rangeBetweenTokens(ctx, openToken, closeToken, sourceFile, true --[[useFullStart]], l)
    end
    return nil
end

function ls.tryGetFunctionOpenToken(node, body, sourceFile)
    if ls.isNodeArrayMultiLine(node:Parameters(), sourceFile) then
        local openParenToken = astnav.FindChildOfKind(node, Kind.OpenParenToken, sourceFile)
        if openParenToken ~= nil then
            return openParenToken
        end
    end
    return astnav.FindChildOfKind(body, Kind.OpenBraceToken, sourceFile)
end

function ls.isNodeArrayMultiLine(list, sourceFile)
    if core.Len(list) == 0 then
        return false
    end
    return not printer.PositionsAreOnSameLine(list[1]:Pos(), list[#list]:End(), sourceFile)
end
