local format = require("tslua.format")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local FindAncestorResult = ast.FindAncestorResult

-- TextRangeWithKind is a Go value struct: { loc = core.TextRange, kind = ast.Kind }. Immutable.
function format.NewTextRangeWithKind(pos, end_, kind)
    return {
        loc = core.NewTextRange(pos, end_),
        kind = kind,
    }
end

-- tokenInfo is a Go value struct: { leadingTrivia = []TextRangeWithKind, token = TextRangeWithKind,
-- trailingTrivia = []TextRangeWithKind }. Immutable.

local formattingScanner = {}
formattingScanner.__index = formattingScanner
format.formattingScanner = formattingScanner

function format.newFormattingScanner(text, languageVariant, startPos, endPos, worker)
    local scan = scanner.NewScanner()
    scan:SetSkipTrivia(false)
    scan:SetLanguageVariant(languageVariant)
    scan:SetText(text)
    scan:ResetTokenState(startPos)

    local fmtScn = setmetatable({
        s = scan,
        startPos = startPos,
        endPos = endPos,
        savedPos = 0,
        hasLastTokenInfo = false,
        lastTokenInfo = { leadingTrivia = nil, token = format.NewTextRangeWithKind(0, 0, Kind.Unknown), trailingTrivia = nil },
        lastScanAction = format.scanAction.actionScan,
        leadingTrivia = nil,
        trailingTrivia = nil,
        wasNewLine = true,
    }, formattingScanner)

    local res = worker:execute(fmtScn)

    fmtScn.hasLastTokenInfo = false
    scan:Reset()

    return res
end

function formattingScanner:advance()
    self.hasLastTokenInfo = false
    local isStarted = self.s:TokenFullStart() ~= self.startPos

    if isStarted then
        self.wasNewLine = core.Len(self.trailingTrivia) > 0 and core.LastOrNil(self.trailingTrivia).kind == Kind.NewLineTrivia
    else
        self.s:Scan()
    end

    self.leadingTrivia = nil
    self.trailingTrivia = nil

    local pos = self.s:TokenFullStart()

    -- Read leading trivia and token
    while pos < self.endPos do
        local t = self.s:Token()
        if not ast.IsTrivia(t) then
            break
        end

        -- consume leading trivia
        self.s:Scan()
        local item = format.NewTextRangeWithKind(pos, self.s:TokenFullStart(), t)

        pos = self.s:TokenFullStart()

        self.leadingTrivia = core.Append(self.leadingTrivia, item)
    end

    self.savedPos = self.s:TokenFullStart()
end

function format.shouldRescanGreaterThanToken(node)
    local k = node.kind
    if k == Kind.GreaterThanEqualsToken or
        k == Kind.GreaterThanGreaterThanEqualsToken or
        k == Kind.GreaterThanGreaterThanGreaterThanEqualsToken or
        k == Kind.GreaterThanGreaterThanGreaterThanToken or
        k == Kind.GreaterThanGreaterThanToken then
        return true
    end
    return false
end

function format.shouldRescanJsxIdentifier(node)
    if node.parent ~= nil then
        local pk = node.parent.kind
        if pk == Kind.JsxAttribute or
            pk == Kind.JsxOpeningElement or
            pk == Kind.JsxClosingElement or
            pk == Kind.JsxSelfClosingElement or
            pk == Kind.JsxNamespacedName then
            -- May parse an identifier like `module-layout`; that will be scanned as a keyword at first, but we should parse the whole thing to get an identifier.
            return ast.IsKeywordKind(node.kind) or node.kind == Kind.Identifier
        elseif pk == Kind.PropertyAccessExpression then
            -- The leftmost name of a dotted JSX tag name (e.g. `a-b` in `<a-b.c>`) may contain hyphens, so rescan it as a JSX identifier.
            return (ast.IsKeywordKind(node.kind) or node.kind == Kind.Identifier) and format.isLeftmostJsxTagName(node)
        end
    end
    return false
end

function format.isLeftmostJsxTagName(node)
    return ast.FindAncestorOrQuit(node, function(n)
        if n.parent == nil then
            return FindAncestorResult.FindAncestorQuit
        elseif ast.IsJsxTagName(n) then
            return FindAncestorResult.FindAncestorTrue
        elseif ast.IsPropertyAccessExpression(n.parent) and n.parent:Expression() == n then
            return FindAncestorResult.FindAncestorFalse
        else
            return FindAncestorResult.FindAncestorQuit
        end
    end) ~= nil
end

function formattingScanner:shouldRescanJsxText(node)
    if ast.IsJsxText(node) then
        return true
    end
    if not ast.IsJsxElement(node) or self.hasLastTokenInfo == false then
        return false
    end

    return self.lastTokenInfo.token.kind == Kind.JsxText
end

function format.shouldRescanSlashToken(container)
    return container.kind == Kind.RegularExpressionLiteral
end

function format.shouldRescanTemplateToken(container)
    return container.kind == Kind.TemplateMiddle or
        container.kind == Kind.TemplateTail
end

function format.shouldRescanJsxAttributeValue(node)
    return node.parent ~= nil and ast.IsJsxAttribute(node.parent) and node.parent:Initializer() == node
end

function format.startsWithSlashToken(t)
    return t == Kind.SlashToken or t == Kind.SlashEqualsToken
end

format.scanAction = {
    actionScan = 0,
    actionRescanGreaterThanToken = 1,
    actionRescanSlashToken = 2,
    actionRescanTemplateToken = 3,
    actionRescanJsxIdentifier = 4,
    actionRescanJsxText = 5,
    actionRescanJsxAttributeValue = 6,
}
local scanAction = format.scanAction

function format.fixTokenKind(tokenInfo, container)
    if ast.IsTokenKind(container.kind) and tokenInfo.token.kind ~= container.kind then
        return {
            leadingTrivia = tokenInfo.leadingTrivia,
            token = { loc = tokenInfo.token.loc, kind = container.kind },
            trailingTrivia = tokenInfo.trailingTrivia,
        }
    end
    return tokenInfo
end

function formattingScanner:readTokenInfo(n)
    debug.Assert(self:isOnToken())

    -- normally scanner returns the smallest available token
    -- check the kind of context node to determine if scanner should have more greedy behavior and consume more text.

    local expectedScanAction
    if format.shouldRescanGreaterThanToken(n) then
        expectedScanAction = scanAction.actionRescanGreaterThanToken
    elseif format.shouldRescanSlashToken(n) then
        expectedScanAction = scanAction.actionRescanSlashToken
    elseif format.shouldRescanTemplateToken(n) then
        expectedScanAction = scanAction.actionRescanTemplateToken
    elseif format.shouldRescanJsxIdentifier(n) then
        expectedScanAction = scanAction.actionRescanJsxIdentifier
    elseif self:shouldRescanJsxText(n) then
        expectedScanAction = scanAction.actionRescanJsxText
    elseif format.shouldRescanJsxAttributeValue(n) then
        expectedScanAction = scanAction.actionRescanJsxAttributeValue
    else
        expectedScanAction = scanAction.actionScan
    end

    if self.hasLastTokenInfo and expectedScanAction == self.lastScanAction then
        -- readTokenInfo was called before with the same expected scan action.
        -- No need to re-scan text, return existing 'lastTokenInfo'
        -- it is ok to call fixTokenKind here since it does not affect
        -- what portion of text is consumed. In contrast rescanning can change it,
        -- i.e. for '>=' when originally scanner eats just one character
        -- and rescanning forces it to consume more.
        self.lastTokenInfo = format.fixTokenKind(self.lastTokenInfo, n)
        return self.lastTokenInfo
    end

    if self.s:TokenFullStart() ~= self.savedPos then
        -- readTokenInfo was called before but scan action differs - rescan text
        self.s:ResetTokenState(self.savedPos)
        self.s:Scan()
    end

    local currentToken = self:getNextToken(n, expectedScanAction)

    local token = format.NewTextRangeWithKind(
        self.s:TokenFullStart(),
        self.s:TokenEnd(),
        currentToken
    )

    -- consume trailing trivia
    self.trailingTrivia = nil
    while self.s:TokenFullStart() < self.endPos do
        currentToken = self.s:Scan()
        if not ast.IsTrivia(currentToken) then
            break
        end
        local trivia = format.NewTextRangeWithKind(
            self.s:TokenFullStart(),
            self.s:TokenEnd(),
            currentToken
        )

        self.trailingTrivia = core.Append(self.trailingTrivia, trivia)

        if currentToken == Kind.NewLineTrivia then
            -- move past new line
            self.s:Scan()
            break
        end
    end

    self.hasLastTokenInfo = true
    self.lastTokenInfo = {
        leadingTrivia = self.leadingTrivia ~= nil and core.Slice(self.leadingTrivia) or nil,
        token = token,
        trailingTrivia = self.trailingTrivia ~= nil and core.Slice(self.trailingTrivia) or nil,
    }
    self.lastTokenInfo = format.fixTokenKind(self.lastTokenInfo, n)

    return self.lastTokenInfo
end

function formattingScanner:getNextToken(n, expectedScanAction)
    local token = self.s:Token()
    self.lastScanAction = scanAction.actionScan
    if expectedScanAction == scanAction.actionRescanGreaterThanToken then
        if token == Kind.GreaterThanToken then
            self.lastScanAction = scanAction.actionRescanGreaterThanToken
            local newToken = self.s:ReScanGreaterThanToken()
            debug.Assert(n.kind == newToken)
            return newToken
        end
    elseif expectedScanAction == scanAction.actionRescanSlashToken then
        if format.startsWithSlashToken(token) then
            self.lastScanAction = scanAction.actionRescanSlashToken
            local newToken = self.s:ReScanSlashToken()
            debug.Assert(n.kind == newToken)
            return newToken
        end
    elseif expectedScanAction == scanAction.actionRescanTemplateToken then
        if token == Kind.CloseBraceToken then
            self.lastScanAction = scanAction.actionRescanTemplateToken
            return self.s:ReScanTemplateToken(false --[[isTaggedTemplate]])
        end
    elseif expectedScanAction == scanAction.actionRescanJsxIdentifier then
        self.lastScanAction = scanAction.actionRescanJsxIdentifier
        return self.s:ScanJsxIdentifier()
    elseif expectedScanAction == scanAction.actionRescanJsxText then
        self.lastScanAction = scanAction.actionRescanJsxText
        return self.s:ReScanJsxToken(false --[[allowMultilineJsxText]])
    elseif expectedScanAction == scanAction.actionRescanJsxAttributeValue then
        self.lastScanAction = scanAction.actionRescanJsxAttributeValue
        return self.s:ReScanJsxAttributeValue()
    elseif expectedScanAction == scanAction.actionScan then -- luacheck: ignore 542
    else
        debug.AssertNever(expectedScanAction, "unhandled scan action kind")
    end
    return token
end

function formattingScanner:readEOFTokenRange()
    debug.Assert(self:isOnEOF())
    return format.NewTextRangeWithKind(
        self.s:TokenFullStart(),
        self.s:TokenEnd(),
        Kind.EndOfFile
    )
end

function formattingScanner:isOnToken()
    local current = self.s:Token()
    if self.hasLastTokenInfo then
        current = self.lastTokenInfo.token.kind
    end
    return current ~= Kind.EndOfFile and not ast.IsTrivia(current)
end

function formattingScanner:isOnEOF()
    local current = self.s:Token()
    if self.hasLastTokenInfo then
        current = self.lastTokenInfo.token.kind
    end
    return current == Kind.EndOfFile
end

function formattingScanner:skipToEndOf(r)
    self.s:ResetTokenState(r:End())
    self.savedPos = self.s:TokenFullStart()
    self.lastScanAction = scanAction.actionScan
    self.hasLastTokenInfo = false
    self.wasNewLine = false
    self.leadingTrivia = nil
    self.trailingTrivia = nil
end

function formattingScanner:skipToStartOf(r)
    self.s:ResetTokenState(r:Pos())
    self.savedPos = self.s:TokenFullStart()
    self.lastScanAction = scanAction.actionScan
    self.hasLastTokenInfo = false
    self.wasNewLine = false
    self.leadingTrivia = nil
    self.trailingTrivia = nil
end

function formattingScanner:getCurrentLeadingTrivia()
    return self.leadingTrivia
end

function formattingScanner:lastTrailingTriviaWasNewLine()
    return self.wasNewLine
end

function formattingScanner:getTokenFullStart()
    if self.hasLastTokenInfo then
        return self.lastTokenInfo.token.loc:Pos()
    end
    return self.s:TokenFullStart()
end

function formattingScanner:getStartPos() -- TODO: redundant?
    return self:getTokenFullStart()
end
