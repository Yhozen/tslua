local format = require("tslua.format")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local kindSet = ast.kindSet
local IndentStyle = lsutil.IndentStyle

function format.GetIndentationForNode(n, ignoreActualIndentationRange, sourceFile, options)
    local startline, startpos = scanner.GetECMALineAndByteOffsetOfPosition(sourceFile,
        scanner.GetTokenPosOfNode(n, sourceFile, false))
    return format.getIndentationForNodeWorker(n, startline, startpos, ignoreActualIndentationRange,
        0 --[[indentationDelta]], sourceFile, false --[[isNextChild]], options)
end

-- GetIndentation computes the expected indentation for a position in a source file.
-- This is the Go port of SmartIndenter.getIndentation from TypeScript.
function format.GetIndentation(position, sourceFile, options, assumeNewLineBeforeCloseBrace)
    if position > #sourceFile:Text() then
        return options.baseIndentSize -- past EOF
    end

    -- no indentation when the indent style is set to none,
    -- so we can return fast
    if options.indentStyle == IndentStyle.None then
        return 0
    end

    local precedingToken = astnav.FindPrecedingTokenEx(sourceFile, position, nil --[[startNode]],
        true --[[excludeJSDoc]])

    local enclosingCommentRange = format.getRangeOfEnclosingComment(sourceFile, position, precedingToken)
    if enclosingCommentRange ~= nil and enclosingCommentRange.kind == Kind.MultiLineCommentTrivia then
        return format.getCommentIndent(sourceFile, position, options, enclosingCommentRange)
    end

    if precedingToken == nil then
        return options.baseIndentSize
    end

    -- no indentation in string/regex/template literals
    if format.isStringOrRegularExpressionOrTemplateLiteral(precedingToken.kind) then
        local tokenStart = scanner.GetTokenPosOfNode(precedingToken, sourceFile, false)
        if tokenStart <= position and position < precedingToken:End() then
            return 0
        end
    end

    local lineAtPosition = scanner.GetECMALineOfPosition(sourceFile, position)

    -- indentation is first non-whitespace character in a previous line
    -- for block indentation, we should look for a line which contains something that's not
    -- whitespace.
    local currentToken = astnav.GetTokenAtPosition(sourceFile, position)
    -- For object literals, we want indentation to work just like with blocks.
    -- If the `{` starts in any position (even in the middle of a line), then
    -- the following indentation should treat `{` as the start of that line (including leading whitespace).
    -- ```
    --     const a: { x: undefined, y: undefined } = {}       // leading 4 whitespaces and { starts in the middle of line
    -- ->
    --     const a: { x: undefined, y: undefined } = {
    --         x: undefined,
    --         y: undefined,
    --     }
    -- ---------------------
    --     const a: {x : undefined, y: undefined } =
    --      {}
    -- ->
    --     const a: { x: undefined, y: undefined } =
    --      {                                                  // leading 5 whitespaces and { starts at 6 column
    --          x: undefined,
    --          y: undefined,
    --      }
    -- ```
    local isObjectLiteral = currentToken.kind == Kind.OpenBraceToken and currentToken.parent ~= nil and
        currentToken.parent.kind == Kind.ObjectLiteralExpression
    if options.indentStyle == IndentStyle.Block or isObjectLiteral then
        return format.getBlockIndent(sourceFile, position, options)
    end

    if precedingToken.kind == Kind.CommaToken and precedingToken.parent ~= nil and
        precedingToken.parent.kind ~= Kind.BinaryExpression then
        -- previous token is comma that separates items in list - find the previous item and try to derive indentation from it
        local actualIndentation = format.getActualIndentationForListItemBeforeComma(precedingToken, sourceFile, options)
        if actualIndentation ~= -1 then
            return actualIndentation
        end
    end

    local containerList = format.getListByPosition(position, precedingToken.parent, sourceFile)
    -- use list position if the preceding token is before any list items
    if containerList ~= nil and not precedingToken.loc:ContainedBy(containerList.loc) then
        local useTheSameBaseIndentation = currentToken.parent ~= nil and
            (currentToken.parent.kind == Kind.FunctionExpression or currentToken.parent.kind == Kind.ArrowFunction)
        local indentSize = 0
        if not useTheSameBaseIndentation then
            indentSize = options.indentSize
        end
        local res = format.getActualIndentationForListStartLine(containerList, sourceFile, options)
        if res == -1 then
            return indentSize
        end
        return res + indentSize
    end

    return format.getSmartIndent(sourceFile, position, precedingToken, lineAtPosition, assumeNewLineBeforeCloseBrace,
        options)
end

function format.getCommentIndent(sourceFile, position, options, enclosingCommentRange)
    local previousLine = scanner.GetECMALineOfPosition(sourceFile, position) - 1
    local commentStartLine = scanner.GetECMALineOfPosition(sourceFile, enclosingCommentRange:Pos())

    debug.Assert(commentStartLine >= 0, "commentStartLine >= 0")

    if previousLine <= commentStartLine then
        local lineStarts = scanner.GetECMALineStarts(sourceFile)
        return format.FindFirstNonWhitespaceColumn(lineStarts[commentStartLine + 1], position, sourceFile, options)
    end

    local lineStarts = scanner.GetECMALineStarts(sourceFile)
    local startPositionOfLine = lineStarts[previousLine + 1]
    local character, column = format.findFirstNonWhitespaceCharacterAndColumn(startPositionOfLine, position, sourceFile,
        options)

    if column == 0 then
        return column
    end

    local firstNonWhitespaceCharacterCode = string.byte(sourceFile:Text(), startPositionOfLine + character + 1)
    if firstNonWhitespaceCharacterCode == 42 then -- '*'
        return column - 1
    end
    return column
end

-- Returns a Lua iterator over comment ranges, or nil (Go's nil iter.Seq).
function format.getLeadingCommentRangesOfNode(node, file)
    if node.kind == Kind.JsxText then
        return nil
    end
    return scanner.GetLeadingCommentRanges(ast.NewNodeFactory({}), file:Text(), node:Pos())
end

function format.getRangeOfEnclosingComment(sourceFile, position, precedingToken)
    local tokenAtPosition = astnav.GetTokenAtPosition(sourceFile, position)
    local jsdoc = ast.FindAncestor(tokenAtPosition, function(n) return n:IsJSDoc() end)
    if jsdoc ~= nil then
        tokenAtPosition = jsdoc.parent
    end
    local tokenStart = astnav.GetStartOfNode(tokenAtPosition, sourceFile, false --[[includeJSDoc]])
    if tokenStart <= position and position < tokenAtPosition:End() then
        return nil
    end

    -- Between two consecutive tokens, all comments are either trailing on the former
    -- or leading on the latter (and none are in both lists).
    local trailingRangesOfPreviousToken = nil
    if precedingToken ~= nil then
        trailingRangesOfPreviousToken = scanner.GetTrailingCommentRanges(ast.NewNodeFactory({}), sourceFile:Text(),
            precedingToken:End())
    end
    local leadingRangesOfNextToken = format.getLeadingCommentRangesOfNode(tokenAtPosition, sourceFile)
    -- core.ConcatenateSeq(trailingRangesOfPreviousToken, leadingRangesOfNextToken)
    for _, seq in ipairs({ trailingRangesOfPreviousToken or false, leadingRangesOfNextToken or false }) do
        if seq then
            for commentRange in seq do
                if commentRange:ContainsExclusive(position) or
                    position == commentRange:End() and
                    (commentRange.kind == Kind.SingleLineCommentTrivia or position == #sourceFile:Text()) then
                    return commentRange
                end
            end
        end
    end
    return nil
end

function format.getBlockIndent(sourceFile, position, options)
    -- move backwards until we find a line with a non-whitespace character,
    -- then find the first non-whitespace character for that line.
    local current = position
    local text = sourceFile:Text()
    while current > 0 do
        local ch, size = stringutil.DecodeRune(text, current)
        if not stringutil.IsWhiteSpaceLike(ch) then
            break
        end
        current = current - size
    end

    local lineStart = format.GetLineStartPositionForPosition(current, sourceFile)
    return format.FindFirstNonWhitespaceColumn(lineStart, current, sourceFile, options)
end

function format.getActualIndentationForListItemBeforeComma(commaToken, sourceFile, options)
    -- previous token is comma that separates items in list - find the previous item and try to derive indentation from it
    if commaToken.parent == nil then
        return -1
    end
    local containingList = format.GetContainingList(commaToken, sourceFile)
    if containingList == nil then
        return -1
    end
    local commaIndex = core.FindIndex(containingList.nodes, function(n) return n == commaToken end)
    if commaIndex > 0 then
        return format.deriveActualIndentationFromList(containingList, commaIndex - 1, sourceFile, options)
    end
    return -1
end

format.nextTokenKind = {
    nextTokenKindUnknown = 0,
    nextTokenKindOpenBrace = 1,
    nextTokenKindCloseBrace = 2,
}
local nextTokenKind = format.nextTokenKind

function format.nextTokenIsCurlyBraceOnSameLineAsCursor(precedingToken, current, lineAtPosition, sourceFile)
    local nextToken = astnav.FindNextToken(precedingToken, current, sourceFile)
    if nextToken == nil then
        return nextTokenKind.nextTokenKindUnknown
    end

    if nextToken.kind == Kind.OpenBraceToken then
        -- open braces are always indented at the parent level
        return nextTokenKind.nextTokenKindOpenBrace
    elseif nextToken.kind == Kind.CloseBraceToken then
        -- close braces are indented at the parent level if they are located on the same line with cursor
        local nextTokenStartLine = format.getStartLineForNode(nextToken, sourceFile)
        if lineAtPosition == nextTokenStartLine then
            return nextTokenKind.nextTokenKindCloseBrace
        end
        return nextTokenKind.nextTokenKindUnknown
    end

    return nextTokenKind.nextTokenKindUnknown
end

function format.getSmartIndent(sourceFile, position, precedingToken, lineAtPosition, assumeNewLineBeforeCloseBrace,
                               options)
    -- try to find node that can contribute to indentation and includes 'position' starting from 'precedingToken'
    -- if such node is found - compute initial indentation for 'position' inside this node
    local previous = nil
    local current = precedingToken

    while current ~= nil do
        if lsutil.PositionBelongsToNode(current, position, sourceFile) and
            format.ShouldIndentChildNode(options, current, previous, sourceFile, true) then
            local currentStartLine, currentStartChar = format.getStartLineAndCharacterForNode(current, sourceFile)
            local ntk = format.nextTokenIsCurlyBraceOnSameLineAsCursor(precedingToken, current, lineAtPosition,
                sourceFile)
            local indentationDelta = 0
            if ntk ~= nextTokenKind.nextTokenKindUnknown then
                -- handle cases when codefix is about to be inserted before the close brace
                if assumeNewLineBeforeCloseBrace and ntk == nextTokenKind.nextTokenKindCloseBrace then
                    indentationDelta = options.indentSize
                end
                -- else 0
            else
                if lineAtPosition ~= currentStartLine then
                    indentationDelta = options.indentSize
                end
            end
            return format.getIndentationForNodeWorker(current, currentStartLine, currentStartChar, nil, indentationDelta,
                sourceFile, true, options)
        end

        -- check if current node is a list item - if yes, take indentation from it
        -- do not consider parent-child line sharing yet:
        -- function foo(a
        --    | preceding node 'a' does share line with its parent but indentation is expected
        local actualIndentation = format.getActualIndentationForListItem(current, sourceFile, options,
            true --[[listIndentsChild]])
        if actualIndentation ~= -1 then
            return actualIndentation
        end

        previous = current
        current = current.parent
    end
    -- no parent was found - return the base indentation of the SourceFile
    return options.baseIndentSize
end

function format.getIndentationForNodeWorker(current, currentStartLine, currentStartCharacter,
                                            ignoreActualIndentationRange, indentationDelta, sourceFile, isNextChild,
                                            options)
    local parent = current.parent

    -- Walk up the tree and collect indentation for parent-child node pairs. Indentation is not added if
    -- * parent and child nodes start on the same line, or
    -- * parent is an IfStatement and child starts on the same line as an 'else clause'.
    while parent ~= nil do
        local useActualIndentation = true
        if ignoreActualIndentationRange ~= nil then
            local start = scanner.GetTokenPosOfNode(current, sourceFile, false)
            useActualIndentation = start < ignoreActualIndentationRange:Pos() or
                start > ignoreActualIndentationRange:End()
        end

        local containingListOrParentStartLine, containingListOrParentStartCharacter =
            format.getContainingListOrParentStart(parent, current, sourceFile)
        local parentAndChildShareLine = containingListOrParentStartLine == currentStartLine or
            format.childStartsOnTheSameLineWithElseInIfStatement(parent, current, currentStartLine, sourceFile)

        if useActualIndentation then
            -- check if current node is a list item - if yes, take indentation from it
            local firstListChild = nil
            local containerList = format.GetContainingList(current, sourceFile)
            if containerList ~= nil then
                firstListChild = core.FirstOrNil(containerList.nodes)
            end
            -- A list indents its children if the children begin on a later line than the list itself:
            --
            -- f1(               L0 - List start
            --   {               L1 - First child start: indented, along with all other children
            --     prop: 0
            --   },
            --   {
            --     prop: 1
            --   }
            -- )
            --
            -- f2({             L0 - List start and first child start: children are not indented.
            --   prop: 0             Object properties are indented only one level, because the list
            -- }, {                  itself contributes nothing.
            --   prop: 1        L3 - The indentation of the second object literal is best understood by
            -- })                    looking at the relationship between the list and *first* list item.
            local listIndentsChild = false
            if firstListChild ~= nil then
                local listLine = format.getStartLineForNode(firstListChild, sourceFile)
                listIndentsChild = listLine > containingListOrParentStartLine
            end
            local actualIndentation = format.getActualIndentationForListItem(current, sourceFile, options,
                listIndentsChild)
            if actualIndentation ~= -1 then
                return actualIndentation + indentationDelta
            end

            -- try to fetch actual indentation for current node from source text
            actualIndentation = format.getActualIndentationForNode(current, parent, currentStartLine,
                currentStartCharacter, parentAndChildShareLine, sourceFile, options)
            if actualIndentation ~= -1 then
                return actualIndentation + indentationDelta
            end
        end

        -- increase indentation if parent node wants its content to be indented and parent and child nodes don't start on the same line
        if format.ShouldIndentChildNode(options, parent, current, sourceFile, isNextChild) and
            not parentAndChildShareLine then
            indentationDelta = indentationDelta + options.indentSize
        end

        -- In our AST, a call argument's `parent` is the call-expression, not the argument list.
        -- We would like to increase indentation based on the relationship between an argument and its argument-list,
        -- so we spoof the starting position of the (parent) call-expression to match the (non-parent) argument-list.
        -- But, the spoofed start-value could then cause a problem when comparing the start position of the call-expression
        -- to *its* parent (in the case of an iife, an expression statement), adding an extra level of indentation.
        --
        -- Instead, when at an argument, we unspoof the starting position of the enclosing call expression
        -- *after* applying indentation for the argument.

        local useTrueStart = format.isArgumentAndStartLineOverlapsExpressionBeingCalled(parent, current,
            currentStartLine, sourceFile)

        current = parent
        parent = current.parent

        if useTrueStart then
            currentStartLine, currentStartCharacter = scanner.GetECMALineAndByteOffsetOfPosition(sourceFile,
                scanner.GetTokenPosOfNode(current, sourceFile, false))
        else
            currentStartLine = containingListOrParentStartLine
            currentStartCharacter = containingListOrParentStartCharacter
        end
    end

    return indentationDelta + options.baseIndentSize
end

--[[
* Function returns -1 if actual indentation for node should not be used (i.e because node is nested expression)
 ]]
function format.getActualIndentationForNode(current, parent, cuurentLine, currentChar, parentAndChildShareLine,
                                            sourceFile, options)
    -- actual indentation is used for statements\declarations if one of cases below is true:
    -- - parent is SourceFile - by default immediate children of SourceFile are not indented except when user indents them manually
    -- - parent and child are not on the same line
    local useActualIndentation = (ast.IsDeclaration(current) or ast.IsStatementButNotDeclaration(current)) and
        (parent.kind == Kind.SourceFile or not parentAndChildShareLine)

    if not useActualIndentation then
        return -1
    end

    return format.findColumnForFirstNonWhitespaceCharacterInLine(cuurentLine, currentChar, sourceFile, options)
end

function format.isArgumentAndStartLineOverlapsExpressionBeingCalled(parent, child, childStartLine, sourceFile)
    if not (ast.IsCallExpression(parent) and core.FindIndex(parent:Arguments(), function(a) return a == child end) ~= -1) then
        return false
    end
    local expressionOfCallExpressionEnd = parent:Expression():End()
    local expressionOfCallExpressionEndLine = scanner.GetECMALineOfPosition(sourceFile, expressionOfCallExpressionEnd)
    return expressionOfCallExpressionEndLine == childStartLine
end

function format.getActualIndentationForListItem(node, sourceFile, options, listIndentsChild)
    if node.parent ~= nil and node.parent.kind == Kind.VariableDeclarationList then
        -- VariableDeclarationList has no wrapping tokens
        return -1
    end
    local containingList = format.GetContainingList(node, sourceFile)
    if containingList ~= nil then
        local index = core.FindIndex(containingList.nodes, function(e) return e == node end)
        if index ~= -1 then
            local result = format.deriveActualIndentationFromList(containingList, index, sourceFile, options)
            if result ~= -1 then
                return result
            end
        end
        local delta = 0
        if listIndentsChild then
            delta = options.indentSize
        end
        local res = format.getActualIndentationForListStartLine(containingList, sourceFile, options)
        if res == -1 then
            return delta
        end
        return res + delta
    end
    return -1
end

function format.getActualIndentationForListStartLine(list, sourceFile, options)
    if list == nil then
        return -1
    end
    local line, char = scanner.GetECMALineAndByteOffsetOfPosition(sourceFile, list.loc:Pos())
    return format.findColumnForFirstNonWhitespaceCharacterInLine(line, char, sourceFile, options)
end

function format.deriveActualIndentationFromList(list, index, sourceFile, options)
    debug.Assert(list ~= nil and index >= 0 and index < core.Len(list.nodes))

    local node = list.nodes[index + 1]

    -- walk toward the start of the list starting from current node and check if the line is the same for all items.
    -- if end line for item [i - 1] differs from the start line for item [i] - find column of the first non-whitespace character on the line of item [i]

    local line, char = format.getStartLineAndCharacterForNode(node, sourceFile)

    for i = index, 0, -1 do
        if list.nodes[i + 1].kind ~= Kind.CommaToken then
            -- skip list items that ends on the same line with the current list element
            local prevEndLine = scanner.GetECMALineOfPosition(sourceFile, list.nodes[i + 1]:End())
            if prevEndLine ~= line then
                return format.findColumnForFirstNonWhitespaceCharacterInLine(line, char, sourceFile, options)
            end

            line, char = format.getStartLineAndCharacterForNode(list.nodes[i + 1], sourceFile)
        end
    end
    return -1
end

function format.findColumnForFirstNonWhitespaceCharacterInLine(line, char, sourceFile, options)
    local lineStart = scanner.GetECMAPositionOfLineAndByteOffset(sourceFile, line, 0)
    return format.FindFirstNonWhitespaceColumn(lineStart, lineStart + char, sourceFile, options)
end

function format.FindFirstNonWhitespaceColumn(startPos, endPos, sourceFile, options)
    local _, col = format.findFirstNonWhitespaceCharacterAndColumn(startPos, endPos, sourceFile, options)
    return col
end

--[[*
* Character is the actual index of the character since the beginning of the line.
* Column - position of the character after expanding tabs to spaces.
* "0\t2$"
* value of 'character' for '$' is 3
* value of 'column' for '$' is 6 (assuming that tab size is 4)
 ]]
-- Returns character, column.
function format.findFirstNonWhitespaceCharacterAndColumn(startPos, endPos, sourceFile, options)
    local column = 0
    local text = sourceFile:Text()
    local pos = startPos
    while pos < endPos do
        local ch, size = stringutil.DecodeRune(text, pos)
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            break
        end

        if ch == 9 then -- '\t'
            if options.tabSize > 0 then
                column = column + options.tabSize + (column % options.tabSize)
            end
        else
            column = column + 1
        end

        pos = pos + size
    end
    return pos - startPos, column
end

function format.childStartsOnTheSameLineWithElseInIfStatement(parent, child, childStartLine, sourceFile)
    if parent.kind == Kind.IfStatement and parent:AsIfStatement().elseStatement == child then
        local elseKeyword = astnav.FindPrecedingToken(sourceFile, child:Pos())
        debug.Assert(elseKeyword ~= nil)
        local elseKeywordStartLine = format.getStartLineForNode(elseKeyword, sourceFile)
        return elseKeywordStartLine == childStartLine
    end
    return false
end

-- Returns line, character.
function format.getStartLineAndCharacterForNode(n, sourceFile)
    return scanner.GetECMALineAndByteOffsetOfPosition(sourceFile, scanner.GetTokenPosOfNode(n, sourceFile, false))
end

function format.getStartLineForNode(n, sourceFile)
    return scanner.GetECMALineOfPosition(sourceFile, scanner.GetTokenPosOfNode(n, sourceFile, false))
end

function format.GetContainingList(node, sourceFile)
    if node.parent == nil then
        return nil
    end
    return format.getListByRange(scanner.GetTokenPosOfNode(node, sourceFile, false), node:End(), node.parent, sourceFile)
end

function format.getListByPosition(pos, node, sourceFile)
    if node == nil then
        return nil
    end
    return format.getListByRange(pos, pos, node, sourceFile)
end

local listByRangeFunctionKinds = kindSet(Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ArrowFunction,
    Kind.MethodDeclaration, Kind.MethodSignature, Kind.CallSignature, Kind.Constructor, Kind.ConstructorType,
    Kind.ConstructSignature)
local listByRangeTypeParameterKinds = kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.TypeAliasDeclaration, Kind.JSDocTemplateTag)
local listByRangeElementKinds = kindSet(Kind.ObjectBindingPattern, Kind.ArrayBindingPattern, Kind.NamedImports,
    Kind.NamedExports)

function format.getListByRange(start, end_, node, sourceFile)
    local r = core.NewTextRange(start, end_)
    local k = node.kind
    if k == Kind.TypeReference then
        return format.getList(node:TypeArgumentList(), r, node, sourceFile)
    elseif k == Kind.ObjectLiteralExpression then
        return format.getList(node:PropertyList(), r, node, sourceFile)
    elseif k == Kind.ArrayLiteralExpression then
        return format.getList(node:ElementList(), r, node, sourceFile)
    elseif k == Kind.TypeLiteral then
        return format.getList(node:MemberList(), r, node, sourceFile)
    elseif listByRangeFunctionKinds[k] then
        local tpl = format.getList(node:TypeParameterList(), r, node, sourceFile)
        if tpl ~= nil then
            return tpl
        end
        return format.getList(node:ParameterList(), r, node, sourceFile)
    elseif k == Kind.GetAccessor then
        return format.getList(node:ParameterList(), r, node, sourceFile)
    elseif listByRangeTypeParameterKinds[k] then
        return format.getList(node:TypeParameterList(), r, node, sourceFile)
    elseif k == Kind.NewExpression or k == Kind.CallExpression then
        local l = format.getList(node:TypeArgumentList(), r, node, sourceFile)
        if l ~= nil then
            return l
        end
        return format.getList(node:ArgumentList(), r, node, sourceFile)
    elseif k == Kind.VariableDeclarationList then
        return format.getList(node:AsVariableDeclarationList().declarations, r, node, sourceFile)
    elseif listByRangeElementKinds[k] then
        return format.getList(node:ElementList(), r, node, sourceFile)
    end
    return nil -- TODO: should this be a panic? It isn't in strada.
end

function format.getList(list, r, node, sourceFile)
    if list == nil then
        return nil
    end
    if r:ContainedBy(format.getVisualListRange(node, list.loc, sourceFile)) then
        return list
    end
    return nil
end

function format.getVisualListRange(node, list, sourceFile) -- luacheck: ignore 212
    -- In strada, this relied on the services .getChildren method, which manifested synthetic token nodes
    -- _however_, the logic boils down to "find the child with the matching span and adjust its start to the
    -- previous (possibly token) child's end and its end to the token start of the following element" - basically
    -- expanding the range to encompass all the neighboring non-token trivia
    -- Now, we perform that logic with the scanner instead
    local prior = astnav.FindPrecedingToken(sourceFile, list:Pos())
    local priorEnd
    if prior == nil then
        priorEnd = list:Pos()
    else
        priorEnd = prior:End()
    end
    -- Find the token that starts at or after list.End() using the scanner
    local scan = scanner.GetScannerForSourceFile(sourceFile, list:End())
    local nextStart
    if scan:Token() == Kind.EndOfFile then
        nextStart = list:End()
    else
        nextStart = scan:TokenStart()
    end
    return core.NewTextRange(priorEnd, nextStart)
end

-- Returns line, character.
function format.getContainingListOrParentStart(parent, child, sourceFile)
    local containingList = format.GetContainingList(child, sourceFile)
    local startPos
    if containingList ~= nil then
        startPos = containingList.loc:Pos()
    else
        startPos = scanner.GetTokenPosOfNode(parent, sourceFile, false)
    end
    return scanner.GetECMALineAndByteOffsetOfPosition(sourceFile, startPos)
end

function format.isControlFlowEndingStatement(kind, parentKind)
    if kind == Kind.ReturnStatement or kind == Kind.ThrowStatement or kind == Kind.ContinueStatement or
        kind == Kind.BreakStatement then
        return parentKind ~= Kind.Block
    end
    return false
end

--[[*
* True when the parent node should indent the given child by an explicit rule.
* @param isNextChild If true, we are judging indent of a hypothetical child *after* this one, not the current child.
 ]]
function format.ShouldIndentChildNode(settings, parent, child, sourceFile, ...)
    local isNextChild = false
    if select("#", ...) > 0 then
        isNextChild = (...)
    end

    return format.NodeWillIndentChild(settings, parent, child, sourceFile, false) and
        not (isNextChild and child ~= nil and format.isControlFlowEndingStatement(child.kind, parent.kind))
end

local willIndentChildAlwaysKinds = kindSet(Kind.ExpressionStatement, Kind.ClassDeclaration, Kind.ClassExpression,
    Kind.InterfaceDeclaration, Kind.EnumDeclaration, Kind.TypeAliasDeclaration, Kind.ArrayLiteralExpression,
    Kind.Block, Kind.ModuleBlock, Kind.ObjectLiteralExpression, Kind.TypeLiteral, Kind.MappedType, Kind.TupleType,
    Kind.ParenthesizedExpression, Kind.PropertyAccessExpression, Kind.CallExpression, Kind.NewExpression,
    Kind.VariableStatement, Kind.ExportAssignment, Kind.ReturnStatement, Kind.ConditionalExpression,
    Kind.ArrayBindingPattern, Kind.ObjectBindingPattern, Kind.JsxOpeningElement, Kind.JsxOpeningFragment,
    Kind.JsxSelfClosingElement, Kind.JsxExpression, Kind.MethodSignature, Kind.CallSignature,
    Kind.ConstructSignature, Kind.Parameter, Kind.FunctionType, Kind.ConstructorType, Kind.ParenthesizedType,
    Kind.TaggedTemplateExpression, Kind.AwaitExpression, Kind.NamedExports, Kind.NamedImports, Kind.ExportSpecifier,
    Kind.ImportSpecifier, Kind.PropertyDeclaration, Kind.CaseClause, Kind.DefaultClause)
local willIndentChildNotBlockKinds = kindSet(Kind.DoStatement, Kind.WhileStatement, Kind.ForInStatement,
    Kind.ForOfStatement, Kind.ForStatement, Kind.IfStatement, Kind.FunctionDeclaration, Kind.FunctionExpression,
    Kind.MethodDeclaration, Kind.Constructor, Kind.GetAccessor, Kind.SetAccessor)

function format.NodeWillIndentChild(settings, parent, child, sourceFile, indentByDefault)
    local childKind = Kind.Unknown
    if child ~= nil then
        childKind = child.kind
    end

    local k = parent.kind
    if willIndentChildAlwaysKinds[k] then
        return true
    elseif k == Kind.CaseBlock then
        return core.Tristate_IsTrueOrUnknown(settings.indentSwitchCase)
    elseif k == Kind.VariableDeclaration or k == Kind.PropertyAssignment or k == Kind.BinaryExpression then
        if core.Tristate_IsFalseOrUnknown(settings.indentMultiLineObjectLiteralBeginningOnBlankLine) and
            sourceFile ~= nil and childKind == Kind.ObjectLiteralExpression then
            return format.rangeIsOnOneLine(child.loc, sourceFile)
        end
        if parent.kind == Kind.BinaryExpression and sourceFile ~= nil and childKind == Kind.JsxElement then
            local parentStartLine = scanner.GetECMALineOfPosition(sourceFile,
                scanner.SkipTrivia(sourceFile:Text(), parent:Pos()))
            local childStartLine = scanner.GetECMALineOfPosition(sourceFile,
                scanner.SkipTrivia(sourceFile:Text(), child:Pos()))
            return parentStartLine ~= childStartLine
        end
        if parent.kind ~= Kind.BinaryExpression then
            return true
        end
        return indentByDefault
    elseif willIndentChildNotBlockKinds[k] then
        return childKind ~= Kind.Block
    elseif k == Kind.ArrowFunction then
        if sourceFile ~= nil and childKind == Kind.ParenthesizedExpression then
            return format.rangeIsOnOneLine(child.loc, sourceFile)
        end
        return childKind ~= Kind.Block
    elseif k == Kind.ExportDeclaration then
        return childKind ~= Kind.NamedExports
    elseif k == Kind.ImportDeclaration then
        return childKind ~= Kind.ImportClause or
            (child:AsImportClause().namedBindings ~= nil and child:AsImportClause().namedBindings.kind ~= Kind.NamedImports)
    elseif k == Kind.JsxElement then
        return childKind ~= Kind.JsxClosingElement
    elseif k == Kind.JsxFragment then
        return childKind ~= Kind.JsxClosingFragment
    elseif k == Kind.IntersectionType or k == Kind.UnionType or k == Kind.SatisfiesExpression then
        if childKind == Kind.TypeLiteral or childKind == Kind.TupleType or childKind == Kind.MappedType then
            return false
        end
        return indentByDefault
    elseif k == Kind.TryStatement then
        if childKind == Kind.Block then
            return false
        end
        return indentByDefault
    end

    -- No explicit rule for given nodes so the result will follow the default value argument
    return indentByDefault
end

-- A multiline conditional typically increases the indentation of its whenTrue and whenFalse children:
--
-- condition
--
--	? whenTrue
--	: whenFalse;
--
-- However, that indentation does not apply if the subexpressions themselves span multiple lines,
-- applying their own indentation:
--
--	(() => {
--	  return complexCalculationForCondition();
--	})() ? {
--
--	  whenTrue: 'multiline object literal'
--	} : (
--
--	whenFalse('multiline parenthesized expression')
--
-- );
--
-- In these cases, we must discard the indentation increase that would otherwise be applied to the
-- whenTrue and whenFalse children to avoid double-indenting their contents. To identify this scenario,
-- we check for the whenTrue branch beginning on the line that the condition ends, and the whenFalse
-- branch beginning on the line that the whenTrue branch ends.
function format.childIsUnindentedBranchOfConditionalExpression(parent, child, childStartLine, sourceFile)
    if parent.kind == Kind.ConditionalExpression and
        (child == parent:AsConditionalExpression().whenTrue or child == parent:AsConditionalExpression().whenFalse) then
        local conditionEndLine = scanner.GetECMALineOfPosition(sourceFile,
            parent:AsConditionalExpression().condition:End())
        if child == parent:AsConditionalExpression().whenTrue then
            return childStartLine == conditionEndLine
        else
            -- On the whenFalse side, we have to look at the whenTrue side, because if that one was
            -- indented, whenFalse must also be indented:
            --
            -- const y = true
            --   ? 1 : (          L1: whenTrue indented because it's on a new line
            --     0              L2: indented two stops, one because whenTrue was indented
            --   );                   and one because of the parentheses spanning multiple lines
            local trueStartLine = format.getStartLineForNode(parent:AsConditionalExpression().whenTrue, sourceFile)
            local trueEndLine = scanner.GetECMALineOfPosition(sourceFile,
                parent:AsConditionalExpression().whenTrue:End())
            return conditionEndLine == trueStartLine and trueEndLine == childStartLine
        end
    end
    return false
end

function format.argumentStartsOnSameLineAsPreviousArgument(parent, child, childStartLine, sourceFile)
    if ast.IsCallExpression(parent) or ast.IsNewExpression(parent) then
        if core.Len(parent:Arguments()) == 0 then
            return false
        end
        local currentIndex = core.FindIndex(parent:Arguments(), function(n) return n == child end)
        if currentIndex == -1 then
            -- If it's not one of the arguments, don't look past this
            return false
        end
        if currentIndex == 0 then
            return false -- Can't look at previous node if first
        end

        local previousNode = parent:Arguments()[currentIndex]
        local lineOfPreviousNode = scanner.GetECMALineOfPosition(sourceFile, previousNode:End())
        if childStartLine == lineOfPreviousNode then
            return true
        end
    end
    return false
end
