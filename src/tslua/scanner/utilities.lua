local scanner = require("tslua.scanner")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local TokenFlags = ast.TokenFlags

local ssub = string.sub

-- Go strings.TrimLeftFunc(s, f).
local function trimLeftFunc(s, f)
    local pos = 0
    local n = #s
    while pos < n do
        local r, size = core.DecodeRune(s, pos)
        if not f(r) then
            break
        end
        pos = pos + size
    end
    return ssub(s, pos + 1)
end

-- Go strings.TrimRightFunc(s, f).
local function trimRightFunc(s, f)
    local end_ = #s
    while end_ > 0 do
        local r, size = core.DecodeLastRune(s, end_)
        if not f(r) then
            break
        end
        end_ = end_ - size
    end
    return ssub(s, 1, end_)
end

-- Go unicode.IsSpace.
local function unicodeIsSpace(r)
    if r <= 0xFF then
        return r == 0x09 or r == 0x0A or r == 0x0B or r == 0x0C or r == 0x0D or r == 0x20 or r == 0x85 or r == 0xA0
    end
    return r == 0x1680 or (r >= 0x2000 and r <= 0x200A) or r == 0x2028 or r == 0x2029 or r == 0x202F or r == 0x205F or r == 0x3000
end

function scanner.tokenIsIdentifierOrKeyword(token)
    return token >= Kind.Identifier
end

function scanner.IdentifierToKeywordKind(node)
    return scanner.textToKeyword[node.text] or Kind.Unknown
end

function scanner.GetSourceTextOfNodeFromSourceFile(sourceFile, node, includeTrivia)
    return scanner.GetTextOfNodeFromSourceText(sourceFile:Text(), node, includeTrivia)
end

function scanner.isJSDocTypeExpressionOrChild(node)
    if ast.IsJSDocTypeExpression(node) then
        return true
    end
    if node.flags & (NodeFlags.JSDoc | NodeFlags.Reparsed) == 0 then
        return false
    end
    local current = node
    while current ~= nil do
        if ast.IsTypeNode(current) then
            return true
        end
        current = current.parent
    end
    return false
end

function scanner.normalizeJSDocTypeSourceText(text)
    local lineStarts = core.ComputeECMALineStarts(text)
    if #lineStarts == 1 then
        return scanner.stripLeadingJSDocComment(text)
    end

    local result = {}
    local newLine = core.NewLineKind_GetNewLineCharacter(core.NewLineKind.LF)
    for i1, lineStart in ipairs(lineStarts) do
        local i = i1 - 1
        if i > 0 then
            result[#result + 1] = newLine
        end
        local lineEnd = #text
        if i + 1 < #lineStarts then
            lineEnd = lineStarts[i + 2]
        end
        local line = trimRightFunc(ssub(text, lineStart + 1, lineEnd), stringutil.IsLineBreak)
        result[#result + 1] = scanner.stripLeadingJSDocComment(line)
    end
    return table.concat(result)
end

function scanner.stripLeadingJSDocComment(line)
    line = trimLeftFunc(line, stringutil.IsWhiteSpaceLike)
    if #line > 0 and string.byte(line, 1) == 42 --[['*']] then
        line = ssub(line, 2)
    end
    return trimLeftFunc(line, stringutil.IsWhiteSpaceLike)
end

function scanner.GetTextOfNodeFromSourceText(sourceText, node, includeTrivia)
    if ast.NodeIsMissing(node) then
        return ""
    end
    local pos = node:Pos()
    if not includeTrivia then
        pos = scanner.SkipTrivia(sourceText, pos)
    end
    local text = ssub(sourceText, pos + 1, node:End())
    if scanner.isJSDocTypeExpressionOrChild(node) then
        text = scanner.normalizeJSDocTypeSourceText(text)
    end
    if node.flags & NodeFlags.ReparserTransformedLiteral ~= 0 then
        -- This is similar to `getLiteralTextOfNode` in the printer, but without the context of an `emitContext` to provide overrides
        if ast.IsStringLiteral(node) then
            if node:AsStringLiteral().tokenFlags & TokenFlags.SingleQuote ~= 0 then
                return "'" .. text .. "'"
            end
            return "\"" .. text .. "\""
        elseif ast.IsIdentifier(node) then
            return node:Text()
        end
        -- Only the above node kinds are currently transformed into one another by the reparser, requiring the textual remapping.
        -- (Any reamppings done by emit transforms are handled by `getLiteralTextOfNode` in the printer)
        -- Fail on any other kinds.
        debug.FailBadSyntaxKind(node, "Unexpected reparser-transformed node kind")
    end
    return text
end

function scanner.GetTextOfNode(node)
    return scanner.GetSourceTextOfNodeFromSourceFile(ast.GetSourceFileOfNode(node), node, false --[[includeTrivia]])
end

function scanner.GetTextOfJSDocComment(comment)
    if comment == nil then
        return ""
    end
    local b = {}
    for _, n in ipairs(comment.nodes) do
        if n.kind == Kind.JSDocText then
            b[#b + 1] = n:Text()
        elseif n.kind == Kind.JSDocLink or n.kind == Kind.JSDocLinkCode or n.kind == Kind.JSDocLinkPlain then
            b[#b + 1] = scanner.GetTextOfNode(n)
        end
    end
    return trimRightFunc(table.concat(b), unicodeIsSpace)
end

function scanner.DeclarationNameToString(name)
    if name == nil or name:Pos() == name:End() then
        return "(Missing)"
    end
    return scanner.GetTextOfNode(name)
end

function scanner.IsIdentifierText(name, languageVariant)
    local ch, size = core.DecodeRune(name, 0)
    if not scanner.IsIdentifierStart(ch) then
        return false
    end
    local i = size
    while i < #name do
        ch, size = core.DecodeRune(name, i)
        if not scanner.IsIdentifierPartEx(ch, languageVariant) then
            return false
        end
        i = i + size
    end
    return true
end

function scanner.IsIntrinsicJsxName(name)
    if #name == 0 then
        return false
    end
    local c = string.byte(name, 1)
    return c >= 97 and c <= 122 or string.find(name, "-", 1, true) ~= nil
end
