local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local ScriptKind = core.ScriptKind
local PC = parser.ParsingContext

-- jsdocScannerInfo (unexported Go enum, not in consts_generated)
parser.jsdocScannerInfoHasJSDoc = 1 << 0
parser.jsdocScannerInfoHasDeprecated = 1 << 1
parser.jsdocScannerInfoHasSeeOrLink = 1 << 2
local jsdocScannerInfoHasJSDoc = parser.jsdocScannerInfoHasJSDoc

local Parser = {}
Parser.__index = Parser
parser.Parser = Parser

-- Truncates a Go-style slice held in a Lua array in place (Go `xs = xs[0:n]`).
function parser.truncate(xs, n)
    if xs == nil then
        return nil
    end
    for i = #xs, n + 1, -1 do
        xs[i] = nil
    end
    return xs
end

local function append(xs, x)
    if xs == nil then
        return { x }
    end
    xs[#xs + 1] = x
    return xs
end
parser.append = append

local function appendAll(xs, ys)
    if ys == nil or #ys == 0 then
        return xs
    end
    if xs == nil then
        xs = {}
    end
    for _, y in ipairs(ys) do
        xs[#xs + 1] = y
    end
    return xs
end
parser.appendAll = appendAll

function parser.newParser()
    local res = setmetatable({}, Parser)
    res.scanner = nil
    res.factory = ast.NewNodeFactory({})
    res.opts = nil
    res.sourceText = ""
    res.scriptKind = ScriptKind.Unknown
    res.languageVariant = core.LanguageVariant.Standard
    res.diagnostics = {}
    res.jsDiagnostics = {}
    res.jsdocDiagnostics = {}
    res.token = Kind.Unknown
    res.sourceFlags = 0
    res.contextFlags = 0
    res.parsingContexts = 0
    res.statementHasAwaitIdentifier = false
    res.hasDeprecatedTag = false
    res.hasParseError = false
    res.identifierCount = 0
    res.notParenthesizedArrow = {}
    res.jsdocInfos = {}
    res.possibleAwaitSpans = {}
    res.reparseList = nil
    res.currentParent = nil
    res.reparsedClones = {}
    res:initializeClosures()
    return res
end

parser.viableKeywordSuggestions = nil -- computed lazily (scanner.GetViableKeywordSuggestions())

function parser.getViableKeywordSuggestions()
    if parser.viableKeywordSuggestions == nil then
        parser.viableKeywordSuggestions = scanner.GetViableKeywordSuggestions()
    end
    return parser.viableKeywordSuggestions
end

-- missingListNodes is a sentinel used to distinguish "missing" node lists
-- (where the expected opening token was not found) from ordinary empty node lists.
-- In Lua each missing list gets its own empty nodes array, registered in this weak set.
parser.missingListNodes = setmetatable({}, { __mode = "k" })

function parser.isMissingNodeList(list)
    return list ~= nil and parser.missingListNodes[list.nodes] == true
end

function parser.getParser()
    return parser.newParser()
end

function parser.ParseSourceFile(opts, sourceText, scriptKind)
    local p = parser.getParser()
    p:initializeState(opts, sourceText, scriptKind)
    p:nextToken()
    if p.scriptKind == ScriptKind.JSON then
        return p:parseJSONText()
    end
    return p:parseSourceFileWorker()
end

function Parser:initializeClosures()
    local p = self
    self.setParentFromContext = function(n)
        n.parent = p.currentParent
        return false
    end
end

function Parser:isJavaScript()
    return self.scriptKind == ScriptKind.JS or self.scriptKind == ScriptKind.JSX
end

function Parser:parseJSONText()
    local p = self
    local pos = p:nodePos()
    local statements
    local eof

    if p.token == Kind.EndOfFile then
        statements = p:newNodeList(core.NewTextRange(pos, p:nodePos()), nil)
        eof = p:parseTokenNode()
    else
        local expressions = nil -- array of expressions | single expression
        local expressionsIsList = false

        while p.token ~= Kind.EndOfFile do
            local expression
            local t = p.token
            if t == Kind.OpenBracketToken then
                expression = p:parseArrayLiteralExpression()
            elseif t == Kind.TrueKeyword or t == Kind.FalseKeyword or t == Kind.NullKeyword then
                expression = p:parseTokenNode()
            elseif t == Kind.MinusToken then
                if p:lookAhead(function(p2)
                    return p2:nextToken() == Kind.NumericLiteral and p2:nextToken() ~= Kind.ColonToken
                end) then
                    expression = p:parsePrefixUnaryExpression()
                else
                    expression = p:parseObjectLiteralExpression()
                end
            elseif (t == Kind.NumericLiteral or t == Kind.StringLiteral) and p:lookAhead(function(p2) return p2:nextToken() ~= Kind.ColonToken end) then
                expression = p:parseLiteralExpression()
            else
                expression = p:parseObjectLiteralExpression()
            end

            -- Error recovery: collect multiple top-level expressions
            if expressions ~= nil then
                if expressionsIsList then
                    expressions[#expressions + 1] = expression
                else
                    expressions = { expressions, expression }
                    expressionsIsList = true
                end
            else
                expressions = expression
                if p.token ~= Kind.EndOfFile then
                    p:parseErrorAtCurrentToken(diagnostics.Unexpected_token)
                end
            end
        end

        local expression
        if expressionsIsList then
            expression = p:finishNode(p.factory:NewArrayLiteralExpression(p:newNodeList(core.NewTextRange(pos, p:nodePos()), expressions), false), pos)
        else
            expression = expressions
        end
        local statement = p:finishNode(p.factory:NewExpressionStatement(expression), pos)
        statements = p:newNodeList(core.NewTextRange(pos, p:nodePos()), { statement })
        eof = p:parseExpectedToken(Kind.EndOfFile)
    end
    local node = p:finishNode(p.factory:NewSourceFile(p.opts, p.sourceText, statements, eof), pos)
    local result = node:AsSourceFile()
    if #result.statements.nodes > 0 then
        p:validateJsonValue(result, result.statements.nodes[1]:Expression())
    end
    p:finishSourceFile(result, false)
    return result
end

function parser.getErrorSpanForNode(sourceText, node)
    local pos = node:Pos()
    if not ast.NodeIsMissing(node) then
        pos = scanner.SkipTrivia(sourceText, pos)
    end
    return core.NewTextRange(pos, node:End())
end

function Parser:validateJsonValue(sourceFile, valueExpression)
    if valueExpression == nil then
        return
    end
    local k = valueExpression.kind
    if k == Kind.TrueKeyword or k == Kind.FalseKeyword or k == Kind.NullKeyword or k == Kind.NumericLiteral then
        return
    elseif k == Kind.StringLiteral then
        if not parser.isDoubleQuotedString(valueExpression) then
            self.diagnostics = append(self.diagnostics, ast.NewDiagnostic(sourceFile, parser.getErrorSpanForNode(self.sourceText, valueExpression), diagnostics.String_literal_with_double_quotes_expected))
        end
        return
    elseif k == Kind.PrefixUnaryExpression then
        local u = valueExpression:AsPrefixUnaryExpression()
        if not (u.operator ~= Kind.MinusToken or u.operand.kind ~= Kind.NumericLiteral) then
            return
        end
        -- not valid JSON syntax
    elseif k == Kind.ObjectLiteralExpression then
        self:validateJsonObjectLiteral(sourceFile, valueExpression:AsObjectLiteralExpression())
        return
    elseif k == Kind.ArrayLiteralExpression then
        for _, element in ipairs(valueExpression:Elements() or {}) do
            self:validateJsonValue(sourceFile, element)
        end
        return
    end
    self.diagnostics = append(self.diagnostics, ast.NewDiagnostic(sourceFile, parser.getErrorSpanForNode(self.sourceText, valueExpression), diagnostics.Property_value_can_only_be_string_literal_numeric_literal_true_false_null_object_literal_or_array_literal))
end

function parser.isDoubleQuotedString(node)
    return ast.IsStringLiteral(node) and node:AsStringLiteral().tokenFlags & ast.TokenFlags.SingleQuote == 0
end

-- validateJsonObjectLiteral validates properties of a JSON object literal.
function Parser:validateJsonObjectLiteral(sourceFile, node)
    for _, element in ipairs(node.properties.nodes) do
        if element.kind ~= Kind.PropertyAssignment then
            self.diagnostics = append(self.diagnostics, ast.NewDiagnostic(sourceFile, parser.getErrorSpanForNode(self.sourceText, element), diagnostics.Property_assignment_expected))
        else
            if element:Name() ~= nil and not parser.isDoubleQuotedString(element:Name()) then
                self.diagnostics = append(self.diagnostics, ast.NewDiagnostic(sourceFile, parser.getErrorSpanForNode(self.sourceText, element:Name()), diagnostics.String_literal_with_double_quotes_expected))
            end
            self:validateJsonValue(sourceFile, element:AsPropertyAssignment().initializer)
        end
    end
end

function parser.ParseIsolatedEntityName(text)
    local p = parser.getParser()
    p:initializeState(ast.NewSourceFileParseOptions("", "", nil), text, ScriptKind.JS)
    p:nextToken()
    local entityName = p:parseEntityName(true, false, nil)
    if p.token == Kind.EndOfFile and #p.diagnostics == 0 then
        return entityName
    end
    return nil
end

function Parser:initializeState(opts, sourceText, scriptKind)
    if scriptKind == ScriptKind.Unknown then
        error("ScriptKind must be specified when parsing source file: " .. opts.fileName, 0)
    end

    if self.scanner == nil then
        self.scanner = scanner.NewScanner()
    else
        self.scanner:Reset()
    end
    self.opts = opts
    self.sourceText = sourceText
    self.scriptKind = scriptKind
    self.languageVariant = parser.getLanguageVariant(self.scriptKind)
    if self.scriptKind == ScriptKind.JS or self.scriptKind == ScriptKind.JSX then
        self.contextFlags = NodeFlags.JavaScriptFile
    elseif self.scriptKind == ScriptKind.JSON then
        self.contextFlags = NodeFlags.JavaScriptFile | NodeFlags.JsonFile
    else
        self.contextFlags = NodeFlags.None
    end
    self.scanner:SetText(self.sourceText)
    local p = self
    self.scanner:SetOnError(function(message, pos, length, ...)
        p:scanError(message, pos, length, ...)
    end)
    self.scanner:SetLanguageVariant(self.languageVariant)
end

function Parser:scanError(message, pos, length, ...)
    self:parseErrorAtRange(core.NewTextRange(pos, pos + length), message, ...)
end

function Parser:parseErrorAt(pos, end_, message, ...)
    return self:parseErrorAtRange(core.NewTextRange(pos, end_), message, ...)
end

function Parser:parseErrorAtCurrentToken(message, ...)
    return self:parseErrorAtRange(self.scanner:TokenRange(), message, ...)
end

function Parser:parseErrorAtRange(loc, message, ...)
    -- Don't report another error if it would just be at the same location as the last error
    local result = nil
    local n = #self.diagnostics
    if n == 0 or self.diagnostics[n]:Pos() ~= loc:Pos() then
        result = ast.NewDiagnostic(nil, loc, message, ...)
        self.diagnostics[n + 1] = result
    end
    self.hasParseError = true
    return result
end

-- ParserState
function Parser:mark()
    return {
        scannerState = self.scanner:Mark(),
        contextFlags = self.contextFlags,
        diagnosticsLen = #self.diagnostics,
        jsDiagnosticsLen = #self.jsDiagnostics,
        jsdocInfosLen = #self.jsdocInfos,
        reparsedClonesLen = #self.reparsedClones,
        statementHasAwaitIdentifier = self.statementHasAwaitIdentifier,
        hasParseError = self.hasParseError,
    }
end

function Parser:rewind(state)
    self.scanner:Rewind(state.scannerState)
    self.token = self.scanner:Token()
    self.contextFlags = state.contextFlags
    parser.truncate(self.diagnostics, state.diagnosticsLen)
    parser.truncate(self.jsDiagnostics, state.jsDiagnosticsLen)
    parser.truncate(self.jsdocInfos, state.jsdocInfosLen)
    parser.truncate(self.reparsedClones, state.reparsedClonesLen)
    self.statementHasAwaitIdentifier = state.statementHasAwaitIdentifier
    self.hasParseError = state.hasParseError
end

function Parser:lookAhead(callback)
    local state = self:mark()
    local result = callback(self)
    self:rewind(state)
    return result
end

function Parser:nextToken()
    -- if the keyword had an escape
    if ast.IsKeyword(self.token) and (self.scanner:HasUnicodeEscape() or self.scanner:HasExtendedUnicodeEscape()) then
        -- issue a parse error for the escape
        self:parseErrorAtCurrentToken(diagnostics.Keywords_cannot_contain_escape_characters)
    end
    self.token = self.scanner:Scan()
    return self.token
end

function Parser:nextTokenWithoutCheck()
    self.token = self.scanner:Scan()
    return self.token
end

function Parser:nextTokenJSDoc()
    self.token = self.scanner:ScanJSDocToken()
    return self.token
end

function Parser:nextJSDocCommentTextToken(inBackticks)
    self.token = self.scanner:ScanJSDocCommentTextToken(inBackticks)
    return self.token
end

function Parser:nodePos()
    return self.scanner:TokenFullStart()
end

function Parser:hasPrecedingLineBreak()
    return self.scanner:HasPrecedingLineBreak()
end

function Parser:jsdocScannerInfo()
    if not self.scanner:HasPrecedingJSDocComment() then
        return 0
    end
    local info = jsdocScannerInfoHasJSDoc
    if self.scanner:HasPrecedingJSDocWithDeprecatedTag() then
        info = info | parser.jsdocScannerInfoHasDeprecated
    end
    if self.scanner:HasPrecedingJSDocWithSeeOrLink() then
        info = info | parser.jsdocScannerInfoHasSeeOrLink
    end
    return info
end

function Parser:parseSourceFileWorker()
    local p = self
    local isDeclarationFile = tspath.IsDeclarationFileName(p.opts.fileName)
    if isDeclarationFile then
        p.contextFlags = p.contextFlags | NodeFlags.Ambient
    end
    local pos = p:nodePos()
    local statements = p:parseListIndex(PC.PCSourceElements, Parser.parseToplevelStatement)
    local end_ = p:nodePos()
    local endJSDoc = p:jsdocScannerInfo()
    local eof = p:parseTokenNode()
    p:withJSDoc(eof, endJSDoc)
    if eof.kind ~= Kind.EndOfFile then
        error("Expected end of file token from scanner.", 0)
    end
    if p.reparseList ~= nil and #p.reparseList ~= 0 then
        statements = appendAll(statements, p.reparseList)
        p.reparseList = nil
    end
    local node = p:finishNode(p.factory:NewSourceFile(p.opts, p.sourceText, p:newNodeList(core.NewTextRange(pos, end_), statements), eof), pos)
    local result = node:AsSourceFile()
    p:finishSourceFile(result, isDeclarationFile)
    if not result.isDeclarationFile and result.externalModuleIndicator ~= nil and #p.possibleAwaitSpans > 0 then
        local reparse = p:finishNode(p:reparseTopLevelAwait(result), pos)
        if node ~= reparse then
            result = reparse:AsSourceFile()
            p:finishSourceFile(result, isDeclarationFile)
        end
    end
    parser.collectExternalModuleReferences(result)
    if ast.IsInJSFile(node) then
        result:SetJSDiagnostics(parser.attachFileToDiagnostics(p.jsDiagnostics, result))
    end
    return result
end

function Parser:finishSourceFile(result, isDeclarationFile)
    local p = self
    result.commentDirectives = p.scanner:CommentDirectives()
    result.pragmas = parser.getCommentPragmas(p.factory, p.sourceText)
    p:processPragmasIntoFields(result)
    result:SetDiagnostics(parser.attachFileToDiagnostics(p.diagnostics, result))
    result:SetJSDocDiagnostics(parser.attachFileToDiagnostics(p.jsdocDiagnostics, result))
    result.isDeclarationFile = isDeclarationFile
    result.languageVariant = p.languageVariant
    result.scriptKind = p.scriptKind
    result.flags = result.flags | p.sourceFlags
    result.nodeCount = p.factory:NodeCount()
    result.textCount = p.factory:TextCount()
    result.identifierCount = p.identifierCount
    result:SetJSDocCache(p:createJSDocCache())
    -- For non-JS files, enable lazy JSDoc parsing on demand
    if not p:isJavaScript() then
        result:SetHasLazyJSDoc(true)
    end
    core.SortStableFunc(p.reparsedClones, ast.CompareNodePositions)
    local clones = {}
    for i, c in ipairs(p.reparsedClones) do
        clones[i] = c
    end
    result.reparsedClones = clones
    ast.SetExternalModuleIndicator(result, p.opts.externalModuleIndicatorOptions)
end

function Parser:createJSDocCache()
    if #self.jsdocInfos == 0 then
        return nil
    end
    local result = {}
    for _, info in ipairs(self.jsdocInfos) do
        result[info.parent] = info.jsDocs
    end
    return result
end

function Parser:parseToplevelStatement(i)
    self.statementHasAwaitIdentifier = false
    local statement = self:parseStatement()
    -- Reparsed nodes (e.g. JSDoc @typedef) produced while parsing this statement are inserted
    -- into the statement list before this statement, so account for them when recording the
    -- statement's index for possibleAwaitSpans.
    i = i + core.Len(self.reparseList)
    if self.statementHasAwaitIdentifier and statement.flags & NodeFlags.AwaitContext == 0 then
        local spans = self.possibleAwaitSpans
        if #spans == 0 or spans[#spans] ~= i then
            spans[#spans + 1] = i
            spans[#spans + 1] = i + 1
        else
            spans[#spans] = i + 1
        end
    end
    return statement
end

function Parser:reparseTopLevelAwait(sourceFile)
    local p = self
    if #p.possibleAwaitSpans % 2 == 1 then
        error("possibleAwaitSpans malformed: odd number of indices, not paired into spans.", 0)
    end
    local statements = {}
    local savedParseDiagnostics = p.diagnostics
    p.diagnostics = {}
    local nodes = sourceFile.statements.nodes

    local afterAwaitStatement = 0
    local i = 0
    while i < #p.possibleAwaitSpans do
        local nextAwaitStatement = p.possibleAwaitSpans[i + 1]
        -- append all non-await statements between afterAwaitStatement and nextAwaitStatement
        local prevStatement = nodes[afterAwaitStatement + 1]
        local nextStatement = nodes[nextAwaitStatement + 1]
        for j = afterAwaitStatement, nextAwaitStatement - 1 do
            statements[#statements + 1] = nodes[j + 1]
        end

        -- append all diagnostics associated with the copied range
        local diagnosticStart = core.FindIndex(savedParseDiagnostics, function(diagnostic)
            return diagnostic:Pos() >= prevStatement:Pos()
        end)
        local diagnosticEnd
        if diagnosticStart >= 0 then
            diagnosticEnd = core.FindIndex(core.Slice(savedParseDiagnostics, diagnosticStart, #savedParseDiagnostics), function(diagnostic)
                return diagnostic:Pos() >= nextStatement:Pos()
            end)
        else
            diagnosticEnd = -1
        end
        if diagnosticStart >= 0 then
            local slice
            if diagnosticEnd >= 0 then
                slice = core.Slice(savedParseDiagnostics, diagnosticStart, diagnosticStart + diagnosticEnd)
            else
                slice = core.Slice(savedParseDiagnostics, diagnosticStart, #savedParseDiagnostics)
            end
            p.diagnostics = appendAll(p.diagnostics, slice)
        end

        local state = p:mark()
        -- reparse all statements between start and pos. We skip existing diagnostics for the same range and allow the parser to generate new ones.
        p.contextFlags = p.contextFlags | NodeFlags.AwaitContext
        p.scanner:ResetPos(nextStatement:Pos())
        p:nextToken()

        afterAwaitStatement = p.possibleAwaitSpans[i + 2]
        while p.token ~= Kind.EndOfFile do
            local startPos = p.scanner:TokenFullStart()
            local statement = p:parseStatement()
            statements[#statements + 1] = statement
            if startPos == p.scanner:TokenFullStart() then
                p:nextToken()
            end
            if afterAwaitStatement < #nodes then
                local lastAwaitStatement = nodes[afterAwaitStatement]
                if statement:End() == lastAwaitStatement:End() then
                    -- done reparsing this section
                    break
                end
                if statement:End() > lastAwaitStatement:End() then
                    -- we ate into the next statement, so we must continue reparsing the next span
                    i = i + 2
                    if i < #p.possibleAwaitSpans then
                        afterAwaitStatement = p.possibleAwaitSpans[i + 2]
                    else
                        afterAwaitStatement = #nodes
                    end
                end
            end
        end

        -- Keep diagnostics from the reparse
        state.diagnosticsLen = #p.diagnostics
        p:rewind(state)
        i = i + 2
    end

    -- append all statements between pos and the end of the list
    if afterAwaitStatement < #nodes then
        local prevStatement = nodes[afterAwaitStatement + 1]
        for j = afterAwaitStatement, #nodes - 1 do
            statements[#statements + 1] = nodes[j + 1]
        end

        -- append all diagnostics associated with the copied range
        local diagnosticStart = core.FindIndex(savedParseDiagnostics, function(diagnostic)
            return diagnostic:Pos() >= prevStatement:Pos()
        end)
        if diagnosticStart >= 0 then
            p.diagnostics = appendAll(p.diagnostics, core.Slice(savedParseDiagnostics, diagnosticStart, #savedParseDiagnostics))
        end
    end

    local result = p.factory:NewSourceFile(sourceFile:ParseOptions(), p.sourceText, p:newNodeList(sourceFile.statements.loc, statements), sourceFile.endOfFileToken)
    for _, s in ipairs(statements) do
        s.parent = result -- force (re)set parent to reparsed source file
    end
    return result
end

function Parser:parseListIndex(kind, parseElement)
    local p = self
    local saveParsingContexts = p.parsingContexts
    p.parsingContexts = p.parsingContexts | (1 << kind)
    local outerReparseList = p.reparseList
    p.reparseList = nil
    local list = {}
    while not p:isListTerminator(kind) do
        if p:isListElement(kind, false --[[inErrorRecovery]]) then
            local elt = parseElement(p, #list)
            if p.reparseList ~= nil and #p.reparseList ~= 0 then
                for _, e in ipairs(p.reparseList) do
                    -- Propagate @typedef type alias declarations outwards to a context that permits them.
                    if (ast.IsJSTypeAliasDeclaration(e) or ast.IsJSImportDeclaration(e)) and kind ~= PC.PCSourceElements and kind ~= PC.PCBlockStatements then
                        outerReparseList = append(outerReparseList, e)
                    else
                        list[#list + 1] = e
                    end
                end
                p.reparseList = nil
            end
            list[#list + 1] = elt
        elseif p:abortParsingListOrMoveToNextToken(kind) then
            break
        end
    end
    p.reparseList = outerReparseList
    p.parsingContexts = saveParsingContexts
    return list
end

function Parser:parseList(kind, parseElement)
    local pos = self:nodePos()
    local nodes = self:parseListIndex(kind, function(p, _) return parseElement(p) end)
    return self:newNodeList(core.NewTextRange(pos, self:nodePos()), nodes)
end

-- Return a non-nil (but possibly empty) slice if parsing was successful, or nil if parseElement returned nil
function Parser:parseDelimitedList(kind, parseElement)
    local p = self
    local pos = p:nodePos()
    local saveParsingContexts = p.parsingContexts
    p.parsingContexts = p.parsingContexts | (1 << kind)
    local list = {}
    while true do
        if p:isListElement(kind, false --[[inErrorRecovery]]) then
            local startPos = p:nodePos()
            local element = parseElement(p)
            if element == nil then
                p.parsingContexts = saveParsingContexts
                -- Return nil to indicate parseElement failed
                return nil
            end
            list[#list + 1] = element
            if p:parseOptional(Kind.CommaToken) then
                -- No need to check for a zero length node since we know we parsed a comma
                goto continue
            end
            if p:isListTerminator(kind) then
                break
            end
            -- We didn't get a comma, and the list wasn't terminated, explicitly parse
            -- out a comma so we give a good error message.
            if p.token ~= Kind.CommaToken and kind == PC.PCEnumMembers then
                p:parseErrorAtCurrentToken(diagnostics.An_enum_member_name_must_be_followed_by_a_or)
            else
                p:parseExpected(Kind.CommaToken)
            end
            -- If the token was a semicolon, and the caller allows that, then skip it and
            -- continue.  This ensures we get back on track and don't result in tons of
            -- parse errors.  For example, this can happen when people do things like use
            -- a semicolon to delimit object literal members.   Note: we'll have already
            -- reported an error when we called parseExpected above.
            if (kind == PC.PCObjectLiteralMembers or kind == PC.PCImportAttributes) and p.token == Kind.SemicolonToken and not p:hasPrecedingLineBreak() then
                p:nextToken()
            end
            if startPos == p:nodePos() then
                -- What we're parsing isn't actually remotely recognizable as a element and we've consumed no tokens whatsoever
                -- Consume a token to advance the parser in some way and avoid an infinite loop
                -- This can happen when we're speculatively parsing parenthesized expressions which we think may be arrow functions,
                -- or when a modifier keyword which is disallowed as a parameter name (ie, `static` in strict mode) is supplied
                p:nextToken()
            end
            goto continue
        end
        if p:isListTerminator(kind) then
            break
        end
        if p:abortParsingListOrMoveToNextToken(kind) then
            break
        end
        ::continue::
    end
    p.parsingContexts = saveParsingContexts
    return p:newNodeList(core.NewTextRange(pos, p:nodePos()), list)
end

-- Return a non-nil (but possibly empty) NodeList if parsing was successful, a missing NodeList if the opening
-- token wasn't found, or nil if parseElement returned nil.
function Parser:parseBracketedList(kind, parseElement, opening, closing)
    if self:parseExpected(opening) then
        local result = self:parseDelimitedList(kind, parseElement)
        self:parseExpected(closing)
        return result
    end
    return self:createMissingList()
end

function Parser:parseEmptyNodeList()
    return self:newNodeList(core.NewTextRange(self:nodePos(), self:nodePos()), nil)
end

function Parser:createMissingList()
    local result = self:parseEmptyNodeList()
    local nodes = {}
    parser.missingListNodes[nodes] = true
    result.nodes = nodes
    return result
end

-- Returns true if we should abort parsing.
function Parser:abortParsingListOrMoveToNextToken(kind)
    self:parsingContextErrors(kind)
    if self:isInSomeParsingContext() then
        return true
    end
    self:nextToken()
    return false
end

-- True if positioned at element or terminator of the current list or any enclosing list
function Parser:isInSomeParsingContext()
    -- We should be in at least one parsing context, be it SourceElements while parsing
    -- a SourceFile, or JSDocComment when lazily parsing JSDoc.
    assert(self.parsingContexts ~= 0, "Missing parsing context")
    for kind = 0, PC.PCCount - 1 do
        if self.parsingContexts & (1 << kind) ~= 0 then
            if self:isListElement(kind, true --[[inErrorRecovery]]) or self:isListTerminator(kind) then
                return true
            end
        end
    end
    return false
end

function Parser:parsingContextErrors(context)
    local p = self
    if context == PC.PCSourceElements then
        if p.token == Kind.DefaultKeyword then
            p:parseErrorAtCurrentToken(diagnostics.X_0_expected, "export")
        else
            p:parseErrorAtCurrentToken(diagnostics.Declaration_or_statement_expected)
        end
    elseif context == PC.PCBlockStatements then
        p:parseErrorAtCurrentToken(diagnostics.Declaration_or_statement_expected)
    elseif context == PC.PCSwitchClauses then
        p:parseErrorAtCurrentToken(diagnostics.X_case_or_default_expected)
    elseif context == PC.PCSwitchClauseStatements then
        p:parseErrorAtCurrentToken(diagnostics.Statement_expected)
    elseif context == PC.PCRestProperties or context == PC.PCTypeMembers then
        p:parseErrorAtCurrentToken(diagnostics.Property_or_signature_expected)
    elseif context == PC.PCClassMembers then
        p:parseErrorAtCurrentToken(diagnostics.Unexpected_token_A_constructor_method_accessor_or_property_was_expected)
    elseif context == PC.PCEnumMembers then
        p:parseErrorAtCurrentToken(diagnostics.Enum_member_expected)
    elseif context == PC.PCHeritageClauseElement then
        p:parseErrorAtCurrentToken(diagnostics.Expression_expected)
    elseif context == PC.PCVariableDeclarations then
        if ast.IsKeyword(p.token) then
            p:parseErrorAtCurrentToken(diagnostics.X_0_is_not_allowed_as_a_variable_declaration_name, scanner.TokenToString(p.token))
        else
            p:parseErrorAtCurrentToken(diagnostics.Variable_declaration_expected)
        end
    elseif context == PC.PCObjectBindingElements then
        p:parseErrorAtCurrentToken(diagnostics.Property_destructuring_pattern_expected)
    elseif context == PC.PCArrayBindingElements then
        p:parseErrorAtCurrentToken(diagnostics.Array_element_destructuring_pattern_expected)
    elseif context == PC.PCArgumentExpressions then
        p:parseErrorAtCurrentToken(diagnostics.Argument_expression_expected)
    elseif context == PC.PCObjectLiteralMembers then
        p:parseErrorAtCurrentToken(diagnostics.Property_assignment_expected)
    elseif context == PC.PCArrayLiteralMembers then
        p:parseErrorAtCurrentToken(diagnostics.Expression_or_comma_expected)
    elseif context == PC.PCJSDocParameters then
        p:parseErrorAtCurrentToken(diagnostics.Parameter_declaration_expected)
    elseif context == PC.PCParameters then
        if ast.IsKeyword(p.token) then
            p:parseErrorAtCurrentToken(diagnostics.X_0_is_not_allowed_as_a_parameter_name, scanner.TokenToString(p.token))
        else
            p:parseErrorAtCurrentToken(diagnostics.Parameter_declaration_expected)
        end
    elseif context == PC.PCTypeParameters then
        p:parseErrorAtCurrentToken(diagnostics.Type_parameter_declaration_expected)
    elseif context == PC.PCTypeArguments then
        p:parseErrorAtCurrentToken(diagnostics.Type_argument_expected)
    elseif context == PC.PCTupleElementTypes then
        p:parseErrorAtCurrentToken(diagnostics.Type_expected)
    elseif context == PC.PCHeritageClauses then
        p:parseErrorAtCurrentToken(diagnostics.Unexpected_token_expected)
    elseif context == PC.PCImportOrExportSpecifiers then
        if p.token == Kind.FromKeyword then
            p:parseErrorAtCurrentToken(diagnostics.X_0_expected, "}")
        else
            p:parseErrorAtCurrentToken(diagnostics.Identifier_expected)
        end
    elseif context == PC.PCJsxAttributes or context == PC.PCJsxChildren or context == PC.PCJSDocComment then
        p:parseErrorAtCurrentToken(diagnostics.Identifier_expected)
    elseif context == PC.PCImportAttributes then
        p:parseErrorAtCurrentToken(diagnostics.Identifier_or_string_literal_expected)
    else
        error("Unhandled case in parsingContextErrors", 0)
    end
end

function Parser:isListElement(parsingContext, inErrorRecovery)
    local p = self
    local t = p.token
    if parsingContext == PC.PCSourceElements or parsingContext == PC.PCBlockStatements or parsingContext == PC.PCSwitchClauseStatements then
        -- If we're in error recovery, then we don't want to treat ';' as an empty statement.
        -- The problem is that ';' can show up in far too many contexts, and if we see one
        -- and assume it's a statement, then we may bail out inappropriately from whatever
        -- we're parsing.  For example, if we have a semicolon in the middle of a class, then
        -- we really don't want to assume the class is over and we're on a statement in the
        -- outer module.  We just want to consume and move on.
        return not (t == Kind.SemicolonToken and inErrorRecovery) and p:isStartOfStatement()
    elseif parsingContext == PC.PCSwitchClauses then
        return t == Kind.CaseKeyword or t == Kind.DefaultKeyword
    elseif parsingContext == PC.PCTypeMembers then
        return p:lookAhead(Parser.scanTypeMemberStart)
    elseif parsingContext == PC.PCClassMembers then
        -- We allow semicolons as class elements (as specified by ES6) as long as we're
        -- not in error recovery.  If we're in error recovery, we don't want an errant
        -- semicolon to be treated as a class member (since they're almost always used
        -- for statements.
        return p:lookAhead(Parser.scanClassMemberStart) or t == Kind.SemicolonToken and not inErrorRecovery
    elseif parsingContext == PC.PCEnumMembers then
        -- Include open bracket computed properties. This technically also lets in indexers,
        -- which would be a candidate for improved error reporting.
        return t == Kind.OpenBracketToken or p:isLiteralPropertyName()
    elseif parsingContext == PC.PCObjectLiteralMembers then
        if t == Kind.OpenBracketToken or t == Kind.AsteriskToken or t == Kind.DotDotDotToken or t == Kind.DotToken then -- Not an object literal member, but don't want to close the object (see `tests/cases/fourslash/completionsDotInObjectLiteral.ts`)
            return true
        end
        return p:isLiteralPropertyName()
    elseif parsingContext == PC.PCRestProperties then
        return p:isLiteralPropertyName()
    elseif parsingContext == PC.PCObjectBindingElements then
        return t == Kind.OpenBracketToken or t == Kind.DotDotDotToken or p:isLiteralPropertyName()
    elseif parsingContext == PC.PCImportAttributes then
        return p:isImportAttributeName()
    elseif parsingContext == PC.PCHeritageClauseElement then
        -- If we see `{ ... }` then only consume it as an expression if it is followed by `,` or `{`
        -- That way we won't consume the body of a class in its heritage clause.
        if t == Kind.OpenBraceToken then
            return p:isValidHeritageClauseObjectLiteral()
        end
        if not inErrorRecovery then
            return p:isStartOfLeftHandSideExpression() and not p:isHeritageClauseExtendsOrImplementsKeyword()
        end
        -- If we're in error recovery we tighten up what we're willing to match.
        -- That way we don't treat something like "this" as a valid heritage clause
        -- element during recovery.
        return p:isIdentifier() and not p:isHeritageClauseExtendsOrImplementsKeyword()
    elseif parsingContext == PC.PCVariableDeclarations then
        return p:isBindingIdentifierOrPrivateIdentifierOrPattern()
    elseif parsingContext == PC.PCArrayBindingElements then
        return t == Kind.CommaToken or t == Kind.DotDotDotToken or p:isBindingIdentifierOrPrivateIdentifierOrPattern()
    elseif parsingContext == PC.PCTypeParameters then
        return t == Kind.InKeyword or t == Kind.ConstKeyword or p:isIdentifier()
    elseif parsingContext == PC.PCArrayLiteralMembers or parsingContext == PC.PCArgumentExpressions then
        if parsingContext == PC.PCArrayLiteralMembers then
            -- Not an array literal member, but don't want to close the array (see `tests/cases/fourslash/completionsDotInArrayLiteralInObjectLiteral.ts`)
            if t == Kind.CommaToken or t == Kind.DotToken then
                return true
            end
        end
        return t == Kind.DotDotDotToken or p:isStartOfExpression()
    elseif parsingContext == PC.PCParameters then
        return p:isStartOfParameter(false --[[isJSDocParameter]])
    elseif parsingContext == PC.PCJSDocParameters then
        return p:isStartOfParameter(true --[[isJSDocParameter]])
    elseif parsingContext == PC.PCTypeArguments or parsingContext == PC.PCTupleElementTypes then
        return t == Kind.CommaToken or p:isStartOfType(false --[[inStartOfParameter]])
    elseif parsingContext == PC.PCHeritageClauses then
        return p:isHeritageClause()
    elseif parsingContext == PC.PCImportOrExportSpecifiers then
        -- bail out if the next token is [FromKeyword StringLiteral].
        -- That means we're in something like `import { from "mod"`. Stop here can give better error message.
        if t == Kind.FromKeyword and p:lookAhead(Parser.nextTokenIsTokenStringLiteral) then
            return false
        end
        if t == Kind.StringLiteral then
            return true -- For "arbitrary module namespace identifiers"
        end
        return parser.tokenIsIdentifierOrKeyword(t)
    elseif parsingContext == PC.PCJsxAttributes then
        return parser.tokenIsIdentifierOrKeyword(t) or t == Kind.OpenBraceToken
    elseif parsingContext == PC.PCJsxChildren then
        return true
    elseif parsingContext == PC.PCJSDocComment then
        return true
    end
    error("Unhandled case in isListElement", 0)
end

function Parser:isListTerminator(kind)
    local p = self
    local t = p.token
    if t == Kind.EndOfFile then
        return true
    end
    if kind == PC.PCBlockStatements or kind == PC.PCSwitchClauses or kind == PC.PCTypeMembers or kind == PC.PCClassMembers or
        kind == PC.PCEnumMembers or kind == PC.PCObjectLiteralMembers or kind == PC.PCObjectBindingElements or
        kind == PC.PCImportOrExportSpecifiers or kind == PC.PCImportAttributes then
        return t == Kind.CloseBraceToken
    elseif kind == PC.PCSwitchClauseStatements then
        return t == Kind.CloseBraceToken or t == Kind.CaseKeyword or t == Kind.DefaultKeyword
    elseif kind == PC.PCHeritageClauseElement then
        return t == Kind.OpenBraceToken or t == Kind.ExtendsKeyword or t == Kind.ImplementsKeyword
    elseif kind == PC.PCVariableDeclarations then
        -- If we can consume a semicolon (either explicitly, or with ASI), then consider us done
        -- with parsing the list of variable declarators.
        -- In the case where we're parsing the variable declarator of a 'for-in' statement, we
        -- are done if we see an 'in' keyword in front of us. Same with for-of
        -- ERROR RECOVERY TWEAK:
        -- For better error recovery, if we see an '=>' then we just stop immediately.  We've got an
        -- arrow function here and it's going to be very unlikely that we'll resynchronize and get
        -- another variable declaration.
        return p:canParseSemicolon() or t == Kind.InKeyword or t == Kind.OfKeyword or t == Kind.EqualsGreaterThanToken
    elseif kind == PC.PCTypeParameters then
        -- Tokens other than '>' are here for better error recovery
        return t == Kind.GreaterThanToken or t == Kind.OpenParenToken or t == Kind.OpenBraceToken or t == Kind.ExtendsKeyword or t == Kind.ImplementsKeyword
    elseif kind == PC.PCArgumentExpressions then
        -- Tokens other than ')' are here for better error recovery
        return t == Kind.CloseParenToken or t == Kind.SemicolonToken
    elseif kind == PC.PCArrayLiteralMembers or kind == PC.PCTupleElementTypes or kind == PC.PCArrayBindingElements then
        return t == Kind.CloseBracketToken
    elseif kind == PC.PCJSDocParameters or kind == PC.PCParameters or kind == PC.PCRestProperties then
        -- Tokens other than ')' and ']' (the latter for index signatures) are here for better error recovery
        return t == Kind.CloseParenToken or t == Kind.CloseBracketToken --[[|| token == ast.KindOpenBraceToken]]
    elseif kind == PC.PCTypeArguments then
        -- All other tokens should cause the type-argument to terminate except comma token
        return t ~= Kind.CommaToken
    elseif kind == PC.PCHeritageClauses then
        return t == Kind.OpenBraceToken or t == Kind.CloseBraceToken
    elseif kind == PC.PCJsxAttributes then
        return t == Kind.GreaterThanToken or t == Kind.SlashToken
    elseif kind == PC.PCJsxChildren then
        return t == Kind.LessThanToken and p:lookAhead(Parser.nextTokenIsSlash)
    end
    return false
end

function Parser:parseExpectedJSDoc(kind)
    if self.token == kind then
        self:nextTokenJSDoc()
        return true
    end
    if not parser.isKeywordOrPunctuation(kind) then
        error("Invalid JSDoc kind: expected keyword or punctuation", 0)
    end
    self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(kind))
    return false
end

function Parser:parseExpectedMatchingBrackets(openKind, closeKind, openParsed, openPosition)
    if self.token == closeKind then
        self:nextToken()
        return
    end
    local lastError = self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(closeKind))
    if not openParsed then
        return
    end
    if lastError ~= nil then
        local related = ast.NewDiagnostic(nil, core.NewTextRange(openPosition, openPosition), diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here, scanner.TokenToString(openKind), scanner.TokenToString(closeKind))
        lastError:AddRelatedInfo(related)
    end
end

function Parser:parseOptional(token)
    if self.token == token then
        self:nextToken()
        return true
    end
    return false
end

function Parser:parseExpected(kind)
    return self:parseExpectedWithDiagnostic(kind, nil, true)
end

function Parser:parseExpectedWithoutAdvancing(kind)
    return self:parseExpectedWithDiagnostic(kind, nil, false)
end

function Parser:parseExpectedWithDiagnostic(kind, message, shouldAdvance)
    if self.token == kind then
        if shouldAdvance then
            self:nextToken()
        end
        return true
    end
    -- Report specific message if provided with one.  Otherwise, report generic fallback message.
    if message ~= nil then
        self:parseErrorAtCurrentToken(message)
    else
        self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(kind))
    end
    return false
end

function Parser:parseTokenNode()
    local pos = self:nodePos()
    local kind = self.token
    self:nextToken()
    return self:finishNode(self.factory:NewToken(kind), pos)
end

function Parser:parseExpectedToken(kind)
    local token = self:parseOptionalToken(kind)
    if token == nil then
        self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(kind))
        token = self:finishNode(self.factory:NewToken(kind), self:nodePos())
    end
    return token
end

function Parser:parseOptionalToken(kind)
    if self.token == kind then
        return self:parseTokenNode()
    end
    return nil
end

function Parser:parseExpectedTokenJSDoc(kind)
    local optional = self:parseOptionalTokenJSDoc(kind)
    if optional == nil then
        if not parser.isKeywordOrPunctuation(kind) then
            error("expected keyword or punctuation", 0)
        end
        self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(kind))
        optional = self:finishNode(self.factory:NewToken(kind), self:nodePos())
    end
    return optional
end

function Parser:parseOptionalTokenJSDoc(kind)
    if self.token == kind then
        return self:parseTokenNode()
    end
    return nil
end

function Parser:parseStatement()
    local p = self
    local t = p.token
    if t == Kind.SemicolonToken then
        return p:parseEmptyStatement()
    elseif t == Kind.OpenBraceToken then
        return p:parseBlock(false --[[ignoreMissingOpenBrace]], nil)
    elseif t == Kind.VarKeyword then
        return p:parseVariableStatement(p:nodePos(), p:jsdocScannerInfo(), nil --[[modifiers]])
    elseif t == Kind.LetKeyword then
        if p:isLetDeclaration() then
            return p:parseVariableStatement(p:nodePos(), p:jsdocScannerInfo(), nil --[[modifiers]])
        end
    elseif t == Kind.AwaitKeyword then
        if p:isAwaitUsingDeclaration() then
            return p:parseVariableStatement(p:nodePos(), p:jsdocScannerInfo(), nil --[[modifiers]])
        end
    elseif t == Kind.UsingKeyword then
        if p:isUsingDeclaration() then
            return p:parseVariableStatement(p:nodePos(), p:jsdocScannerInfo(), nil --[[modifiers]])
        end
    elseif t == Kind.FunctionKeyword then
        return p:parseFunctionDeclaration(p:nodePos(), p:jsdocScannerInfo(), nil --[[modifiers]])
    elseif t == Kind.ClassKeyword then
        return p:parseClassDeclaration(p:nodePos(), p:jsdocScannerInfo(), nil --[[modifiers]])
    elseif t == Kind.IfKeyword then
        return p:parseIfStatement()
    elseif t == Kind.DoKeyword then
        return p:parseDoStatement()
    elseif t == Kind.WhileKeyword then
        return p:parseWhileStatement()
    elseif t == Kind.ForKeyword then
        return p:parseForOrForInOrForOfStatement()
    elseif t == Kind.ContinueKeyword then
        return p:parseContinueStatement()
    elseif t == Kind.BreakKeyword then
        return p:parseBreakStatement()
    elseif t == Kind.ReturnKeyword then
        return p:parseReturnStatement()
    elseif t == Kind.WithKeyword then
        return p:parseWithStatement()
    elseif t == Kind.SwitchKeyword then
        return p:parseSwitchStatement()
    elseif t == Kind.ThrowKeyword then
        return p:parseThrowStatement()
    elseif t == Kind.TryKeyword or t == Kind.CatchKeyword or t == Kind.FinallyKeyword then
        return p:parseTryStatement()
    elseif t == Kind.DebuggerKeyword then
        return p:parseDebuggerStatement()
    elseif t == Kind.AtToken then
        return p:parseDeclaration()
    elseif t == Kind.AsyncKeyword or t == Kind.InterfaceKeyword or t == Kind.TypeKeyword or t == Kind.ModuleKeyword or t == Kind.NamespaceKeyword or
        t == Kind.DeclareKeyword or t == Kind.ConstKeyword or t == Kind.EnumKeyword or t == Kind.ExportKeyword or t == Kind.ImportKeyword or
        t == Kind.PrivateKeyword or t == Kind.ProtectedKeyword or t == Kind.PublicKeyword or t == Kind.AbstractKeyword or t == Kind.AccessorKeyword or
        t == Kind.StaticKeyword or t == Kind.ReadonlyKeyword or t == Kind.GlobalKeyword then
        if p:isStartOfDeclaration() then
            return p:parseDeclaration()
        end
    end
    return p:parseExpressionOrLabeledStatement()
end

function Parser:parseDeclaration()
    local p = self
    -- `parseListElement` attempted to get the reused node at this position,
    -- but the ambient context flag was not yet set, so the node appeared
    -- not reusable in that context.
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local modifiers = p:parseModifiersEx(true --[[allowDecorators]], false --[[permitConstAsModifier]], false --[[stopOnStartOfClassStaticBlock]])
    local isAmbient = modifiers ~= nil and core.Some(modifiers.nodes, parser.isDeclareModifier)
    if isAmbient then
        -- !!! incremental parsing
        -- node := p.tryReuseAmbientDeclaration(pos)
        -- if node {
        -- 	return node
        -- }
        for _, m in ipairs(modifiers.nodes) do
            m.flags = m.flags | NodeFlags.Ambient
        end
        local saveContextFlags = p.contextFlags
        p:setContextFlags(NodeFlags.Ambient, true)
        local result = p:parseDeclarationWorker(pos, jsdoc, modifiers)
        p.contextFlags = saveContextFlags
        return result
    else
        return p:parseDeclarationWorker(pos, jsdoc, modifiers)
    end
end

function Parser:parseDeclarationWorker(pos, jsdoc, modifiers)
    local p = self
    local t = p.token
    if t == Kind.VarKeyword or t == Kind.LetKeyword or t == Kind.ConstKeyword or t == Kind.UsingKeyword then
        return p:parseVariableStatement(pos, jsdoc, modifiers)
    elseif t == Kind.AwaitKeyword then
        if p:isAwaitUsingDeclaration() then
            return p:parseVariableStatement(pos, jsdoc, modifiers)
        end
    elseif t == Kind.FunctionKeyword then
        return p:parseFunctionDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.ClassKeyword then
        return p:parseClassDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.InterfaceKeyword then
        return p:parseInterfaceDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.TypeKeyword then
        return p:parseTypeAliasDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.EnumKeyword then
        return p:parseEnumDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.GlobalKeyword or t == Kind.ModuleKeyword or t == Kind.NamespaceKeyword then
        return p:parseModuleDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.ImportKeyword then
        return p:parseImportDeclarationOrImportEqualsDeclaration(pos, jsdoc, modifiers)
    elseif t == Kind.ExportKeyword then
        p:nextToken()
        if p.token == Kind.DefaultKeyword or p.token == Kind.EqualsToken then
            return p:parseExportAssignment(pos, jsdoc, modifiers)
        elseif p.token == Kind.AsKeyword then
            return p:parseNamespaceExportDeclaration(pos, jsdoc, modifiers)
        else
            return p:parseExportDeclaration(pos, jsdoc, modifiers)
        end
    end
    if modifiers ~= nil then
        -- We reached this point because we encountered decorators and/or modifiers and assumed a declaration
        -- would follow. For recovery and error reporting purposes, return an incomplete declaration.
        p:parseErrorAt(p:nodePos(), p:nodePos(), diagnostics.Declaration_expected)
        return p:finishNode(p.factory:NewMissingDeclaration(modifiers), pos)
    end
    error("Unhandled case in parseDeclarationWorker", 0)
end

function parser.isDeclareModifier(modifier)
    return modifier.kind == Kind.DeclareKeyword
end

function Parser:isLetDeclaration()
    -- In ES6 'let' always starts a lexical declaration if followed by an identifier or {
    -- or [.
    return self:lookAhead(Parser.nextTokenIsBindingIdentifierOrStartOfDestructuring)
end

function Parser:nextTokenIsBindingIdentifierOrStartOfDestructuring()
    self:nextToken()
    return self:isBindingIdentifier() or self.token == Kind.OpenBraceToken or self.token == Kind.OpenBracketToken
end

function Parser:parseBlock(ignoreMissingOpenBrace, diagnosticMessage)
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local openBracePosition = p.scanner:TokenStart()
    local openBraceParsed = p:parseExpectedWithDiagnostic(Kind.OpenBraceToken, diagnosticMessage, true --[[shouldAdvance]])
    local multiline = false
    if openBraceParsed or ignoreMissingOpenBrace then
        multiline = p:hasPrecedingLineBreak()
        local statements = p:parseList(PC.PCBlockStatements, Parser.parseStatement)
        p:parseExpectedMatchingBrackets(Kind.OpenBraceToken, Kind.CloseBraceToken, openBraceParsed, openBracePosition)
        local result = p:finishNode(p.factory:NewBlock(statements, multiline), pos)
        p:withJSDoc(result, jsdoc)
        if p.token == Kind.EqualsToken then
            p:parseErrorAtCurrentToken(diagnostics.Declaration_or_statement_expected_This_follows_a_block_of_statements_so_if_you_intended_to_write_a_destructuring_assignment_you_might_need_to_wrap_the_whole_assignment_in_parentheses)
            p:nextToken()
        end
        return result
    end
    local result = p:finishNode(p.factory:NewBlock(p:createMissingList(), multiline), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseEmptyStatement()
    local pos = self:nodePos()
    local jsdoc = self:jsdocScannerInfo()
    self:parseExpected(Kind.SemicolonToken)
    local result = self:finishNode(self.factory:NewEmptyStatement(), pos)
    self:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseIfStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.IfKeyword)
    local openParenPosition = p.scanner:TokenStart()
    local openParenParsed = p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseExpressionAllowIn()
    p:parseExpectedMatchingBrackets(Kind.OpenParenToken, Kind.CloseParenToken, openParenParsed, openParenPosition)
    local thenStatement = p:parseStatement()
    local elseStatement = nil
    if p:parseOptional(Kind.ElseKeyword) then
        elseStatement = p:parseStatement()
    end
    local result = p:finishNode(p.factory:NewIfStatement(expression, thenStatement, elseStatement), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseDoStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.DoKeyword)
    local statement = p:parseStatement()
    p:parseExpected(Kind.WhileKeyword)
    local openParenPosition = p.scanner:TokenStart()
    local openParenParsed = p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseExpressionAllowIn()
    p:parseExpectedMatchingBrackets(Kind.OpenParenToken, Kind.CloseParenToken, openParenParsed, openParenPosition)
    -- From: https://mail.mozilla.org/pipermail/es-discuss/2011-August/016188.html
    -- 157 min --- All allen at wirfs-brock.com CONF --- "do{;}while(false)false" prohibited in
    -- spec but allowed in consensus reality. Approved -- this is the de-facto standard whereby
    --  do;while(0)x will have a semicolon inserted before x.
    p:parseOptional(Kind.SemicolonToken)
    local result = p:finishNode(p.factory:NewDoStatement(statement, expression), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseWhileStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.WhileKeyword)
    local openParenPosition = p.scanner:TokenStart()
    local openParenParsed = p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseExpressionAllowIn()
    p:parseExpectedMatchingBrackets(Kind.OpenParenToken, Kind.CloseParenToken, openParenParsed, openParenPosition)
    local statement = p:parseStatement()
    local result = p:finishNode(p.factory:NewWhileStatement(expression, statement), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseForOrForInOrForOfStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.ForKeyword)
    local awaitToken = p:parseOptionalToken(Kind.AwaitKeyword)
    p:parseExpected(Kind.OpenParenToken)
    local initializer = nil
    if p.token ~= Kind.SemicolonToken then
        if p.token == Kind.VarKeyword or p.token == Kind.LetKeyword or p.token == Kind.ConstKeyword or
            p.token == Kind.UsingKeyword and p:lookAhead(Parser.nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLineDisallowOf) or
            -- this one is meant to allow of
            p.token == Kind.AwaitKeyword and p:lookAhead(Parser.nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine) then
            initializer = p:parseVariableDeclarationList(true --[[inForStatementInitializer]])
        else
            initializer = parser.doInContext(p, NodeFlags.DisallowInContext, true, Parser.parseExpression)
        end
    end
    local result
    if awaitToken ~= nil and p:parseExpected(Kind.OfKeyword) or awaitToken == nil and p:parseOptional(Kind.OfKeyword) then
        local expression = parser.doInContext(p, NodeFlags.DisallowInContext, false, Parser.parseAssignmentExpressionOrHigher)
        p:parseExpected(Kind.CloseParenToken)
        result = p.factory:NewForInOrOfStatement(Kind.ForOfStatement, awaitToken, initializer, expression, p:parseStatement())
    elseif p:parseOptional(Kind.InKeyword) then
        local expression = p:parseExpressionAllowIn()
        p:parseExpected(Kind.CloseParenToken)
        result = p.factory:NewForInOrOfStatement(Kind.ForInStatement, nil --[[awaitToken]], initializer, expression, p:parseStatement())
    else
        p:parseExpected(Kind.SemicolonToken)
        local condition = nil
        if p.token ~= Kind.SemicolonToken and p.token ~= Kind.CloseParenToken then
            condition = p:parseExpressionAllowIn()
        end
        p:parseExpected(Kind.SemicolonToken)
        local incrementor = nil
        if p.token ~= Kind.CloseParenToken then
            incrementor = p:parseExpressionAllowIn()
        end
        p:parseExpected(Kind.CloseParenToken)
        result = p.factory:NewForStatement(initializer, condition, incrementor, p:parseStatement())
    end
    p:finishNode(result, pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseBreakStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.BreakKeyword)
    local label = p:parseIdentifierUnlessAtSemicolon()
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewBreakStatement(label), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseContinueStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.ContinueKeyword)
    local label = p:parseIdentifierUnlessAtSemicolon()
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewContinueStatement(label), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseIdentifierUnlessAtSemicolon()
    if not self:canParseSemicolon() then
        return self:parseIdentifier()
    end
    return nil
end

function Parser:parseReturnStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.ReturnKeyword)
    local expression = nil
    if not p:canParseSemicolon() then
        expression = p:parseExpressionAllowIn()
    end
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewReturnStatement(expression), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseWithStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.WithKeyword)
    local openParenPosition = p.scanner:TokenStart()
    local openParenParsed = p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseExpressionAllowIn()
    p:parseExpectedMatchingBrackets(Kind.OpenParenToken, Kind.CloseParenToken, openParenParsed, openParenPosition)
    local statement = parser.doInContext(p, NodeFlags.InWithStatement, true, Parser.parseStatement)
    local result = p:finishNode(p.factory:NewWithStatement(expression, statement), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseCaseClause()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.CaseKeyword)
    local expression = p:parseExpressionAllowIn()
    p:parseExpected(Kind.ColonToken)
    local statements = p:parseList(PC.PCSwitchClauseStatements, Parser.parseStatement)
    local result = p:finishNode(p.factory:NewCaseOrDefaultClause(Kind.CaseClause, expression, statements), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseDefaultClause()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.DefaultKeyword)
    p:parseExpected(Kind.ColonToken)
    local statements = p:parseList(PC.PCSwitchClauseStatements, Parser.parseStatement)
    local result = p:finishNode(p.factory:NewCaseOrDefaultClause(Kind.DefaultClause, nil --[[expression]], statements), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseCaseOrDefaultClause()
    if self.token == Kind.CaseKeyword then
        return self:parseCaseClause()
    end
    return self:parseDefaultClause()
end

function Parser:parseCaseBlock()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.OpenBraceToken)
    local clauses = p:parseList(PC.PCSwitchClauses, Parser.parseCaseOrDefaultClause)
    p:parseExpected(Kind.CloseBraceToken)
    local result = p:finishNode(p.factory:NewCaseBlock(clauses), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseSwitchStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.SwitchKeyword)
    p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseExpressionAllowIn()
    p:parseExpected(Kind.CloseParenToken)
    local caseBlock = p:parseCaseBlock()
    local result = p:finishNode(p.factory:NewSwitchStatement(expression, caseBlock), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseThrowStatement()
    local p = self
    -- ThrowStatement[Yield] :
    --      throw [no LineTerminator here]Expression[In, ?Yield];
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.ThrowKeyword)
    -- Because of automatic semicolon insertion, we need to report error if this
    -- throw could be terminated with a semicolon.  Note: we can't call 'parseExpression'
    -- directly as that might consume an expression on the following line.
    -- Instead, we create a "missing" identifier, but don't report an error. The actual error
    -- will be reported in the grammar walker.
    local expression
    if not p:hasPrecedingLineBreak() then
        expression = p:parseExpressionAllowIn()
    else
        expression = p:createMissingIdentifier()
    end
    if not p:tryParseSemicolon() then
        p:parseErrorForMissingSemicolonAfter(expression)
    end
    local result = p:finishNode(p.factory:NewThrowStatement(expression), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

-- TODO: Review for error recovery
function Parser:parseTryStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.TryKeyword)
    local tryBlock = p:parseBlock(false --[[ignoreMissingOpenBrace]], nil)
    local catchClause = nil
    if p.token == Kind.CatchKeyword then
        catchClause = p:parseCatchClause()
    end
    -- If we don't have a catch clause, then we must have a finally clause.  Try to parse
    -- one out no matter what.
    local finallyBlock = nil
    if catchClause == nil or p.token == Kind.FinallyKeyword then
        p:parseExpectedWithDiagnostic(Kind.FinallyKeyword, diagnostics.X_catch_or_finally_expected, true --[[shouldAdvance]])
        finallyBlock = p:parseBlock(false --[[ignoreMissingOpenBrace]], nil)
    end
    local result = p:finishNode(p.factory:NewTryStatement(tryBlock, catchClause, finallyBlock), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseCatchClause()
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.CatchKeyword)
    local variableDeclaration = nil
    if p:parseOptional(Kind.OpenParenToken) then
        variableDeclaration = p:parseVariableDeclaration()
        p:parseExpected(Kind.CloseParenToken)
    end
    local block = p:parseBlock(false --[[ignoreMissingOpenBrace]], nil)
    local result = p:finishNode(p.factory:NewCatchClause(variableDeclaration, block), pos)
    return result
end

function Parser:parseDebuggerStatement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.DebuggerKeyword)
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewDebuggerStatement(), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseExpressionOrLabeledStatement()
    local p = self
    -- Avoiding having to do the lookahead for a labeled statement by just trying to parse
    -- out an expression, seeing if it is identifier and then seeing if it is followed by
    -- a colon.
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local hasParen = p.token == Kind.OpenParenToken
    local expression = p:parseExpression()

    if expression.kind == Kind.Identifier and p:parseOptional(Kind.ColonToken) then
        local result = p:finishNode(p.factory:NewLabeledStatement(expression, p:parseStatement()), pos)
        p:withJSDoc(result, jsdoc)
        return result
    end

    if not p:tryParseSemicolon() then
        p:parseErrorForMissingSemicolonAfter(expression)
    end
    local result = p:finishNode(p.factory:NewExpressionStatement(expression), pos)
    if hasParen then
        jsdoc = jsdoc & ~jsdocScannerInfoHasJSDoc
    end
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseVariableStatement(pos, jsdoc, modifiers)
    local p = self
    local declarationList = p:parseVariableDeclarationList(false --[[inForStatementInitializer]])
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewVariableStatement(modifiers, declarationList), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseVariableDeclarationList(inForStatementInitializer)
    local p = self
    local pos = p:nodePos()
    local flags = 0
    local t = p.token
    if t == Kind.VarKeyword then
        flags = NodeFlags.None
    elseif t == Kind.LetKeyword then
        flags = NodeFlags.Let
    elseif t == Kind.ConstKeyword then
        flags = NodeFlags.Const
    elseif t == Kind.UsingKeyword then
        flags = NodeFlags.Using
    elseif t == Kind.AwaitKeyword then
        if p:isAwaitUsingDeclaration() then
            flags = NodeFlags.AwaitUsing
            p:nextToken()
        end
    else
        error("Unhandled case in parseVariableDeclarationList", 0)
    end
    p:nextToken()
    -- The user may have written the following:
    --
    --    for (let of X) { }
    --
    -- In this case, we want to parse an empty declaration list, and then parse 'of'
    -- as a keyword. The reason this is not automatic is that 'of' is a valid identifier.
    -- So we need to look ahead to determine if 'of' should be treated as a keyword in
    -- this context.
    -- The checker will then give an error that there is an empty declaration list.
    local declarations
    if p.token == Kind.OfKeyword and p:lookAhead(Parser.nextIsIdentifierAndCloseParen) then
        declarations = p:createMissingList()
    else
        local saveContextFlags = p.contextFlags
        p:setContextFlags(NodeFlags.DisallowInContext, inForStatementInitializer)
        local parseElement
        if inForStatementInitializer then
            parseElement = Parser.parseVariableDeclaration
        else
            parseElement = Parser.parseVariableDeclarationAllowExclamation
        end
        declarations = p:parseDelimitedList(PC.PCVariableDeclarations, parseElement)
        p.contextFlags = saveContextFlags
    end
    local result = p:finishNode(p.factory:NewVariableDeclarationList(declarations, flags), pos)
    return result
end

function Parser:nextIsIdentifierAndCloseParen()
    return self:nextTokenIsIdentifier() and self:nextToken() == Kind.CloseParenToken
end

function Parser:nextTokenIsIdentifier()
    self:nextToken()
    return self:isIdentifier()
end

function Parser:parseVariableDeclaration()
    return self:parseVariableDeclarationWorker(false --[[allowExclamation]])
end

function Parser:parseVariableDeclarationAllowExclamation()
    return self:parseVariableDeclarationWorker(true --[[allowExclamation]])
end

function Parser:parseVariableDeclarationWorker(allowExclamation)
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local name = p:parseIdentifierOrPatternWithDiagnostic(diagnostics.Private_identifiers_are_not_allowed_in_variable_declarations)
    local exclamationToken = nil
    if allowExclamation and name.kind == Kind.Identifier and p.token == Kind.ExclamationToken and not p:hasPrecedingLineBreak() then
        exclamationToken = p:parseTokenNode()
    end
    local typeNode = p:parseTypeAnnotation()
    local initializer = nil
    if p.token ~= Kind.InKeyword and p.token ~= Kind.OfKeyword then
        initializer = p:parseInitializer()
    end
    local result = p:finishNode(p.factory:NewVariableDeclaration(name, exclamationToken, typeNode, initializer), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseIdentifierOrPattern()
    return self:parseIdentifierOrPatternWithDiagnostic(nil)
end

function Parser:parseIdentifierOrPatternWithDiagnostic(privateIdentifierDiagnosticMessage)
    if self.token == Kind.OpenBracketToken then
        return self:parseArrayBindingPattern()
    end
    if self.token == Kind.OpenBraceToken then
        return self:parseObjectBindingPattern()
    end
    return self:parseBindingIdentifierWithDiagnostic(privateIdentifierDiagnosticMessage)
end

function Parser:parseArrayBindingPattern()
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.OpenBracketToken)
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.DisallowInContext, false)
    local elements = p:parseDelimitedList(PC.PCArrayBindingElements, Parser.parseArrayBindingElement)
    p.contextFlags = saveContextFlags
    p:parseExpected(Kind.CloseBracketToken)
    return p:finishNode(p.factory:NewBindingPattern(Kind.ArrayBindingPattern, elements), pos)
end

function Parser:parseArrayBindingElement()
    local p = self
    local pos = p:nodePos()
    local dotDotDotToken = nil
    local name = nil
    local initializer = nil
    if p.token ~= Kind.CommaToken then
        -- These are all nil for a missing element
        dotDotDotToken = p:parseOptionalToken(Kind.DotDotDotToken)
        name = p:parseIdentifierOrPattern()
        initializer = p:parseInitializer()
    end
    return p:finishNode(p.factory:NewBindingElement(dotDotDotToken, nil --[[propertyName]], name, initializer), pos)
end

function Parser:parseObjectBindingPattern()
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.OpenBraceToken)
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.DisallowInContext, false)
    local elements = p:parseDelimitedList(PC.PCObjectBindingElements, Parser.parseObjectBindingElement)
    p.contextFlags = saveContextFlags
    p:parseExpected(Kind.CloseBraceToken)
    return p:finishNode(p.factory:NewBindingPattern(Kind.ObjectBindingPattern, elements), pos)
end

function Parser:parseObjectBindingElement()
    local p = self
    local pos = p:nodePos()
    local dotDotDotToken = p:parseOptionalToken(Kind.DotDotDotToken)
    local tokenIsIdentifier = p:isBindingIdentifier()
    local propertyName = p:parsePropertyName()
    local name
    if tokenIsIdentifier and p.token ~= Kind.ColonToken then
        name = propertyName
        propertyName = nil
    else
        p:parseExpected(Kind.ColonToken)
        name = p:parseIdentifierOrPattern()
    end
    local initializer = p:parseInitializer()
    return p:finishNode(p.factory:NewBindingElement(dotDotDotToken, propertyName, name, initializer), pos)
end

function Parser:parseInitializer()
    if self:parseOptional(Kind.EqualsToken) then
        return self:parseAssignmentExpressionOrHigher()
    end
    return nil
end

function Parser:parseTypeAnnotation()
    if self:parseOptional(Kind.ColonToken) then
        return self:parseType()
    end
    return nil
end

local ParseFlags = parser.ParseFlags

function Parser:parseFunctionDeclaration(pos, jsdoc, modifiers)
    local p = self
    p:parseExpected(Kind.FunctionKeyword)
    local asteriskToken = p:parseOptionalToken(Kind.AsteriskToken)
    -- We don't parse the name here in await context, instead we will report a grammar error in the checker.
    local name = nil
    if modifiers == nil or modifiers.modifierFlags & ModifierFlags.Default == 0 or p:isBindingIdentifier() then
        name = p:parseBindingIdentifier()
    end
    local signatureFlags = (asteriskToken ~= nil and ParseFlags.Yield or ParseFlags.None) |
        ((modifiers ~= nil and modifiers.modifierFlags & ModifierFlags.Async ~= 0) and ParseFlags.Await or ParseFlags.None)
    local typeParameters = p:parseTypeParameters()
    local saveContextFlags = p.contextFlags
    if modifiers ~= nil and modifiers.modifierFlags & ModifierFlags.Export ~= 0 then
        p:setContextFlags(NodeFlags.AwaitContext, true)
    end
    local parameters = p:parseParameters(signatureFlags)
    local returnType = p:parseReturnType(Kind.ColonToken, false --[[isType]])
    local body = p:parseFunctionBlockOrSemicolon(signatureFlags, diagnostics.X_or_expected)
    p.contextFlags = saveContextFlags
    local result = p:finishNode(p.factory:NewFunctionDeclaration(modifiers, asteriskToken, name, typeParameters, parameters, returnType, nil --[[fullSignature]], body), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseClassDeclaration(pos, jsdoc, modifiers)
    return self:parseClassDeclarationOrExpression(pos, jsdoc, modifiers, Kind.ClassDeclaration)
end

function Parser:parseClassExpression()
    return self:parseClassDeclarationOrExpression(self:nodePos(), self:jsdocScannerInfo(), nil --[[modifiers]], Kind.ClassExpression)
end

function Parser:parseClassDeclarationOrExpression(pos, jsdoc, modifiers, kind)
    local p = self
    local saveContextFlags = p.contextFlags
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    p:parseExpected(Kind.ClassKeyword)
    -- We don't parse the name here in await context, instead we will report a grammar error in the checker.
    local name = p:parseNameOfClassDeclarationOrExpression()
    local typeParameters = p:parseTypeParameters()
    if modifiers ~= nil and
        p.parsingContexts & (1 << PC.PCSourceElements) ~= 0 and
        p.parsingContexts & ((1 << PC.PCBlockStatements) | (1 << PC.PCSwitchClauseStatements)) == 0 and
        core.Some(modifiers.nodes, parser.isExportModifier) then
        p:setContextFlags(NodeFlags.AwaitContext, true --[[value]])
    end
    local heritageClauses = p:parseHeritageClauses(false --[[isInterface]])
    local members
    if p:parseExpected(Kind.OpenBraceToken) then
        -- ClassTail[Yield,Await] : (Modified) See 14.5
        --      ClassHeritage[?Yield,?Await]opt { ClassBody[?Yield,?Await]opt }
        members = p:parseList(PC.PCClassMembers, Parser.parseClassElement)
        p:parseExpected(Kind.CloseBraceToken)
    else
        members = p:createMissingList()
    end
    p.contextFlags = saveContextFlags
    local result
    if modifiers ~= nil and ast.ModifiersToFlags(modifiers.nodes) & ModifierFlags.Ambient ~= 0 then
        p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    end
    if kind == Kind.ClassDeclaration then
        result = p.factory:NewClassDeclaration(modifiers, name, typeParameters, heritageClauses, members)
    else
        result = p.factory:NewClassExpression(modifiers, name, typeParameters, heritageClauses, members)
    end
    p:finishNode(result, pos)
    p:withJSDoc(result, jsdoc)
    if result.flags & NodeFlags.JavaScriptFile ~= 0 then
        p:checkJSSyntax(result)
        if heritageClauses ~= nil then
            for _, clause in ipairs(heritageClauses.nodes) do
                if clause:AsHeritageClause().token == Kind.ExtendsKeyword then
                    for _, expr in ipairs(clause:AsHeritageClause().types.nodes) do
                        p:checkJSSyntax(expr)
                    end
                end
            end
        end
    end
    return result
end

function Parser:parseNameOfClassDeclarationOrExpression()
    -- implements is a future reserved word so
    -- 'class implements' might mean either
    -- - class expression with omitted name, 'implements' starts heritage clause
    -- - class with name 'implements'
    -- 'isImplementsClause' helps to disambiguate between these two cases
    if self:isBindingIdentifier() and not self:isImplementsClause() then
        local saveHasAwaitIdentifier = self.statementHasAwaitIdentifier
        local id = self:createIdentifier(self:isBindingIdentifier())
        self.statementHasAwaitIdentifier = saveHasAwaitIdentifier
        return id
    end
    return nil
end

function Parser:isImplementsClause()
    return self.token == Kind.ImplementsKeyword and self:lookAhead(Parser.nextTokenIsIdentifierOrKeyword)
end

function parser.isExportModifier(modifier)
    return modifier.kind == Kind.ExportKeyword
end

function parser.isAsyncModifier(modifier)
    return modifier.kind == Kind.AsyncKeyword
end

function Parser:parseHeritageClauses(isInterface)
    -- ClassTail[Yield,Await] : (Modified) See 14.5
    --      ClassHeritage[?Yield,?Await]opt { ClassBody[?Yield,?Await]opt }
    if self:isHeritageClause() then
        return self:parseList(PC.PCHeritageClauses, function(p)
            return p:parseHeritageClause(isInterface)
        end)
    end
    return nil
end

function Parser:parseHeritageClause(isInterface)
    local p = self
    local pos = p:nodePos()
    local kind = p.token
    p:nextToken()
    local parseElement = Parser.parseExpressionWithTypeArguments
    if parser.isTypeHeritageClause(isInterface, kind) then
        parseElement = Parser.parseTypeHeritageClauseElement
    end
    local types = p:parseDelimitedList(PC.PCHeritageClauseElement, parseElement)
    return p:checkJSSyntax(p:finishNode(p.factory:NewHeritageClause(kind, types), pos))
end

function parser.isTypeHeritageClause(isInterface, token)
    return isInterface and token == Kind.ExtendsKeyword or
        not isInterface and token == Kind.ImplementsKeyword
end

function Parser:parseTypeHeritageClauseElement()
    local pos = self:nodePos()
    local expressionWithTypeArguments = self:parseExpressionWithTypeArguments():AsExpressionWithTypeArguments()
    if not parser.isValidHeritageTypeReferenceExpression(expressionWithTypeArguments.expression) then
        return expressionWithTypeArguments
    end
    local typeName = self:convertEntityNameExpressionToEntityName(expressionWithTypeArguments.expression)
    return self:finishNode(self.factory:NewTypeReferenceNode(typeName, expressionWithTypeArguments.typeArguments), pos)
end

function parser.isValidHeritageTypeReferenceExpression(node)
    if ast.IsIdentifier(node) then
        return ast.NodeIsPresent(node)
    end
    return ast.IsPropertyAccessExpression(node) and
        not ast.IsOptionalChain(node) and
        ast.NodeIsPresent(node:Name()) and
        parser.isValidHeritageTypeReferenceExpression(node:Expression())
end

function Parser:convertEntityNameExpressionToEntityName(node)
    if ast.IsIdentifier(node) then
        return node
    end
    local propertyAccess = node:AsPropertyAccessExpression()
    local result = self.factory:NewQualifiedName(
        self:convertEntityNameExpressionToEntityName(propertyAccess.expression),
        propertyAccess:Name()
    )
    return self:finishNodeWithEnd(result, node:Pos(), node:End())
end

function Parser:parseExpressionWithTypeArguments()
    local pos = self:nodePos()
    local expression = self:parseLeftHandSideExpressionOrHigher()
    if ast.IsExpressionWithTypeArguments(expression) then
        return expression
    end
    local typeArguments = self:parseTypeArguments()
    return self:finishNode(self.factory:NewExpressionWithTypeArguments(expression, typeArguments), pos)
end

function Parser:parseClassElement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    if p.token == Kind.SemicolonToken then
        p:nextToken()
        local result = p:finishNode(p.factory:NewSemicolonClassElement(), pos)
        p:withJSDoc(result, jsdoc)
        return result
    end
    local modifiers = p:parseModifiersEx(true --[[allowDecorators]], true --[[permitConstAsModifier]], true --[[stopOnStartOfClassStaticBlock]])
    if p.token == Kind.StaticKeyword and p:lookAhead(Parser.nextTokenIsOpenBrace) then
        return p:parseClassStaticBlockDeclaration(pos, jsdoc, modifiers)
    end
    if p:parseContextualModifier(Kind.GetKeyword) then
        return p:parseAccessorDeclaration(pos, jsdoc, modifiers, Kind.GetAccessor, ParseFlags.None)
    end
    if p:parseContextualModifier(Kind.SetKeyword) then
        return p:parseAccessorDeclaration(pos, jsdoc, modifiers, Kind.SetAccessor, ParseFlags.None)
    end
    if p.token == Kind.ConstructorKeyword or p.token == Kind.StringLiteral then
        local constructorDeclaration = p:tryParseConstructorDeclaration(pos, jsdoc, modifiers)
        if constructorDeclaration ~= nil then
            return constructorDeclaration
        end
    end
    if p:isIndexSignature() then
        return p:checkJSSyntax(p:parseIndexSignatureDeclaration(pos, jsdoc, modifiers))
    end
    -- It is very important that we check this *after* checking indexers because
    -- the [ token can start an index signature or a computed property name
    if parser.tokenIsIdentifierOrKeyword(p.token) or p.token == Kind.StringLiteral or p.token == Kind.NumericLiteral or p.token == Kind.BigIntLiteral or p.token == Kind.AsteriskToken or p.token == Kind.OpenBracketToken then
        local isAmbient = modifiers ~= nil and core.Some(modifiers.nodes, parser.isDeclareModifier)
        if isAmbient then
            for _, m in ipairs(modifiers.nodes) do
                m.flags = m.flags | NodeFlags.Ambient
            end
            local saveContextFlags = p.contextFlags
            p:setContextFlags(NodeFlags.Ambient, true)
            local result = p:parsePropertyOrMethodDeclaration(pos, jsdoc, modifiers)
            p.contextFlags = saveContextFlags
            return result
        else
            return p:parsePropertyOrMethodDeclaration(pos, jsdoc, modifiers)
        end
    end
    if modifiers ~= nil then
        -- treat this as a property declaration with a missing name.
        p:parseErrorAt(p:nodePos(), p:nodePos(), diagnostics.Declaration_expected)
        local name = p:createMissingIdentifier()
        return p:parsePropertyDeclaration(pos, jsdoc, modifiers, name, nil --[[questionToken]])
    end
    -- 'isClassMemberStart' should have hinted not to attempt parsing.
    error("Should not have attempted to parse class member declaration.", 0)
end

function Parser:parseClassStaticBlockDeclaration(pos, jsdoc, modifiers)
    self:parseExpectedToken(Kind.StaticKeyword)
    local body = self:parseClassStaticBlockBody()
    local result = self:finishNode(self.factory:NewClassStaticBlockDeclaration(modifiers, body), pos)
    self:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseClassStaticBlockBody()
    local saveContextFlags = self.contextFlags
    self:setContextFlags(NodeFlags.YieldContext, false)
    self:setContextFlags(NodeFlags.AwaitContext, true)
    local body = self:parseBlock(false --[[ignoreMissingOpenBrace]], nil --[[diagnosticMessage]])
    self.contextFlags = saveContextFlags
    return body
end

function Parser:tryParseConstructorDeclaration(pos, jsdoc, modifiers)
    local p = self
    local state = p:mark()
    if p.token == Kind.ConstructorKeyword or p.token == Kind.StringLiteral and p.scanner:TokenValue() == "constructor" and p:lookAhead(Parser.nextTokenIsOpenParen) then
        p:nextToken()
        local typeParameters = p:parseTypeParameters()
        local parameters = p:parseParameters(ParseFlags.None)
        local returnType = p:parseReturnType(Kind.ColonToken, false --[[isType]])
        local body = p:parseFunctionBlockOrSemicolon(ParseFlags.None, diagnostics.X_or_expected)
        local result = p:finishNode(p.factory:NewConstructorDeclaration(modifiers, typeParameters, parameters, returnType, nil --[[fullSignature]], body), pos)
        p:withJSDoc(result, jsdoc)
        p:checkJSSyntax(result)
        return result
    end
    p:rewind(state)
    return nil
end

function Parser:nextTokenIsOpenParen()
    return self:nextToken() == Kind.OpenParenToken
end

function Parser:parsePropertyOrMethodDeclaration(pos, jsdoc, modifiers)
    local p = self
    local asteriskToken = p:parseOptionalToken(Kind.AsteriskToken)
    local name = p:parsePropertyName()
    -- Note: this is not legal as per the grammar.  But we allow it in the parser and
    -- report an error in the grammar checker.
    local questionToken = p:parseOptionalToken(Kind.QuestionToken)
    if asteriskToken ~= nil or p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken then
        return p:parseMethodDeclaration(pos, jsdoc, modifiers, asteriskToken, name, questionToken, diagnostics.X_or_expected)
    end
    return p:parsePropertyDeclaration(pos, jsdoc, modifiers, name, questionToken)
end

function Parser:parseMethodDeclaration(pos, jsdoc, modifiers, asteriskToken, name, questionToken, diagnosticMessage)
    local p = self
    local signatureFlags = (asteriskToken ~= nil and ParseFlags.Yield or ParseFlags.None) | (parser.modifierListHasAsync(modifiers) and ParseFlags.Await or ParseFlags.None)
    local typeParameters = p:parseTypeParameters()
    local parameters = p:parseParameters(signatureFlags)
    local typeNode = p:parseReturnType(Kind.ColonToken, false --[[isType]])
    local body = p:parseFunctionBlockOrSemicolon(signatureFlags, diagnosticMessage)
    local result = p:finishNode(p.factory:NewMethodDeclaration(modifiers, asteriskToken, name, questionToken, typeParameters, parameters, typeNode, nil --[[fullSignature]], body), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function parser.modifierListHasAsync(modifiers)
    return modifiers ~= nil and core.Some(modifiers.nodes, parser.isAsyncModifier)
end

function Parser:parsePropertyDeclaration(pos, jsdoc, modifiers, name, questionToken)
    local p = self
    local postfixToken = questionToken
    if postfixToken == nil and not p:hasPrecedingLineBreak() then
        postfixToken = p:parseOptionalToken(Kind.ExclamationToken)
    end
    local typeNode = p:parseTypeAnnotation()
    local initializer = parser.doInContext(p, NodeFlags.YieldContext | NodeFlags.AwaitContext | NodeFlags.DisallowInContext, false, Parser.parseInitializer)
    p:parseSemicolonAfterPropertyName(name, typeNode, initializer)
    local result = p:finishNode(p.factory:NewPropertyDeclaration(modifiers, name, postfixToken, typeNode, initializer), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseSemicolonAfterPropertyName(name, typeNode, initializer)
    local p = self
    if p.token == Kind.AtToken and not p:hasPrecedingLineBreak() then
        p:parseErrorAtCurrentToken(diagnostics.Decorators_must_precede_the_name_and_all_keywords_of_property_declarations)
        return
    end
    if p.token == Kind.OpenParenToken then
        p:parseErrorAtCurrentToken(diagnostics.Cannot_start_a_function_call_in_a_type_annotation)
        p:nextToken()
        return
    end
    if typeNode ~= nil and not p:canParseSemicolon() then
        if initializer ~= nil then
            p:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(Kind.SemicolonToken))
        else
            p:parseErrorAtCurrentToken(diagnostics.Expected_for_property_initializer)
        end
        return
    end
    if p:tryParseSemicolon() then
        return
    end
    if initializer ~= nil then
        p:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(Kind.SemicolonToken))
        return
    end
    p:parseErrorForMissingSemicolonAfter(name)
end

function Parser:parseErrorForMissingSemicolonAfter(node)
    local p = self
    -- Tagged template literals are sometimes used in places where only simple strings are allowed, i.e.:
    --   module `M1` {
    --   ^^^^^^^^^^^ This block is parsed as a template literal like module`M1`.
    if node.kind == Kind.TaggedTemplateExpression then
        p:parseErrorAtRange(p:skipRangeTrivia(node:AsTaggedTemplateExpression().template.loc), diagnostics.Module_declaration_names_may_only_use_or_quoted_strings)
        return
    end
    -- Otherwise, if this isn't a well-known keyword-like identifier, give the generic fallback message.
    local expressionText = ""
    if node.kind == Kind.Identifier then
        expressionText = node:Text()
    end
    if expressionText == "" then
        p:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(Kind.SemicolonToken))
        return
    end
    local pos = scanner.SkipTrivia(p.sourceText, node:Pos())
    -- Some known keywords are likely signs of syntax being used improperly.
    if expressionText == "const" or expressionText == "let" or expressionText == "var" then
        p:parseErrorAt(pos, node:End(), diagnostics.Variable_declaration_not_allowed_at_this_location)
        return
    elseif expressionText == "declare" then
        -- If a declared node failed to parse, it would have emitted a diagnostic already.
        return
    elseif expressionText == "interface" then
        p:parseErrorForInvalidName(diagnostics.Interface_name_cannot_be_0, diagnostics.Interface_must_be_given_a_name, Kind.OpenBraceToken)
        return
    elseif expressionText == "is" then
        p:parseErrorAt(pos, p.scanner:TokenStart(), diagnostics.A_type_predicate_is_only_allowed_in_return_type_position_for_functions_and_methods)
        return
    elseif expressionText == "module" or expressionText == "namespace" then
        p:parseErrorForInvalidName(diagnostics.Namespace_name_cannot_be_0, diagnostics.Namespace_must_be_given_a_name, Kind.OpenBraceToken)
        return
    elseif expressionText == "type" then
        p:parseErrorForInvalidName(diagnostics.Type_alias_name_cannot_be_0, diagnostics.Type_alias_must_be_given_a_name, Kind.EqualsToken)
        return
    end
    -- The user alternatively might have misspelled or forgotten to add a space after a common keyword.
    local suggestion = core.GetSpellingSuggestionForStrings(expressionText, parser.getViableKeywordSuggestions())
    if suggestion == "" then
        suggestion = parser.getSpaceSuggestion(expressionText)
    end
    if suggestion ~= "" then
        p:parseErrorAt(pos, node:End(), diagnostics.Unknown_keyword_or_identifier_Did_you_mean_0, suggestion)
        return
    end
    -- Unknown tokens are handled with their own errors in the scanner
    if p.token == Kind.Unknown then
        return
    end
    -- Otherwise, we know this some kind of unknown word, not just a missing expected semicolon.
    p:parseErrorAt(pos, node:End(), diagnostics.Unexpected_keyword_or_identifier)
end

function parser.getSpaceSuggestion(expressionText)
    for _, keyword in ipairs(parser.getViableKeywordSuggestions()) do
        if #expressionText > #keyword + 2 and string.sub(expressionText, 1, #keyword) == keyword then
            return keyword .. " " .. string.sub(expressionText, #keyword + 1)
        end
    end
    return ""
end

function Parser:parseErrorForInvalidName(nameDiagnostic, blankDiagnostic, tokenIfBlankName)
    if self.token == tokenIfBlankName then
        self:parseErrorAtCurrentToken(blankDiagnostic)
    else
        self:parseErrorAtCurrentToken(nameDiagnostic, self.scanner:TokenValue())
    end
end

function Parser:parseInterfaceDeclaration(pos, jsdoc, modifiers)
    local p = self
    p:parseExpected(Kind.InterfaceKeyword)
    local name = p:parseIdentifier()
    local typeParameters = p:parseTypeParameters()
    local heritageClauses = p:parseHeritageClauses(true --[[isInterface]])
    local members = p:parseObjectTypeMembers()
    local result = p:finishNode(p.factory:NewInterfaceDeclaration(modifiers, name, typeParameters, heritageClauses, members), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseTypeAliasDeclaration(pos, jsdoc, modifiers)
    local p = self
    p:parseExpected(Kind.TypeKeyword)
    if p:hasPrecedingLineBreak() then
        p:parseErrorAtCurrentToken(diagnostics.Line_break_not_permitted_here)
    end
    local name = p:parseIdentifier()
    local typeParameters = p:parseTypeParameters()
    p:parseExpected(Kind.EqualsToken)
    local typeNode
    if p.token == Kind.IntrinsicKeyword and p:lookAhead(Parser.nextIsNotDot) then
        typeNode = p:parseKeywordTypeNode()
    else
        typeNode = p:parseType()
    end
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewTypeAliasDeclaration(modifiers, name, typeParameters, typeNode), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:nextIsNotDot()
    return self:nextToken() ~= Kind.DotToken
end

-- In an ambient declaration, the grammar only allows integer literals as initializers.
-- In a non-ambient declaration, the grammar allows uninitialized members only in a
-- ConstantEnumMemberSection, which starts at the beginning of an enum declaration
-- or any time an integer literal initializer is encountered.
function Parser:parseEnumMember()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local name = p:parsePropertyName()
    local initializer = parser.doInContext(p, NodeFlags.DisallowInContext, false, Parser.parseInitializer)
    local result = p:finishNode(p.factory:NewEnumMember(name, initializer), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseEnumDeclaration(pos, jsdoc, modifiers)
    local p = self
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    p:parseExpected(Kind.EnumKeyword)
    local name = p:parseIdentifier()
    local members
    if p:parseExpected(Kind.OpenBraceToken) then
        local saveContextFlags = p.contextFlags
        p:setContextFlags(NodeFlags.YieldContext | NodeFlags.AwaitContext, false)
        members = p:parseDelimitedList(PC.PCEnumMembers, Parser.parseEnumMember)
        p.contextFlags = saveContextFlags
        p:parseExpected(Kind.CloseBraceToken)
    else
        members = p:createMissingList()
    end
    local result = p:finishNode(p.factory:NewEnumDeclaration(modifiers, name, members), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return result
end

function Parser:parseModuleDeclaration(pos, jsdoc, modifiers)
    local p = self
    local keyword = Kind.ModuleKeyword
    if p.token == Kind.GlobalKeyword then
        -- global augmentation
        return p:parseAmbientExternalModuleDeclaration(pos, jsdoc, modifiers)
    elseif p:parseOptional(Kind.NamespaceKeyword) then
        keyword = Kind.NamespaceKeyword
    else
        p:parseExpected(Kind.ModuleKeyword)
        if p.token == Kind.StringLiteral then
            return p:parseAmbientExternalModuleDeclaration(pos, jsdoc, modifiers)
        end
    end
    return p:parseModuleOrNamespaceDeclaration(pos, jsdoc, modifiers, false --[[nested]], keyword)
end

function Parser:parseAmbientExternalModuleDeclaration(pos, jsdoc, modifiers)
    local p = self
    local name
    local keyword = Kind.ModuleKeyword
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    if p.token == Kind.GlobalKeyword then
        -- parse 'global' as name of global scope augmentation
        name = p:parseIdentifier()
        keyword = Kind.GlobalKeyword
    else
        -- parse string literal
        name = p:parseLiteralExpression()
    end
    local body = nil
    if p.token == Kind.OpenBraceToken then
        body = p:parseModuleBlock()
    else
        p:parseSemicolon()
    end
    local result = p:finishNode(p.factory:NewModuleDeclaration(modifiers, keyword, name, body), pos)
    p:withJSDoc(result, jsdoc)
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return result
end

function Parser:parseModuleBlock()
    local p = self
    local pos = p:nodePos()
    local statements
    if p:parseExpected(Kind.OpenBraceToken) then
        statements = p:parseList(PC.PCBlockStatements, Parser.parseStatement)
        p:parseExpected(Kind.CloseBraceToken)
    else
        statements = p:createMissingList()
    end
    return p:finishNode(p.factory:NewModuleBlock(statements), pos)
end

function Parser:parseModuleOrNamespaceDeclaration(pos, jsdoc, modifiers, nested, keyword)
    local p = self
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    local name
    if nested then
        name = p:parseIdentifierName()
    else
        name = p:parseIdentifier()
    end
    local body
    if p:parseOptional(Kind.DotToken) then
        local implicitExport = p.factory:NewModifier(Kind.ExportKeyword)
        implicitExport.loc = core.NewTextRange(p:nodePos(), p:nodePos())
        implicitExport.flags = NodeFlags.Reparsed
        local implicitModifiers = p:newModifierList(implicitExport.loc, { implicitExport })
        body = p:parseModuleOrNamespaceDeclaration(p:nodePos(), 0 --[[jsdoc]], implicitModifiers, true --[[nested]], keyword)
    else
        body = p:parseModuleBlock()
    end
    local result = p:finishNode(p.factory:NewModuleDeclaration(modifiers, keyword, name, body), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return result
end

function Parser:parseImportDeclarationOrImportEqualsDeclaration(pos, jsdoc, modifiers)
    local p = self
    p:parseExpected(Kind.ImportKeyword)
    local afterImportPos = p:nodePos()
    -- We don't parse the identifier here in await context, instead we will report a grammar error in the checker.
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    local identifier = nil
    if p:isIdentifier() then
        identifier = p:parseIdentifier()
    end
    local phaseModifier = Kind.Unknown
    if identifier ~= nil and identifier:Text() == "type" and
        (p.token ~= Kind.FromKeyword or p:isIdentifier() and p:lookAhead(Parser.nextTokenIsFromKeywordOrEqualsToken)) and
        (p:isIdentifier() or p:tokenAfterImportDefinitelyProducesImportDeclaration()) then
        phaseModifier = Kind.TypeKeyword
        identifier = nil
        if p:isIdentifier() then
            identifier = p:parseIdentifier()
        end
    elseif identifier ~= nil and identifier:Text() == "defer" then
        local shouldParseAsDeferModifier
        if p.token == Kind.FromKeyword then
            shouldParseAsDeferModifier = not p:lookAhead(Parser.nextTokenIsTokenStringLiteral)
        else
            shouldParseAsDeferModifier = p.token ~= Kind.CommaToken and p.token ~= Kind.EqualsToken
        end
        if shouldParseAsDeferModifier then
            phaseModifier = Kind.DeferKeyword
            identifier = nil
            if p:isIdentifier() then
                identifier = p:parseIdentifier()
            end
        end
    end
    if identifier ~= nil and not p:tokenAfterImportedIdentifierDefinitelyProducesImportDeclaration() and phaseModifier ~= Kind.DeferKeyword then
        local importEquals = p:checkJSSyntax(p:parseImportEqualsDeclaration(pos, jsdoc, modifiers, identifier, phaseModifier == Kind.TypeKeyword))
        p.statementHasAwaitIdentifier = saveHasAwaitIdentifier -- Import= declaration is always parsed in an Await context, no need to reparse
        return importEquals
    end
    local importClause = p:tryParseImportClause(identifier, afterImportPos, phaseModifier, false --[[skipJSDocLeadingAsterisks]])
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier -- import clause is always parsed in an Await context
    local moduleSpecifier = p:parseModuleSpecifier()
    local attributes = p:tryParseImportAttributes()
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewImportDeclaration(modifiers, importClause, moduleSpecifier, attributes), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:nextTokenIsFromKeywordOrEqualsToken()
    self:nextToken()
    return self.token == Kind.FromKeyword or self.token == Kind.EqualsToken
end

function Parser:tokenAfterImportDefinitelyProducesImportDeclaration()
    return self.token == Kind.AsteriskToken or self.token == Kind.OpenBraceToken
end

function Parser:tokenAfterImportedIdentifierDefinitelyProducesImportDeclaration()
    -- In `import id ___`, the current token decides whether to produce
    -- an ImportDeclaration or ImportEqualsDeclaration.
    return self.token == Kind.CommaToken or self.token == Kind.FromKeyword
end

function Parser:parseImportEqualsDeclaration(pos, jsdoc, modifiers, identifier, isTypeOnly)
    local p = self
    p:parseExpected(Kind.EqualsToken)
    local moduleReference = p:parseModuleReference()
    p:parseSemicolon()
    local result = p:finishNode(p.factory:NewImportEqualsDeclaration(modifiers, isTypeOnly, identifier, moduleReference), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseModuleReference()
    if self.token == Kind.RequireKeyword and self:lookAhead(Parser.nextTokenIsOpenParen) then
        return self:parseExternalModuleReference()
    end
    return self:parseEntityName(false --[[allowReservedWords]], false --[[allowPrivateName]], nil --[[diagnosticMessage]])
end

function Parser:parseExternalModuleReference()
    local p = self
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    local pos = p:nodePos()
    p:parseExpected(Kind.RequireKeyword)
    p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseModuleSpecifier()
    p:parseExpected(Kind.CloseParenToken)
    local result = p:finishNode(p.factory:NewExternalModuleReference(expression), pos)
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return result
end

function Parser:parseModuleSpecifier()
    if self.token == Kind.StringLiteral then
        return self:parseLiteralExpression()
    end
    -- We allow arbitrary expressions here, even though the grammar only allows string
    -- literals.  We check to ensure that it is only a string literal later in the grammar
    -- check pass.
    return self:parseExpression()
end

function Parser:tryParseImportClause(identifier, pos, phaseModifier, skipJSDocLeadingAsterisks)
    -- ImportDeclaration:
    --  import ImportClause from ModuleSpecifier ;
    --  import ModuleSpecifier;
    if identifier ~= nil or self.token == Kind.AsteriskToken or self.token == Kind.OpenBraceToken then
        local importClause = self:parseImportClause(identifier, pos, phaseModifier, skipJSDocLeadingAsterisks)
        self:parseExpected(Kind.FromKeyword)
        return importClause
    end
    return nil
end

function Parser:parseImportClause(identifier, pos, phaseModifier, skipJSDocLeadingAsterisks)
    local p = self
    -- ImportClause:
    --  ImportedDefaultBinding
    --  NameSpaceImport
    --  NamedImports
    --  ImportedDefaultBinding, NameSpaceImport
    --  ImportedDefaultBinding, NamedImports
    -- If there was no default import or if there is comma token after default import
    -- parse namespace or named imports
    local namedBindings = nil
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    if identifier == nil or p:parseOptional(Kind.CommaToken) then
        if skipJSDocLeadingAsterisks then
            p.scanner:SetSkipJSDocLeadingAsterisks(true)
        end
        if p.token == Kind.AsteriskToken then
            namedBindings = p:parseNamespaceImport()
        else
            namedBindings = p:parseNamedImports()
        end
        if skipJSDocLeadingAsterisks then
            p.scanner:SetSkipJSDocLeadingAsterisks(false)
        end
    end
    local result = p:finishNode(p.factory:NewImportClause(phaseModifier, identifier, namedBindings), pos)
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return result
end

function Parser:parseNamespaceImport()
    -- NameSpaceImport:
    --  * as ImportedBinding
    local pos = self:nodePos()
    self:parseExpected(Kind.AsteriskToken)
    self:parseExpected(Kind.AsKeyword)
    local name = self:parseIdentifier()
    return self:finishNode(self.factory:NewNamespaceImport(name), pos)
end

function Parser:parseNamedImports()
    local pos = self:nodePos()
    -- NamedImports:
    --  { }
    --  { ImportsList }
    --  { ImportsList, }
    local imports = self:parseBracketedList(PC.PCImportOrExportSpecifiers, Parser.parseImportSpecifier, Kind.OpenBraceToken, Kind.CloseBraceToken)
    return self:finishNode(self.factory:NewNamedImports(imports), pos)
end

function Parser:parseImportSpecifier()
    local p = self
    local pos = p:nodePos()
    local isTypeOnly, propertyName, name = p:parseImportOrExportSpecifier(Kind.ImportSpecifier)
    local identifierName
    if name.kind == Kind.Identifier then
        identifierName = name
    else
        p:parseErrorAtRange(p:skipRangeTrivia(name.loc), diagnostics.Identifier_expected)
        identifierName = p:newIdentifier("")
        p:finishNode(identifierName, name:Pos())
    end
    local result = p:checkJSSyntax(p:finishNode(p.factory:NewImportSpecifier(isTypeOnly, propertyName, identifierName), pos))
    return result
end

function Parser:parseImportOrExportSpecifier(kind)
    local p = self
    local isTypeOnly = false
    local propertyName = nil
    local name
    -- ImportSpecifier:
    --   BindingIdentifier
    --   ModuleExportName as BindingIdentifier
    -- ExportSpecifier:
    --   ModuleExportName
    --   ModuleExportName as ModuleExportName
    -- let checkIdentifierIsKeyword = isKeyword(token()) && !isIdentifier();
    -- let checkIdentifierStart = scanner.getTokenStart();
    -- let checkIdentifierEnd = scanner.getTokenEnd();
    local canParseAsKeyword = true
    local disallowKeywords = kind == Kind.ImportSpecifier
    local nameOk
    name, nameOk = p:parseModuleExportName(disallowKeywords)
    if name.kind == Kind.Identifier and name:Text() == "type" then
        -- If the first token of an import specifier is 'type', there are a lot of possibilities,
        -- especially if we see 'as' afterwards:
        --
        -- import { type } from "mod";          - isTypeOnly: false,   name: type
        -- import { type as } from "mod";       - isTypeOnly: true,    name: as
        -- import { type as as } from "mod";    - isTypeOnly: false,   name: as,    propertyName: type
        -- import { type as as as } from "mod"; - isTypeOnly: true,    name: as,    propertyName: as
        if p.token == Kind.AsKeyword then
            -- { type as ...? }
            local firstAs = p:parseIdentifierName()
            if p.token == Kind.AsKeyword then
                -- { type as as ...? }
                local secondAs = p:parseIdentifierName()
                if p:canParseModuleExportName() then
                    -- { type as as something }
                    -- { type as as "something" }
                    isTypeOnly = true
                    propertyName = firstAs
                    name, nameOk = p:parseModuleExportName(disallowKeywords)
                    canParseAsKeyword = false
                else
                    -- { type as as }
                    propertyName = name
                    name = secondAs
                    canParseAsKeyword = false
                end
            elseif p:canParseModuleExportName() then
                -- { type as something }
                -- { type as "something" }
                propertyName = name
                canParseAsKeyword = false
                name, nameOk = p:parseModuleExportName(disallowKeywords)
            else
                -- { type as }
                isTypeOnly = true
                name = firstAs
            end
        elseif p:canParseModuleExportName() then
            -- { type something ...? }
            -- { type "something" ...? }
            isTypeOnly = true
            name, nameOk = p:parseModuleExportName(disallowKeywords)
        end
    end
    if canParseAsKeyword and p.token == Kind.AsKeyword then
        propertyName = name
        p:parseExpected(Kind.AsKeyword)
        name, nameOk = p:parseModuleExportName(disallowKeywords)
    end

    if not nameOk then
        p:parseErrorAtRange(p:skipRangeTrivia(name.loc), diagnostics.Identifier_expected)
    end

    return isTypeOnly, propertyName, name
end

function Parser:canParseModuleExportName()
    return parser.tokenIsIdentifierOrKeyword(self.token) or self.token == Kind.StringLiteral
end

function Parser:parseModuleExportName(disallowKeywords)
    local nameOk = true

    if self.token == Kind.StringLiteral then
        return self:parseLiteralExpression(), nameOk
    end
    if disallowKeywords and ast.IsKeyword(self.token) and not self:isIdentifier() then
        nameOk = false
    end
    return self:parseIdentifierName(), nameOk
end

function Parser:tryParseImportAttributes()
    if self.token == Kind.WithKeyword or (self.token == Kind.AssertKeyword and not self:hasPrecedingLineBreak()) then
        if self.token == Kind.AssertKeyword then
            self:parseErrorAtCurrentToken(diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert)
        end
        return self:parseImportAttributes(self.token, false --[[skipKeyword]])
    end
    return nil
end

function Parser:parseExportAssignment(pos, jsdoc, modifiers)
    local p = self
    local saveContextFlags = p.contextFlags
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    p:setContextFlags(NodeFlags.AwaitContext, true)
    local isExportEquals = false
    if p:parseOptional(Kind.EqualsToken) then
        isExportEquals = true
    else
        p:parseExpected(Kind.DefaultKeyword)
    end
    local expression = p:parseAssignmentExpressionOrHigher()
    p:parseSemicolon()
    p.contextFlags = saveContextFlags
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    local result = p:finishNode(p.factory:NewExportAssignment(modifiers, isExportEquals, nil --[[typeNode]], expression), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseNamespaceExportDeclaration(pos, jsdoc, modifiers)
    local p = self
    p:parseExpected(Kind.AsKeyword)
    p:parseExpected(Kind.NamespaceKeyword)
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    local name = p:parseIdentifier()
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    p:parseSemicolon()
    -- NamespaceExportDeclaration nodes cannot have decorators or modifiers, we attach them here so we can report them in the grammar checker
    local result = p:finishNode(p.factory:NewNamespaceExportDeclaration(modifiers, name), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseExportDeclaration(pos, jsdoc, modifiers)
    local p = self
    local saveContextFlags = p.contextFlags
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    p:setContextFlags(NodeFlags.AwaitContext, true)
    local exportClause = nil
    local moduleSpecifier = nil
    local attributes = nil
    local isTypeOnly = p:parseOptional(Kind.TypeKeyword)
    local namespaceExportPos = p:nodePos()
    if p:parseOptional(Kind.AsteriskToken) then
        if p:parseOptional(Kind.AsKeyword) then
            exportClause = p:parseNamespaceExport(namespaceExportPos)
        end
        p:parseExpected(Kind.FromKeyword)
        moduleSpecifier = p:parseModuleSpecifier()
    else
        exportClause = p:parseNamedExports()
        -- It is not uncommon to accidentally omit the 'from' keyword. Additionally, in editing scenarios,
        -- the 'from' keyword can be parsed as a named export when the export clause is unterminated (i.e. `export { from "moduleName";`)
        -- If we don't have a 'from' keyword, see if we have a string literal such that ASI won't take effect.
        if p.token == Kind.FromKeyword or (p.token == Kind.StringLiteral and not p:hasPrecedingLineBreak()) then
            p:parseExpected(Kind.FromKeyword)
            moduleSpecifier = p:parseModuleSpecifier()
        end
    end
    if moduleSpecifier ~= nil and (p.token == Kind.WithKeyword or p.token == Kind.AssertKeyword) and not p:hasPrecedingLineBreak() then
        if p.token == Kind.AssertKeyword then
            p:parseErrorAtCurrentToken(diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert)
        end
        attributes = p:parseImportAttributes(p.token, false --[[skipKeyword]])
    end
    p:parseSemicolon()
    p.contextFlags = saveContextFlags
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    local result = p:finishNode(p.factory:NewExportDeclaration(modifiers, isTypeOnly, exportClause, moduleSpecifier, attributes), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseNamespaceExport(pos)
    local exportName = self:parseModuleExportName(false --[[disallowKeywords]])
    return self:finishNode(self.factory:NewNamespaceExport(exportName), pos)
end

function Parser:parseNamedExports()
    local pos = self:nodePos()
    -- NamedImports:
    --  { }
    --  { ImportsList }
    --  { ImportsList, }
    local exports = self:parseBracketedList(PC.PCImportOrExportSpecifiers, Parser.parseExportSpecifier, Kind.OpenBraceToken, Kind.CloseBraceToken)
    return self:finishNode(self.factory:NewNamedExports(exports), pos)
end

function Parser:parseExportSpecifier()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local isTypeOnly, propertyName, name = p:parseImportOrExportSpecifier(Kind.ExportSpecifier)
    local result = p:finishNode(p.factory:NewExportSpecifier(isTypeOnly, propertyName, name), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end
