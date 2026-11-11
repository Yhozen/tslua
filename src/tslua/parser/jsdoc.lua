local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local PC = parser.ParsingContext
local Parser = parser.Parser

local function copyStrings(xs)
    local r = {}
    for i, x in ipairs(xs) do
        r[i] = x
    end
    return r
end

-- Go strings.TrimRightFunc(s, f) for a rune predicate.
local function trimRightFunc(s, f)
    local pos = 0
    local keep = 0
    local n = #s
    while pos < n do
        local ch, size = stringutil.DecodeRune(s, pos)
        pos = pos + size
        if not f(ch) then
            keep = pos
        end
    end
    return string.sub(s, 1, keep)
end
parser.trimRightFunc = trimRightFunc

-- parseJSDocForNode lazily parses JSDoc for a node in a TS file.
-- Called on first access to Node.JSDoc() for non-JS source files.
function parser.parseJSDocForNode(sourceFile, node)
    local p = parser.getParser()
    p:initializeState(sourceFile:ParseOptions(), sourceFile:Text(), sourceFile.scriptKind)
    local ranges = parser.GetJSDocCommentRanges(p.factory, nil, node, sourceFile:Text())
    if #ranges == 0 then
        return nil
    end
    local jsdoc = {}
    local pos = node:Pos()
    for _, comment in ipairs(ranges) do
        local parsed = p:parseJSDocComment(node, comment:Pos(), comment:End(), pos)
        if parsed ~= nil then
            parsed.parent = node
            jsdoc[#jsdoc + 1] = parsed
            pos = parsed:End()
        end
    end
    return jsdoc
end

ast.SetParseJSDocForNode(parser.parseJSDocForNode)

-- jsdocState (unexported Go enum)
parser.jsdocStateBeginningOfLine = 0
parser.jsdocStateSawAsterisk = 1
parser.jsdocStateSavingComments = 2
parser.jsdocStateSavingBackticks = 3

-- propertyLikeParse (unexported Go enum)
parser.propertyLikeParseProperty = 1 << 0
parser.propertyLikeParseParameter = 1 << 1
parser.propertyLikeParseCallbackParameter = 1 << 2

local BeginningOfLine = parser.jsdocStateBeginningOfLine
local SawAsterisk = parser.jsdocStateSawAsterisk
local SavingComments = parser.jsdocStateSavingComments
local SavingBackticks = parser.jsdocStateSavingBackticks

function Parser:withJSDoc(node, info)
    local p = self
    if info & parser.jsdocScannerInfoHasJSDoc == 0 then
        return nil
    end

    -- For TS/TSX files, defer JSDoc parsing to first access, unless the comment
    -- contains @see/@link (needed for unused-identifier checks).
    -- @deprecated is detected via cheap text scan to set PossiblyContainsDeprecatedTag;
    -- callers must confirm via JSDoc lookup.
    if not p:isJavaScript() then
        node.flags = node.flags | NodeFlags.HasJSDoc
        if info & parser.jsdocScannerInfoHasDeprecated ~= 0 then
            node.flags = node.flags | NodeFlags.PossiblyContainsDeprecatedTag
        end
        if info & parser.jsdocScannerInfoHasSeeOrLink == 0 then
            return nil
        end
        -- Fall through to eager parse for @see/@link
    end

    local ranges = parser.GetJSDocCommentRanges(p.factory, nil, node, p.sourceText)

    -- Should only be called once per node
    p.hasDeprecatedTag = false
    local jsdoc = {}
    local pos = node:Pos()
    for _, comment in ipairs(ranges) do
        local parsed = p:parseJSDocComment(node, comment:Pos(), comment:End(), pos)
        if parsed ~= nil then
            parsed.parent = node
            jsdoc[#jsdoc + 1] = parsed
            pos = parsed:End()
        end
    end
    if #jsdoc ~= 0 then
        if node.flags & NodeFlags.HasJSDoc == 0 then
            node.flags = node.flags | NodeFlags.HasJSDoc
        end
        if p.hasDeprecatedTag then
            p.hasDeprecatedTag = false
            node.flags = node.flags | NodeFlags.PossiblyContainsDeprecatedTag
        end
        if p:isJavaScript() then
            p:reparseTags(node, jsdoc)
        end
        p.jsdocInfos[#p.jsdocInfos + 1] = { parent = node, jsDocs = jsdoc }
        return jsdoc
    end
    return nil
end

function Parser:parseJSDocTypeExpression(mayOmitBraces)
    local p = self
    local pos = p:nodePos()
    local hasBrace
    if mayOmitBraces then
        hasBrace = p:parseOptional(Kind.OpenBraceToken)
    else
        hasBrace = p:parseExpected(Kind.OpenBraceToken)
    end
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.JSDoc, true)
    local t = p:parseJSDocType()
    p.contextFlags = saveContextFlags
    if hasBrace then
        p:parseExpectedJSDoc(Kind.CloseBraceToken)
    end

    return p:finishNode(p.factory:NewJSDocTypeExpression(t), pos)
end

function Parser:parseJSDocNameReference()
    local p = self
    local pos = p:nodePos()
    local hasBrace = p:parseOptional(Kind.OpenBraceToken)
    local entityName = p:parseJSDocLinkName()
    if hasBrace then
        p:parseExpectedJSDoc(Kind.CloseBraceToken)
    end
    p.scanner:ResetPos(p.scanner:TokenFullStart())
    p:nextTokenJSDoc()
    return p:finishNode(p.factory:NewJSDocNameReference(entityName), pos)
end

-- Pass end=-1 to parse the text to the end
function Parser:parseJSDocComment(parent, start, end_, fullStart)
    local p = self
    if end_ == -1 then
        end_ = #p.sourceText
    end
    -- Check for /** (JSDoc opening part)
    if not parser.isJSDocLikeText(string.sub(p.sourceText, start + 1)) then
        -- TODO: This should be a panic, unless parseSingleJSDocComment is calling this (not ported yet)
        return nil
    end

    local saveSourceText = p.sourceText
    local saveToken = p.token
    local saveContextFlags = p.contextFlags
    local saveParsingContexts = p.parsingContexts
    local saveScannerState = p.scanner:Mark()
    local saveDiagnosticsLength = #p.diagnostics
    local saveHasParseError = p.hasParseError
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier

    -- initial indent is start+4 to account for leading `/** `
    -- + 1 because \n is one character before the first character in the line and,
    -- if there is no \n before start, -1 is one index before the first character in the string
    local lastNewLine = -1
    do
        local prefix = string.sub(p.sourceText, 1, start)
        local i = 0
        while true do
            local j = string.find(prefix, "\n", i + 1, true)
            if j == nil then
                break
            end
            lastNewLine = j - 1
            i = j
        end
    end
    local initialIndent = start + 4 - (lastNewLine + 1)
    -- -2 for trailing `*/`
    p.sourceText = string.sub(p.sourceText, 1, end_ - 2)
    p.scanner:SetText(p.sourceText)
    -- +3 for leading `/**`
    p.scanner:ResetPos(start + 3)
    p:setContextFlags(NodeFlags.JSDoc, true)
    p.parsingContexts = p.parsingContexts | (1 << PC.PCJSDocComment)

    local comment = p:parseJSDocCommentWorker(start, end_, fullStart, initialIndent)
    -- move jsdoc diagnostics to jsdocDiagnostics -- for JS files only
    if p.contextFlags & NodeFlags.JavaScriptFile ~= 0 then
        for i = saveDiagnosticsLength + 1, #p.diagnostics do
            p.jsdocDiagnostics[#p.jsdocDiagnostics + 1] = p.diagnostics[i]
        end
    end
    parser.truncate(p.diagnostics, saveDiagnosticsLength)

    p.sourceText = saveSourceText
    p.scanner:SetText(p.sourceText)
    p.parsingContexts = saveParsingContexts
    p.contextFlags = saveContextFlags
    p.scanner:Rewind(saveScannerState)
    p.token = saveToken
    p.hasParseError = saveHasParseError
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier

    return comment
end

--[[
 * @param offset - the offset in the containing file
 * @param indent - the number of spaces to consider as the margin (applies to non-first lines only)
]]
function Parser:parseJSDocCommentWorker(start, end_, fullStart, indent)
    local p = self
    -- Initially we can parse out a tag.  We also have seen a starting asterisk.
    -- This is so that /** * @type */ doesn't parse.
    local tags = {}
    local tagsPos = -1
    local tagsEnd = -1
    local state = SawAsterisk
    local backtickCount = 0
    local inFencedCodeBlock = false
    local commentParts = {}
    local comments = {}
    local commentsPos = -1
    local linkEnd = start
    local margin = -1
    local function pushComment(text)
        if margin == -1 then
            margin = indent
        end
        comments[#comments + 1] = text
        indent = indent + #text
    end

    p:nextTokenJSDoc()
    while p:parseOptionalJsdoc(Kind.WhitespaceTrivia) do
    end
    if p:parseOptionalJsdoc(Kind.NewLineTrivia) then
        state = BeginningOfLine
        indent = 0
    end
    while true do
        -- Detect fenced code blocks by counting consecutive backtick tokens.
        -- Three or more consecutive backticks toggle the fenced code block state.
        if p.token ~= Kind.BacktickToken and backtickCount > 0 then
            if backtickCount >= 3 then
                inFencedCodeBlock = not inFencedCodeBlock
            end
            backtickCount = 0
        end
        local t = p.token
        local isDefault = false
        if t == Kind.AtToken then
            if inFencedCodeBlock or not p.scanner:CanFollowJSDocAt() then
                if inFencedCodeBlock then
                    state = SavingBackticks
                else
                    state = SavingComments
                end
                pushComment(p.scanner:TokenText())
            else
                comments = parser.removeTrailingWhitespace(comments)
                if commentsPos == -1 then
                    commentsPos = p:nodePos()
                end
                local tag = p:parseTag(tags, indent)
                if tagsPos == -1 then
                    tagsPos = tag:Pos()
                end
                tags[#tags + 1] = tag
                tagsEnd = tag:End()
                -- NOTE: According to usejsdoc.org, a tag goes to end of line, except the last tag.
                -- Real-world comments may break this rule, so "BeginningOfLine" will not be a real line beginning
                -- for malformed examples like `/** @param {string} x @returns {number} the length */`
                state = BeginningOfLine
                margin = -1
            end
        elseif t == Kind.NewLineTrivia then
            comments[#comments + 1] = p.scanner:TokenText()
            state = BeginningOfLine
            indent = 0
        elseif t == Kind.AsteriskToken then
            local asterisk = p.scanner:TokenText()
            if state == SawAsterisk then
                -- If we've already seen an asterisk, then we can no longer parse a tag on this line
                state = SavingComments
                pushComment(asterisk)
            else
                if state ~= BeginningOfLine then
                    error("state must be BeginningOfLine", 0)
                end
                -- Ignore the first asterisk on a line
                state = SawAsterisk
                indent = indent + #asterisk
            end
        elseif t == Kind.WhitespaceTrivia then
            if state == SavingComments or state == SavingBackticks then
                error("whitespace shouldn't come from the scanner while saving top-level comment text", 0)
            end
            -- only collect whitespace if we're already saving comments or have just crossed the comment indent margin
            local whitespace = p.scanner:TokenText()
            if margin > -1 and indent + #whitespace > margin then
                local existingIndent = margin - indent
                if existingIndent < 0 then
                    existingIndent = existingIndent + #whitespace
                end
                if existingIndent < 0 then
                    existingIndent = 0
                end
                comments[#comments + 1] = string.sub(whitespace, existingIndent + 1)
            end
            indent = indent + #whitespace
        elseif t == Kind.EndOfFile then
            break
        elseif t == Kind.JSDocCommentTextToken then
            if state ~= SavingBackticks then
                if inFencedCodeBlock then
                    state = SavingBackticks
                else
                    state = SavingComments
                end
            end
            pushComment(p.scanner:TokenValue())
        elseif t == Kind.BacktickToken then
            backtickCount = backtickCount + 1
            if state == SavingBackticks then
                state = SavingComments
            else
                state = SavingBackticks
            end
            pushComment(p.scanner:TokenText())
        elseif t == Kind.OpenBraceToken then
            if inFencedCodeBlock then
                state = SavingBackticks
                pushComment(p.scanner:TokenText())
            else
                state = SavingComments
                local commentEnd = p.scanner:TokenFullStart()
                local linkStart = p.scanner:TokenEnd() - 1
                local link = p:parseJSDocLink(linkStart)
                if link ~= nil then
                    if linkEnd == start then
                        comments = parser.removeLeadingNewlines(comments)
                    end
                    local jsdocText = p:finishNodeWithEnd(p.factory:NewJSDocText(copyStrings(comments)), linkEnd, commentEnd)
                    commentParts[#commentParts + 1] = jsdocText
                    commentParts[#commentParts + 1] = link
                    comments = {}
                    linkEnd = p.scanner:TokenEnd()
                else
                    isDefault = true
                end
            end
        else
            isDefault = true
        end
        if isDefault then
            -- Anything else is doc comment text. We just save it. Because it
            -- wasn't a tag, we can no longer parse a tag on this line until we hit the next
            -- line break.
            if state ~= SavingBackticks then
                if inFencedCodeBlock then
                    state = SavingBackticks
                else
                    state = SavingComments
                end
            end
            pushComment(p.scanner:TokenText())
        end
        if state == SavingComments or state == SavingBackticks then
            p:nextJSDocCommentTextToken(state == SavingBackticks)
        else
            p:nextTokenJSDoc()
        end
    end

    if commentsPos == -1 then
        commentsPos = p.scanner:TokenFullStart()
    end

    if #comments > 0 then
        comments[#comments] = trimRightFunc(comments[#comments], stringutil.UnicodeIsSpace)
        local jsdocText = p:finishNodeWithEnd(p.factory:NewJSDocText(copyStrings(comments)), linkEnd, commentsPos)
        commentParts[#commentParts + 1] = jsdocText
    end

    if #commentParts > 0 and #tags > 0 and commentsPos == -1 then
        error("having parsed tags implies that the end of the comment span should be set", 0)
    end

    local tagsNodeList = nil
    if tagsPos ~= -1 then
        tagsNodeList = p:newNodeList(core.NewTextRange(tagsPos, tagsEnd), tags)
    end

    local jsdocComment = p.factory:NewJSDoc(
        p:newNodeList(core.NewTextRange(start, commentsPos), commentParts),
        tagsNodeList
    )
    return p:finishNodeWithEnd(jsdocComment, fullStart, end_)
end

local function isNewlineOnly(s)
    for i = 1, #s do
        local c = string.byte(s, i)
        if c ~= 13 and c ~= 10 then
            return false
        end
    end
    return true
end

function parser.removeLeadingNewlines(comments)
    local i = 0
    while i < #comments and isNewlineOnly(comments[i + 1]) do
        i = i + 1
    end
    return core.Slice(comments, i, #comments)
end

function parser.trimEnd(s)
    return trimRightFunc(s, stringutil.IsWhiteSpaceLike)
end

function parser.removeTrailingWhitespace(comments)
    local end_ = #comments
    for i = #comments - 1, 0, -1 do
        local trimmed = parser.trimEnd(comments[i + 1])
        if trimmed == "" then
            end_ = i
        else
            comments[i + 1] = trimmed
            break
        end
    end
    return parser.truncate(comments, end_)
end

function Parser:isNextNonwhitespaceTokenEndOfFile()
    -- We must use infinite lookahead, as there could be any number of newlines :(
    while true do
        self:nextTokenJSDoc()
        if self.token == Kind.EndOfFile then
            return true
        end
        if not (self.token == Kind.WhitespaceTrivia or self.token == Kind.NewLineTrivia) then
            return false
        end
    end
end

function Parser:skipWhitespace()
    if self.token == Kind.WhitespaceTrivia or self.token == Kind.NewLineTrivia then
        if self:lookAhead(Parser.isNextNonwhitespaceTokenEndOfFile) then
            return
            -- Don't skip whitespace prior to EoF (or end of comment) - that shouldn't be included in any node's range
        end
    end
    while self.token == Kind.WhitespaceTrivia or self.token == Kind.NewLineTrivia do
        self:nextTokenJSDoc()
    end
end

function Parser:skipWhitespaceOrAsterisk()
    local p = self
    if p.token == Kind.WhitespaceTrivia or p.token == Kind.NewLineTrivia then
        if p:lookAhead(Parser.isNextNonwhitespaceTokenEndOfFile) then
            return ""
            -- Don't skip whitespace prior to EoF (or end of comment) - that shouldn't be included in any node's range
        end
    end

    local precedingLineBreak = p.scanner:HasPrecedingLineBreak()
    local seenLineBreak = false
    local indents = {}
    while (precedingLineBreak and p.token == Kind.AsteriskToken) or p.token == Kind.WhitespaceTrivia or p.token == Kind.NewLineTrivia do
        indents[#indents + 1] = p.scanner:TokenText()
        if p.token == Kind.NewLineTrivia then
            precedingLineBreak = true
            seenLineBreak = true
            indents = {}
        elseif p.token == Kind.AsteriskToken then
            precedingLineBreak = false
        end
        p:nextTokenJSDoc()
    end
    if seenLineBreak then
        return table.concat(indents)
    else
        return ""
    end
end

local simpleTagFactories = {
    public = "NewJSDocPublicTag",
    private = "NewJSDocPrivateTag",
    protected = "NewJSDocProtectedTag",
    readonly = "NewJSDocReadonlyTag",
    override = "NewJSDocOverrideTag",
    deprecated = "NewJSDocDeprecatedTag",
}

function Parser:parseTag(tags, margin)
    local p = self
    if p.token ~= Kind.AtToken then
        error("should be called only at the start of a tag", 0)
    end
    local start = p.scanner:TokenStart()
    p:nextTokenJSDoc()

    local tagName = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
    local indentText = p:skipWhitespaceOrAsterisk()

    local tag
    local name = tagName:Text()
    if name == "implements" then
        tag = p:parseImplementsTag(start, tagName, margin, indentText)
    elseif name == "augments" or name == "extends" then
        tag = p:parseAugmentsTag(start, tagName, margin, indentText)
    elseif simpleTagFactories[name] ~= nil then
        if name == "deprecated" then
            p.hasDeprecatedTag = true
        end
        local factoryMethod = simpleTagFactories[name]
        tag = p:parseSimpleTag(start, function(tn, comments)
            return p.factory[factoryMethod](p.factory, tn, comments)
        end, tagName, margin, indentText)
    elseif name == "this" then
        tag = p:parseThisTag(start, tagName, margin, indentText)
    elseif name == "arg" or name == "argument" or name == "param" then
        tag = p:parseParameterOrPropertyTag(start, tagName, parser.propertyLikeParseParameter, margin)
    elseif name == "return" or name == "returns" then
        tag = p:parseReturnTag(tags, start, tagName, margin, indentText)
    elseif name == "template" then
        tag = p:parseTemplateTag(start, tagName, margin, indentText)
    elseif name == "type" then
        tag = p:parseTypeTag(tags, start, tagName, margin, indentText)
    elseif name == "typedef" then
        tag = p:parseTypedefTag(start, tagName, margin, indentText)
    elseif name == "callback" then
        tag = p:parseCallbackTag(start, tagName, margin, indentText)
    elseif name == "overload" then
        tag = p:parseOverloadTag(start, tagName, margin, indentText)
    elseif name == "satisfies" then
        tag = p:parseSatisfiesTag(start, tagName, margin, indentText)
    elseif name == "see" then
        tag = p:parseSeeTag(start, tagName, margin, indentText)
    elseif name == "exception" or name == "throws" then
        tag = p:parseThrowsTag(start, tagName, margin, indentText)
    elseif name == "import" then
        tag = p:parseImportTag(start, tagName, margin, indentText)
    else
        tag = p:parseUnknownTag(start, tagName, margin, indentText)
    end
    if tag == nil then
        error("tag should not be nil", 0)
    end
    return tag
end

function Parser:parseTrailingTagComments(pos, end_, margin, indentText)
    -- some tags, like typedef and callback, have already parsed their comments earlier
    if #indentText == 0 then
        margin = margin + end_ - pos
    end
    local initialMargin = ""
    if margin < #indentText then
        initialMargin = string.sub(indentText, margin + 1)
    end
    return self:parseTagComments(margin, initialMargin)
end

-- initialMargin: string or nil (Go *string)
function Parser:parseTagComments(indent, initialMargin)
    local p = self
    local commentsPos = p:nodePos()
    local comments = {}
    local parts = {}
    local linkEnd = -1
    local state = BeginningOfLine
    local backtickCount = 0
    local inFencedCodeBlock = false
    if indent < 0 then
        error("indent must be a natural number", 0)
    end
    local margin = -1
    local function pushComment(text)
        if margin == -1 then
            margin = indent
        end
        comments[#comments + 1] = text
        indent = indent + #text
    end

    if initialMargin ~= nil then
        -- jump straight to saving comments if there is some initial indentation
        if initialMargin ~= "" then
            pushComment(initialMargin)
        end
        state = SawAsterisk
    end
    local tok = p.token
    while true do
        -- Detect fenced code blocks by counting consecutive backtick tokens.
        -- Three or more consecutive backticks toggle the fenced code block state.
        if tok ~= Kind.BacktickToken and backtickCount > 0 then
            if backtickCount >= 3 then
                inFencedCodeBlock = not inFencedCodeBlock
            end
            backtickCount = 0
        end
        local isDefault = false
        if tok == Kind.NewLineTrivia then
            state = BeginningOfLine
            -- don't use pushComment here because we want to keep the margin unchanged
            comments[#comments + 1] = p.scanner:TokenText()
            indent = 0
        elseif tok == Kind.AtToken then
            if not inFencedCodeBlock and p.scanner:CanFollowJSDocAt() then
                p.scanner:ResetPos(p.scanner:TokenEnd() - 1)
                break
            end
            if inFencedCodeBlock then
                state = SavingBackticks
            else
                state = SavingComments
            end
            pushComment(p.scanner:TokenText())
        elseif tok == Kind.EndOfFile then
            -- Done
            break
        elseif tok == Kind.WhitespaceTrivia then
            if state == SavingComments or state == SavingBackticks then
                error("whitespace shouldn't come from the scanner while saving comment text", 0)
            end
            local whitespace = p.scanner:TokenText()
            -- if the whitespace crosses the margin, take only the whitespace that passes the margin
            if margin > -1 and indent + #whitespace > margin then
                comments[#comments + 1] = string.sub(whitespace, math.max(margin - indent, 0) + 1)
                if inFencedCodeBlock then
                    state = SavingBackticks
                else
                    state = SavingComments
                end
            end
            indent = indent + #whitespace
        elseif tok == Kind.OpenBraceToken then
            if inFencedCodeBlock then
                state = SavingBackticks
                pushComment(p.scanner:TokenText())
            else
                state = SavingComments
                local commentEnd = p.scanner:TokenFullStart()
                local linkStart = p.scanner:TokenEnd() - 1
                local link = p:parseJSDocLink(linkStart)
                if link ~= nil then
                    local commentStart
                    if linkEnd > -1 then
                        commentStart = linkEnd
                    else
                        commentStart = commentsPos
                    end
                    local text = p:finishNodeWithEnd(p.factory:NewJSDocText(copyStrings(comments)), commentStart, commentEnd)
                    parts[#parts + 1] = text
                    parts[#parts + 1] = link
                    comments = {}
                    linkEnd = p.scanner:TokenEnd()
                else
                    pushComment(p.scanner:TokenText())
                end
            end
        elseif tok == Kind.BacktickToken then
            backtickCount = backtickCount + 1
            if state == SavingBackticks then
                state = SavingComments
            else
                state = SavingBackticks
            end
            pushComment(p.scanner:TokenText())
        elseif tok == Kind.JSDocCommentTextToken then
            if state ~= SavingBackticks then
                if inFencedCodeBlock then
                    state = SavingBackticks
                else
                    state = SavingComments
                end
                -- leading identifiers start recording as well
            end
            pushComment(p.scanner:TokenValue())
        elseif tok == Kind.AsteriskToken then
            if state == BeginningOfLine then
                -- leading asterisks start recording on the *next* (non-whitespace) token
                state = SawAsterisk
                indent = indent + 1
            else
                -- record the * as a comment
                isDefault = true
            end
        else
            isDefault = true
        end
        if isDefault then
            if state ~= SavingBackticks then
                if inFencedCodeBlock then
                    state = SavingBackticks
                else
                    state = SavingComments
                end
                -- leading identifiers start recording as well
            end
            pushComment(p.scanner:TokenText())
        end
        if state == SavingComments or state == SavingBackticks then
            tok = p:nextJSDocCommentTextToken(state == SavingBackticks)
        else
            tok = p:nextTokenJSDoc()
        end
    end

    comments = parser.removeLeadingNewlines(comments)
    comments = parser.removeTrailingWhitespace(comments)
    if #comments > 0 then
        local commentStart
        if linkEnd > -1 then
            commentStart = linkEnd
        else
            commentStart = commentsPos
        end
        local text = p:finishNode(p.factory:NewJSDocText(copyStrings(comments)), commentStart)
        parts[#parts + 1] = text
    end

    if #parts > 0 then
        return p:newNodeList(core.NewTextRange(commentsPos, p.scanner:TokenEnd()), parts)
    end
    return nil
end

function Parser:parseJSDocLink(start)
    local p = self
    local state = p:mark()
    local linkType, ok = p:parseJSDocLinkPrefix()
    if not ok then
        p:rewind(state)
        return nil
    end
    p:nextTokenJSDoc()
    -- start at token after link, then skip any whitespace
    p:skipWhitespace()
    local name = p:parseJSDocLinkName()
    local text = {}
    while p.token ~= Kind.CloseBraceToken and p.token ~= Kind.NewLineTrivia and p.token ~= Kind.EndOfFile do
        text = parser.append(text, p.scanner:TokenText())
        p:nextTokenJSDoc() -- Couldn't this be nextTokenCommentJSDoc?
    end
    local create
    if linkType == "link" then
        create = p.factory:NewJSDocLink(name, text)
    elseif linkType == "linkcode" then
        create = p.factory:NewJSDocLinkCode(name, text)
    else
        create = p.factory:NewJSDocLinkPlain(name, text)
    end
    return p:finishNodeWithEnd(create, start, p.scanner:TokenEnd())
end

function Parser:parseJSDocLinkName()
    local p = self
    if parser.tokenIsIdentifierOrKeyword(p.token) then
        local pos = p:nodePos()
        local name = p:parseIdentifierName()
        while p:parseOptional(Kind.DotToken) do
            local right
            if p.token == Kind.PrivateIdentifier then
                right = p:createMissingIdentifier()
            else
                right = p:parseIdentifierName()
            end
            name = p:finishNode(p.factory:NewQualifiedName(name, right), pos)
        end
        while p.token == Kind.PrivateIdentifier do
            p.scanner:ReScanHashToken()
            p:nextTokenJSDoc()
            name = p:finishNode(p.factory:NewQualifiedName(name, p:parseIdentifier()), pos)
        end
        return name
    end
    return nil
end

function Parser:parseJSDocLinkPrefix()
    local p = self
    p:skipWhitespaceOrAsterisk()
    if p.token == Kind.OpenBraceToken and p:nextTokenJSDoc() == Kind.AtToken and parser.tokenIsIdentifierOrKeyword(p:nextTokenJSDoc()) then
        local kind = p.scanner:TokenValue()
        if parser.isJSDocLinkTag(kind) then
            return kind, true
        end
    end
    return "NONE", false
end

function parser.isJSDocLinkTag(kind)
    return kind == "link" or kind == "linkcode" or kind == "linkplain"
end

function Parser:parseUnknownTag(start, tagName, indent, indentText)
    return self:finishNode(self.factory:NewJSDocUnknownTag(tagName, self:parseTrailingTagComments(start, self:nodePos(), indent, indentText)), start)
end

function Parser:tryParseTypeExpression()
    self:skipWhitespaceOrAsterisk()
    if self.token == Kind.OpenBraceToken then
        return self:parseJSDocTypeExpression(false --[[mayOmitBraces]])
    else
        return nil
    end
end

function Parser:parseBracketNameInPropertyAndParamTag(target)
    local p = self
    -- Looking for something like '[foo]', 'foo', '[foo.bar]' or 'foo.bar'
    local isBracketed = p:parseOptionalJsdoc(Kind.OpenBracketToken)
    if isBracketed then
        p:skipWhitespace()
    end
    -- a markdown-quoted name: `arg` is not legal jsdoc, but occurs in the wild
    local isBackquoted = p:parseOptionalJsdoc(Kind.BacktickToken)
    local name = p:parseJSDocEntityName(target ~= parser.propertyLikeParseParameter and diagnostics.Identifier_expected or nil)
    if isBackquoted then
        p:parseExpectedTokenJSDoc(Kind.BacktickToken)
    end
    if isBracketed then
        p:skipWhitespace()
        -- May have an optional default, e.g. '[foo = 42]'
        if p:parseOptionalToken(Kind.EqualsToken) ~= nil then
            p:parseExpression()
        end

        p:parseExpected(Kind.CloseBracketToken)
    end

    return name, isBracketed
end

function parser.isObjectOrObjectArrayTypeReference(node)
    if node.kind == Kind.ObjectKeyword then
        return true
    elseif node.kind == Kind.ArrayType then
        return parser.isObjectOrObjectArrayTypeReference(node:AsArrayTypeNode().elementType)
    else
        if ast.IsTypeReferenceNode(node) then
            local ref = node:AsTypeReferenceNode()
            return ast.IsIdentifier(ref.typeName) and ref.typeName:Text() == "Object" and ref.typeArguments == nil
        end
        return false
    end
end

function Parser:parseParameterOrPropertyTag(start, tagName, target, indent)
    local p = self
    local typeExpression = p:tryParseTypeExpression()
    local isNameFirst = typeExpression == nil
    p:skipWhitespaceOrAsterisk()

    local name, isBracketed = p:parseBracketNameInPropertyAndParamTag(target)
    local indentText = p:skipWhitespaceOrAsterisk()

    if isNameFirst and p:lookAhead(function(p2)
        local _, ok = p2:parseJSDocLinkPrefix()
        return not ok
    end) then
        typeExpression = p:tryParseTypeExpression()
    end

    local comment = p:parseTrailingTagComments(start, p:nodePos(), indent, indentText)

    local nestedTypeLiteral = p:parseNestedTypeLiteral(typeExpression, name, target, indent)
    if nestedTypeLiteral ~= nil then
        typeExpression = nestedTypeLiteral
        isNameFirst = true
    end
    local kind = target == parser.propertyLikeParseProperty and Kind.JSDocPropertyTag or Kind.JSDocParameterTag
    local result = p.factory:NewJSDocParameterOrPropertyTag(kind, tagName, name, isBracketed, typeExpression, isNameFirst, comment)
    return p:finishNode(result, start)
end

function Parser:parseNestedTypeLiteral(typeExpression, name, target, indent)
    local p = self
    if typeExpression ~= nil and parser.isObjectOrObjectArrayTypeReference(typeExpression:Type()) then
        local pos = p:nodePos()
        local children = nil
        while true do
            local state = p:mark()
            local child = p:parseChildParameterOrPropertyTag(target, indent, name)
            if child == nil then
                p:rewind(state)
                break
            end
            if child.kind == Kind.JSDocParameterTag or child.kind == Kind.JSDocPropertyTag then
                children = parser.append(children, child)
            elseif child.kind == Kind.JSDocTemplateTag then
                p:parseErrorAtRange(child:TagName().loc, diagnostics.A_JSDoc_template_tag_may_not_follow_a_typedef_callback_or_overload_tag)
            end
        end
        if children ~= nil then
            local literal = p:finishNode(p.factory:NewJSDocTypeLiteral(children, typeExpression:Type().kind == Kind.ArrayType), pos)
            return p:finishNode(p.factory:NewJSDocTypeExpression(literal), pos)
        end
    end
    return nil
end

function Parser:parseReturnTag(previousTags, start, tagName, indent, indentText)
    local p = self
    if core.Some(previousTags, ast.IsJSDocReturnTag) then
        p:parseErrorAt(tagName:Pos(), p.scanner:TokenStart(), diagnostics.X_0_tag_already_specified, tagName:Text())
    end

    local typeExpression = p:tryParseTypeExpression()
    return p:finishNode(p.factory:NewJSDocReturnTag(tagName, typeExpression, p:parseTrailingTagComments(start, p:nodePos(), indent, indentText)), start)
end

-- pass indent=-1 to skip parsing trailing comments (as when a type tag is nested in a typedef)
function Parser:parseTypeTag(previousTags, start, tagName, indent, indentText)
    local p = self
    if core.Some(previousTags, ast.IsJSDocTypeTag) then
        p:parseErrorAt(tagName:Pos(), p.scanner:TokenStart(), diagnostics.X_0_tag_already_specified, tagName:Text())
    end

    local typeExpression = p:parseJSDocTypeExpression(true)
    local comments = nil
    if indent ~= -1 then
        comments = p:parseTrailingTagComments(start, p:nodePos(), indent, indentText)
    end
    return p:finishNode(p.factory:NewJSDocTypeTag(tagName, typeExpression, comments), start)
end

function Parser:parseSeeTag(start, tagName, indent, indentText)
    local p = self
    local hasNameReference = p:isIdentifier() and string.sub(p.sourceText, p.scanner:TokenEnd() + 1, p.scanner:TokenEnd() + 3) ~= "://" or
        p.token == Kind.OpenBraceToken and p:lookAhead(Parser.nextTokenIsIdentifierOrKeyword)
    local nameExpression = nil
    if hasNameReference then
        nameExpression = p:parseJSDocNameReference()
    end
    local comments = p:parseTrailingTagComments(start, p:nodePos(), indent, indentText)
    return p:finishNode(p.factory:NewJSDocSeeTag(tagName, nameExpression, comments), start)
end

function Parser:parseImplementsTag(start, tagName, margin, indentText)
    local className = self:parseExpressionWithTypeArgumentsForAugments()
    return self:finishNode(self.factory:NewJSDocImplementsTag(tagName, className, self:parseTrailingTagComments(start, self:nodePos(), margin, indentText)), start)
end

function Parser:parseAugmentsTag(start, tagName, margin, indentText)
    local className = self:parseExpressionWithTypeArgumentsForAugments()
    return self:finishNode(self.factory:NewJSDocAugmentsTag(tagName, className, self:parseTrailingTagComments(start, self:nodePos(), margin, indentText)), start)
end

function Parser:parseSatisfiesTag(start, tagName, margin, indentText)
    local typeExpression = self:parseJSDocTypeExpression(false)
    local comments = self:parseTrailingTagComments(start, self:nodePos(), margin, indentText)
    return self:finishNode(self.factory:NewJSDocSatisfiesTag(tagName, typeExpression, comments), start)
end

function Parser:parseThrowsTag(start, tagName, margin, indentText)
    local typeExpression = self:tryParseTypeExpression()
    local comment = self:parseTrailingTagComments(start, self:nodePos(), margin, indentText)
    return self:finishNode(self.factory:NewJSDocThrowsTag(tagName, typeExpression, comment), start)
end

function Parser:parseImportTag(start, tagName, margin, indentText)
    local p = self
    local afterImportTagPos = p.scanner:TokenFullStart()

    local identifier = nil
    if p:isIdentifier() then
        identifier = p:parseIdentifier()
    end

    local importClause = p:tryParseImportClause(identifier, afterImportTagPos, Kind.TypeKeyword, true --[[skipJSDocLeadingAsterisks]])
    local moduleSpecifier = p:parseModuleSpecifier()
    local attributes = p:tryParseImportAttributes()

    local comments = p:parseTrailingTagComments(start, p:nodePos(), margin, indentText)
    return p:finishNode(p.factory:NewJSDocImportTag(tagName, importClause, moduleSpecifier, attributes, comments), start)
end

function Parser:parseExpressionWithTypeArgumentsForAugments()
    local p = self
    local usedBrace = p:parseOptional(Kind.OpenBraceToken)
    local pos = p:nodePos()
    local expression = p:parsePropertyAccessEntityNameExpression()
    p.scanner:SetSkipJSDocLeadingAsterisks(true)
    local typeArguments = p:parseTypeArguments()
    p.scanner:SetSkipJSDocLeadingAsterisks(false)
    local node = p:finishNode(p.factory:NewExpressionWithTypeArguments(expression, typeArguments), pos)
    if usedBrace then
        p:skipWhitespace()
        p:parseExpected(Kind.CloseBraceToken)
    end
    return node
end

function Parser:parsePropertyAccessEntityNameExpression()
    local p = self
    local pos = p:nodePos()
    local node = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
    while p:parseOptional(Kind.DotToken) do
        local name = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
        node = p:finishNode(p.factory:NewPropertyAccessExpression(node, nil, name, NodeFlags.None), pos)
    end
    return node
end

function Parser:parseSimpleTag(start, createTag, tagName, margin, indentText)
    return self:finishNode(createTag(tagName, self:parseTrailingTagComments(start, self:nodePos(), margin, indentText)), start)
end

function Parser:parseThisTag(start, tagName, margin, indentText)
    local typeExpression = self:parseJSDocTypeExpression(true)
    self:skipWhitespace()
    local result = self.factory:NewJSDocThisTag(tagName, typeExpression, self:parseTrailingTagComments(start, self:nodePos(), margin, indentText))
    return self:finishNode(result, start)
end

function Parser:parseJSDocTypeNameWithNamespace(nested)
    local p = self
    local start = p.scanner:TokenStart()
    if not parser.tokenIsIdentifierOrKeyword(p.token) then
        return nil
    end
    local typeNameOrNamespaceName = p:parseJSDocIdentifierName(nil)
    if p:parseOptionalJsdoc(Kind.DotToken) then
        local body = p:parseJSDocTypeNameWithNamespace(true --[[nested]])
        local jsDocNamespaceNode = p.factory:NewModuleDeclaration(
            nil, --[[modifiers]]
            Kind.NamespaceKeyword, --[[keyword]]
            typeNameOrNamespaceName,
            body
        )
        if nested then
            jsDocNamespaceNode.flags = jsDocNamespaceNode.flags | NodeFlags.NestedNamespace
        end
        return p:finishNode(jsDocNamespaceNode, start)
    end
    if nested then
        typeNameOrNamespaceName.flags = typeNameOrNamespaceName.flags | NodeFlags.IdentifierIsInJSDocNamespace
    end
    return typeNameOrNamespaceName
end

function Parser:parseTypedefTag(start, tagName, indent, indentText)
    local p = self
    local typeExpression = p:tryParseTypeExpression()
    p:skipWhitespaceOrAsterisk()
    local fullName = p:parseJSDocTypeNameWithNamespace(false --[[nested]])
    if fullName == nil then
        fullName = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
    end
    p:skipWhitespace()
    local comment = p:parseTagComments(indent, nil)

    local end_ = -1
    local hasChildren = false
    if typeExpression == nil or parser.isObjectOrObjectArrayTypeReference(typeExpression:Type()) then
        local child
        local childTypeTag = nil
        local jsdocPropertyTags = nil
        while true do
            local state = p:mark()
            child = p:parseChildPropertyTag(indent)
            if child == nil then
                p:rewind(state)
                break
            end
            hasChildren = true
            if child.kind == Kind.JSDocTemplateTag then
                p:parseErrorAtRange(child:TagName().loc, diagnostics.A_JSDoc_template_tag_may_not_follow_a_typedef_callback_or_overload_tag)
            elseif child.kind == Kind.JSDocTypeTag then
                if childTypeTag == nil then
                    childTypeTag = child:AsJSDocTypeTag()
                else
                    local lastError = p:parseErrorAtCurrentToken(diagnostics.A_JSDoc_typedef_comment_may_not_contain_multiple_type_tags)
                    if lastError ~= nil then
                        local related = ast.NewDiagnostic(nil, core.NewTextRange(0, 0), diagnostics.The_tag_was_first_specified_here)
                        lastError:AddRelatedInfo(related)
                    end
                end
            else
                jsdocPropertyTags = parser.append(jsdocPropertyTags, child)
            end
        end
        if hasChildren then
            local isArrayType = typeExpression ~= nil and typeExpression:Type().kind == Kind.ArrayType
            local jsdocTypeLiteral = p.factory:NewJSDocTypeLiteral(jsdocPropertyTags or {}, isArrayType)
            if childTypeTag ~= nil and childTypeTag.typeExpression ~= nil and not parser.isObjectOrObjectArrayTypeReference(childTypeTag.typeExpression:Type()) then
                typeExpression = childTypeTag.typeExpression
            else
                -- !!! This differs from Strada but prevents a crash
                local pos = start
                if jsdocPropertyTags ~= nil and #jsdocPropertyTags > 0 then
                    pos = jsdocPropertyTags[1]:Pos()
                end
                typeExpression = p:finishNode(jsdocTypeLiteral, pos)
            end
            end_ = typeExpression:End()
        end
    end

    -- Only include the characters between the name end and the next token if a comment was actually parsed out - otherwise it's just whitespace
    if end_ == -1 then
        if hasChildren and typeExpression ~= nil then
            end_ = typeExpression:End()
        elseif comment ~= nil then
            end_ = p:nodePos()
        elseif fullName ~= nil then
            end_ = fullName:End()
        elseif typeExpression ~= nil then
            end_ = typeExpression:End()
        else
            end_ = tagName:End()
        end
    end

    if comment == nil then
        comment = p:parseTrailingTagComments(start, end_, indent, indentText)
    end

    local typedefTag = p:finishNodeWithEnd(p.factory:NewJSDocTypedefTag(tagName, typeExpression, fullName, comment), start, end_)
    if typeExpression ~= nil then
        typeExpression.parent = typedefTag -- forcibly overwrite parent potentially set by inner type expression parse
    end
    return typedefTag
end

function Parser:parseCallbackTagParameters(indent)
    local p = self
    local child
    local parameters = {}
    local pos = p:nodePos()
    while true do
        local state = p:mark()
        child = p:parseChildParameterOrPropertyTag(parser.propertyLikeParseCallbackParameter, indent, nil)
        if child == nil then
            p:rewind(state)
            break
        end
        if child.kind == Kind.JSDocTemplateTag then
            p:parseErrorAtRange(child:TagName().loc, diagnostics.A_JSDoc_template_tag_may_not_follow_a_typedef_callback_or_overload_tag)
        else
            parameters[#parameters + 1] = child
        end
    end
    return p:newNodeList(core.NewTextRange(pos, p:nodePos()), parameters)
end

function Parser:parseJSDocSignature(start, indent)
    local p = self
    local parameters = p:parseCallbackTagParameters(indent)
    local returnTag = nil
    local state = p:mark()
    if p:parseOptionalJsdoc(Kind.AtToken) then
        local tag = p:parseTag(nil, indent)
        if tag.kind == Kind.JSDocReturnTag then
            returnTag = tag
        end
    end
    if returnTag == nil then
        p:rewind(state)
    end
    return p:finishNode(p.factory:NewJSDocSignature(nil, parameters, returnTag), start)
end

function Parser:parseCallbackTag(start, tagName, indent, indentText)
    local p = self
    local fullName = p:parseJSDocTypeNameWithNamespace(false --[[nested]])
    if fullName == nil then
        fullName = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
    end
    p:skipWhitespace()
    local comment = p:parseTagComments(indent, nil)
    local typeExpression = p:parseJSDocSignature(p:nodePos(), indent)
    if comment == nil then
        comment = p:parseTrailingTagComments(start, p:nodePos(), indent, indentText)
    end
    local end_
    if comment ~= nil then
        end_ = p:nodePos()
    else
        end_ = typeExpression:End()
    end
    return p:finishNodeWithEnd(p.factory:NewJSDocCallbackTag(tagName, typeExpression, fullName, comment), start, end_)
end

function Parser:parseOverloadTag(start, tagName, indent, indentText)
    local p = self
    p:skipWhitespace()
    local comment = p:parseTagComments(indent, nil)
    local typeExpression = p:parseJSDocSignature(start, indent)
    if comment == nil then
        comment = p:parseTrailingTagComments(start, p:nodePos(), indent, indentText)
    end
    local end_
    if comment ~= nil then
        end_ = p:nodePos()
    else
        end_ = typeExpression:End()
    end
    return p:finishNodeWithEnd(p.factory:NewJSDocOverloadTag(tagName, typeExpression, comment), start, end_)
end

function parser.textsEqual(a, b)
    while not ast.IsIdentifier(a) or not ast.IsIdentifier(b) do
        if not ast.IsIdentifier(a) and not ast.IsIdentifier(b) and a:AsQualifiedName().right:Text() == b:AsQualifiedName().right:Text() then
            a = a:AsQualifiedName().left
            b = b:AsQualifiedName().left
        else
            return false
        end
    end
    return a:Text() == b:Text()
end

function Parser:parseChildPropertyTag(indent)
    return self:parseChildParameterOrPropertyTag(parser.propertyLikeParseProperty, indent, nil)
end

function Parser:parseChildParameterOrPropertyTag(target, indent, name)
    local p = self
    local canParseTag = true
    local seenAsterisk = false
    while true do
        local t = p:nextTokenJSDoc()
        if t == Kind.AtToken then
            if canParseTag and p.scanner:CanFollowJSDocAt() then
                local child = p:tryParseChildTag(target, indent)
                if child ~= nil and name ~= nil and
                    (child.kind == Kind.JSDocParameterTag or child.kind == Kind.JSDocPropertyTag) and
                    (ast.IsIdentifier(child:Name()) or not parser.textsEqual(name, child:Name():AsQualifiedName().left)) then
                    return nil
                end
                return child
            end
            seenAsterisk = false
        elseif t == Kind.NewLineTrivia then
            canParseTag = true
            seenAsterisk = false
        elseif t == Kind.AsteriskToken then
            if seenAsterisk then
                canParseTag = false
            end
            seenAsterisk = true
        elseif t == Kind.Identifier then
            canParseTag = false
        elseif t == Kind.EndOfFile then
            return nil
        end
    end
end

function Parser:tryParseChildTag(target, indent)
    local p = self
    if p.token ~= Kind.AtToken then
        error("should only be called when at @", 0)
    end
    local start = p.scanner:TokenFullStart()
    p:nextTokenJSDoc()

    local tagName = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
    local indentText = p:skipWhitespaceOrAsterisk()
    local t = 0
    local name = tagName:Text()
    if name == "type" then
        if target == parser.propertyLikeParseProperty then
            return p:parseTypeTag(nil, start, tagName, -1, "")
        end
    elseif name == "prop" or name == "property" then
        t = parser.propertyLikeParseProperty
    elseif name == "arg" or name == "argument" or name == "param" then
        t = parser.propertyLikeParseParameter | parser.propertyLikeParseCallbackParameter
    elseif name == "template" then
        return p:parseTemplateTag(start, tagName, indent, indentText)
    elseif name == "this" then
        return p:parseThisTag(start, tagName, indent, indentText)
    else
        return nil
    end
    if (target & t) == 0 then
        return nil
    end
    return p:parseParameterOrPropertyTag(start, tagName, target, indent)
end

function Parser:parseTemplateTagTypeParameter()
    local p = self
    local typeParameterPos = p:nodePos()
    local isBracketed = p:parseOptionalJsdoc(Kind.OpenBracketToken)
    if isBracketed then
        p:skipWhitespace()
    end

    local modifiers = p:parseModifiersEx(false, true --[[permitConstAsModifier]], false)
    local name = p:parseJSDocIdentifierName(diagnostics.Unexpected_token_A_type_parameter_name_was_expected_without_curly_braces)
    local defaultType = nil
    if isBracketed then
        p:skipWhitespace()
        p:parseExpected(Kind.EqualsToken)
        local saveContextFlags = p.contextFlags
        p:setContextFlags(NodeFlags.JSDoc, true)
        defaultType = p:parseJSDocType()
        p.contextFlags = saveContextFlags
        p:parseExpected(Kind.CloseBracketToken)
    end

    if ast.NodeIsMissing(name) then
        return nil
    end
    return p:finishNode(p.factory:NewTypeParameterDeclaration(modifiers, name, nil --[[constraint]], nil --[[expression]], defaultType), typeParameterPos)
end

function Parser:parseTemplateTagTypeParameters()
    local p = self
    -- Go: a zero-value ast.TypeParameterList (Loc {0, 0}, no nodes)
    local typeParameters = p.factory:NewNodeList({})
    typeParameters.loc = core.NewTextRange(0, 0)
    repeat -- do-while loop
        p:skipWhitespace()
        local node = p:parseTemplateTagTypeParameter()
        if node ~= nil then
            typeParameters.nodes[#typeParameters.nodes + 1] = node
        end
        p:skipWhitespaceOrAsterisk()
    until not p:parseOptionalJsdoc(Kind.CommaToken)
    return typeParameters
end

function Parser:parseTemplateTag(start, tagName, indent, indentText)
    local p = self
    -- The template tag looks like one of the following:
    --   @template T,U,V
    --   @template {Constraint} T
    --
    -- According to the [closure docs](https://github.com/google/closure-compiler/wiki/Generic-Types#multiple-bounded-template-types):
    --   > Multiple bounded generics cannot be declared on the same line. For the sake of clarity, if multiple templates share the same
    --   > type bound they must be declared on separate lines.
    --
    -- TODO: Determine whether we should enforce this in the checker.
    -- TODO: Consider moving the `constraint` to the first type parameter as we could then remove `getEffectiveConstraintOfTypeParameter`.
    -- TODO: Consider only parsing a single type parameter if there is a constraint.
    local constraint = nil
    if p.token == Kind.OpenBraceToken then
        constraint = p:parseJSDocTypeExpression(false)
    end
    local typeParameters = p:parseTemplateTagTypeParameters()
    local result = p.factory:NewJSDocTemplateTag(tagName, constraint, typeParameters, p:parseTrailingTagComments(start, p:nodePos(), indent, indentText))
    return p:finishNode(result, start)
end

function Parser:parseOptionalJsdoc(t)
    if self.token == t then
        self:nextTokenJSDoc()
        return true
    end
    return false
end

function Parser:parseJSDocEntityName(diagnosticMessage)
    local p = self
    local entity = p:parseJSDocIdentifierName(diagnosticMessage)
    if p:parseOptional(Kind.OpenBracketToken) then
        p:parseExpected(Kind.CloseBracketToken)
        -- Note that y[] is accepted as an entity name, but the postfix brackets are not saved for checking.
        -- Technically usejsdoc.org requires them for specifying a property of a type equivalent to Array<{ x: ...}>
        -- but it's not worth it to enforce that restriction.
    end
    while p:parseOptional(Kind.DotToken) do
        local name = p:parseJSDocIdentifierName(diagnostics.Identifier_expected)
        if p:parseOptional(Kind.OpenBracketToken) then
            p:parseExpected(Kind.CloseBracketToken)
        end
        local pos = entity:Pos()
        entity = p:finishNode(p.factory:NewQualifiedName(entity, name), pos)
    end
    return entity
end

function Parser:parseJSDocIdentifierName(diagnosticMessage)
    local p = self
    if not parser.tokenIsIdentifierOrKeyword(p.token) then
        if diagnosticMessage ~= nil then
            p:parseErrorAtCurrentToken(diagnosticMessage)
        elseif parser.isReservedWord(p.token) then
            p:parseErrorAtCurrentToken(diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, p.scanner:TokenText())
        end
        return p:finishNode(p:newIdentifier(""), p:nodePos())
    end
    local pos = p.scanner:TokenStart()
    local end_ = p.scanner:TokenEnd()
    local text = p.scanner:TokenValue()
    p:nextTokenJSDoc()
    return p:finishNodeWithEnd(p:newIdentifier(text), pos, end_)
end
