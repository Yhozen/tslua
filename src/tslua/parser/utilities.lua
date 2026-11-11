local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local ScriptKind = core.ScriptKind
local LanguageVariant = core.LanguageVariant

function parser.getLanguageVariant(scriptKind)
    if scriptKind == ScriptKind.TSX or scriptKind == ScriptKind.JSX or scriptKind == ScriptKind.JS or scriptKind == ScriptKind.JSON then
        -- .tsx and .jsx files are treated as jsx language variant.
        return LanguageVariant.JSX
    end
    return LanguageVariant.Standard
end

function parser.tokenIsIdentifierOrKeyword(token)
    return token >= Kind.Identifier
end

function parser.tokenIsIdentifierOrKeywordOrGreaterThan(token)
    return token == Kind.GreaterThanToken or parser.tokenIsIdentifierOrKeyword(token)
end

function parser.GetJSDocCommentRanges(f, commentRanges, node, text)
    commentRanges = commentRanges or {}
    local k = node.kind
    if k == Kind.Parameter or k == Kind.TypeParameter or k == Kind.FunctionExpression or k == Kind.ArrowFunction or
        k == Kind.ParenthesizedExpression or k == Kind.VariableDeclaration or k == Kind.ExportSpecifier then
        for commentRange in scanner.GetTrailingCommentRanges(f, text, node:Pos()) do
            commentRanges[#commentRanges + 1] = commentRange
        end
        for commentRange in scanner.GetLeadingCommentRanges(f, text, node:Pos()) do
            commentRanges[#commentRanges + 1] = commentRange
        end
    else
        for commentRange in scanner.GetLeadingCommentRanges(f, text, node:Pos()) do
            commentRanges[#commentRanges + 1] = commentRange
        end
    end
    -- Keep if the comment starts with '/**' but not if it is '/**/'
    local result = {}
    for _, comment in ipairs(commentRanges) do
        local commentStart = comment:Pos()
        local commentLen = comment:End() - commentStart
        local drop = comment:End() > node:End() or commentLen < 4 or string.byte(text, commentStart + 2) ~= 42 or
            string.byte(text, commentStart + 3) ~= 42 or string.byte(text, commentStart + 4) == 47
        if not drop then
            result[#result + 1] = comment
        end
    end
    return result
end

function parser.isKeywordOrPunctuation(token)
    return ast.IsKeywordKind(token) or ast.IsPunctuationKind(token)
end

function parser.isJSDocLikeText(text)
    return #text >= 4 and string.byte(text, 2) == 42 and string.byte(text, 3) == 42 and string.byte(text, 4) ~= 47
end
