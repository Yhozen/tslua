local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local format = require("tslua.format")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local LanguageService = ls.LanguageService

function LanguageService:toLSProtoTextEdits(file, changes)
    local result = {}
    for _, c in ipairs(changes or {}) do
        local lspRange, fidelity = self.converters:ToLSPRange(file, core.NewTextRange(c:Pos(), c:End()))
        if not spanmap.Fidelity_IsExact(fidelity) then
            return nil
        end
        result[#result + 1] = {
            newText = c.newText,
            range = lspRange,
        }
    end
    return result
end

-- Responses are the lsproto.TextEditsOrNull union: { textEdits = [...] } or {} (null).
function LanguageService:ProvideFormatDocument(ctx, documentURI, options)
    if core.Tristate_IsFalse(self:UserPreferences().enableFormatting) then
        return {}, nil
    end
    local _, file = self:getProgramAndFile(documentURI)
    local formatOpts = lsutil.FromLSFormatOptions(self:FormatOptions(), options)
    local edits = self:toLSProtoTextEdits(file, self:getFormattingEditsForDocument(
        ctx,
        file,
        formatOpts
    ))
    return { textEdits = edits }, nil
end

function LanguageService:ProvideFormatDocumentRange(ctx, documentURI, options, r)
    if core.Tristate_IsFalse(self:UserPreferences().enableFormatting) then
        return {}, nil
    end
    local _, file = self:getProgramAndFile(documentURI)
    local formatOpts = lsutil.FromLSFormatOptions(self:FormatOptions(), options)
    local ranges = lsconv.FromLSPRangeForSourceFile(self.converters, file, r, spanmap.Feature.Formatting)
    if #ranges ~= 1 or not spanmap.Fidelity_IsExact(ranges[1].fidelity) then
        return {}, nil
    end
    file = ranges[1].script
    local edits = self:toLSProtoTextEdits(file, self:getFormattingEditsForRange(
        ctx,
        file,
        formatOpts,
        ranges[1].span
    ))
    return { textEdits = edits }, nil
end

function LanguageService:ProvideFormatDocumentOnType(ctx, documentURI, options, position, character)
    if core.Tristate_IsFalse(self:UserPreferences().enableFormatting) then
        return {}, nil
    end
    local _, file = self:getProgramAndFile(documentURI)
    local formatOpts = lsutil.FromLSFormatOptions(self:FormatOptions(), options)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, position, spanmap.Feature.Formatting)
    if #positions ~= 1 or not spanmap.Fidelity_IsExact(positions[1].fidelity) then
        return {}, nil
    end
    file = positions[1].script
    local edits = self:toLSProtoTextEdits(file, self:getFormattingEditsAfterKeystroke(
        ctx,
        file,
        formatOpts,
        positions[1].position,
        character
    ))
    return { textEdits = edits }, nil
end

function LanguageService:getFormattingEditsForRange(ctx, file, options, r)
    ctx = format.WithFormatCodeSettings(ctx, options, options.newLineCharacter)
    return format.FormatSelection(ctx, file, r:Pos(), r:End())
end

function LanguageService:getFormattingEditsForDocument(ctx, file, options)
    ctx = format.WithFormatCodeSettings(ctx, options, options.newLineCharacter)
    return format.FormatDocument(ctx, file)
end

function LanguageService:getFormattingEditsAfterKeystroke(ctx, file, options, position, key)
    ctx = format.WithFormatCodeSettings(ctx, options, options.newLineCharacter)

    local tokenAtPosition = astnav.GetTokenAtPosition(file, position)
    if ls.isInComment(file, position, tokenAtPosition) == nil then
        if key == "{" then
            return format.FormatOnOpeningCurly(ctx, file, position)
        elseif key == "}" then
            return format.FormatOnClosingCurly(ctx, file, position)
        elseif key == ";" then
            return format.FormatOnSemicolon(ctx, file, position)
        elseif key == "\n" then
            return format.FormatOnEnter(ctx, file, position)
        else
            return nil
        end
    end
    return nil
end

-- Unlike the TS implementation, this function *will not* compute default values for
-- `precedingToken` and `tokenAtPosition`.
-- It is the caller's responsibility to call `astnav.GetTokenAtPosition` to compute a default `tokenAtPosition`,
-- or `astnav.FindPrecedingToken` to compute a default `precedingToken`.
function ls.getRangeOfEnclosingComment(file, position, precedingToken, tokenAtPosition)
    local jsdoc = ast.FindAncestor(tokenAtPosition, function(n)
        return n:IsJSDoc()
    end)
    if jsdoc ~= nil then
        tokenAtPosition = jsdoc.parent
    end
    local tokenStart = astnav.GetStartOfNode(tokenAtPosition, file, false --[[includeJSDoc]])
    if tokenStart <= position and position < tokenAtPosition:End() then
        return nil
    end

    -- Between two consecutive tokens, all comments are either trailing on the former
    -- or leading on the latter (and none are in both lists).
    local trailingRangesOfPreviousToken
    if precedingToken ~= nil then
        trailingRangesOfPreviousToken = core.Collect(scanner.GetTrailingCommentRanges(ast.NewNodeFactory({}), file:Text(), precedingToken:End()))
    end
    local leadingRangesOfNextToken = core.Collect(ls.getLeadingCommentRangesOfNode(tokenAtPosition, file))
    for commentRange in core.ConcatenateSeq(trailingRangesOfPreviousToken, leadingRangesOfNextToken) do
        -- The end marker of a single-line comment does not include the newline character.
        -- In the following case where the cursor is at `^`, we are inside a comment:
        --
        --    // asdf   ^\n
        --
        -- But for closed multi-line comments, we don't want to be inside the comment in the following case:
        --
        --    /* asdf */^
        --
        -- Internally, we represent the end of the comment prior to the newline and at the '/', respectively.
        --
        -- However, unterminated multi-line comments lack a `/`, end at the end of the file, and *do* contain their end.
        --
        if commentRange:ContainsExclusive(position) or
            position == commentRange:End() and
            (commentRange.kind == ast.Kind.SingleLineCommentTrivia or position == #file:Text()) then
            return commentRange
        end
    end
    return nil
end
