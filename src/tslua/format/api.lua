local format = require("tslua.format")
local ast = require("tslua.ast")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local FormatRequestKind = format.FormatRequestKind

-- formatContextKey
format.formatOptionsKey = "format.formatOptionsKey"
format.formatNewlineKey = "format.formatNewlineKey"

function format.WithFormatCodeSettings(ctx, options, newLine)
    ctx = core.contextWithValue(ctx, format.formatOptionsKey, options)
    ctx = core.contextWithValue(ctx, format.formatNewlineKey, newLine)
    -- In strada, the rules map was both globally cached *and* cached into the context, for some reason. We skip that here and just use the global one.
    return ctx
end

function format.GetFormatCodeSettingsFromContext(ctx)
    local opt = core.contextValue(ctx, format.formatOptionsKey)
    if opt ~= nil then
        return opt
    end
    return lsutil.GetDefaultFormatCodeSettings()
end

function format.GetNewLineOrDefaultFromContext(ctx) -- TODO: Move into broader LS - more than just the formatter uses the newline editor setting/host new line
    local opt = format.GetFormatCodeSettingsFromContext(ctx)
    if #opt.newLineCharacter > 0 then
        return opt.newLineCharacter
    end
    local host = core.contextValue(ctx, format.formatNewlineKey)
    if host == nil then
        error("interface conversion: interface {} is nil, not string")
    end
    if #host > 0 then
        return host
    end
    return "\n"
end

function format.FormatSpan(ctx, span, file, kind)
    -- find the smallest node that fully wraps the range and compute the initial indentation for the node
    local enclosingNode = format.findEnclosingNode(span, file)
    local opts = format.GetFormatCodeSettingsFromContext(ctx)

    return format.newFormattingScanner(
        file:Text(),
        file.languageVariant,
        format.getScanStartPosition(enclosingNode, span, file),
        span:End(),
        format.newFormatSpanWorker(
            ctx,
            span,
            enclosingNode,
            format.GetIndentationForNode(enclosingNode, span, file, opts),
            format.getOwnOrInheritedDelta(enclosingNode, opts, file),
            kind,
            format.prepareRangeContainsErrorFunction(file:Diagnostics(), span),
            file
        )
    )
end

function format.FormatNodeGivenIndentation(ctx, node, file, languageVariant, initialIndentation, delta)
    local textRange = core.NewTextRange(node:Pos(), node:End())
    return format.newFormattingScanner(
        file:Text(),
        languageVariant,
        textRange:Pos(),
        textRange:End(),
        format.newFormatSpanWorker(
            ctx,
            textRange,
            node,
            initialIndentation,
            delta,
            FormatRequestKind.FormatSelection,
            function(_) return false end, -- assume that node does not have any errors
            file
        )
    )
end

function format.formatNodeLines(ctx, sourceFile, node, requestKind)
    if node == nil then
        return nil
    end
    local tokenStart = scanner.GetTokenPosOfNode(node, sourceFile, false)
    local lineStart = format.GetLineStartPositionForPosition(tokenStart, sourceFile)
    local span = core.NewTextRange(lineStart, node:End())
    return format.FormatSpan(ctx, span, sourceFile, requestKind)
end

function format.FormatDocument(ctx, sourceFile)
    return format.FormatSpan(ctx, core.NewTextRange(0, sourceFile:End()), sourceFile, FormatRequestKind.FormatDocument)
end

function format.FormatSelection(ctx, sourceFile, start, end_)
    return format.FormatSpan(ctx, core.NewTextRange(format.GetLineStartPositionForPosition(start, sourceFile), end_),
        sourceFile, FormatRequestKind.FormatSelection)
end

function format.FormatOnOpeningCurly(ctx, sourceFile, position)
    local openingCurly = format.findImmediatelyPrecedingTokenOfKind(position, Kind.OpenBraceToken, sourceFile)
    if openingCurly == nil then
        return nil
    end
    local curlyBraceRange = openingCurly.parent
    local outermostNode = format.findOutermostNodeWithinListLevel(curlyBraceRange)
    --[[*
     * We limit the span to end at the opening curly to handle the case where
     * the brace matched to that just typed will be incorrect after further edits.
     * For example, we could type the opening curly for the following method
     * body without brace-matching activated:
     * ```
     * class C {
     *     foo()
     * }
     * ```
     * and we wouldn't want to move the closing brace.
     ]]
    local textRange = core.NewTextRange(format.GetLineStartPositionForPosition(
        scanner.GetTokenPosOfNode(outermostNode, sourceFile, false), sourceFile), position)
    return format.FormatSpan(ctx, textRange, sourceFile, FormatRequestKind.FormatOnOpeningCurlyBrace)
end

function format.FormatOnClosingCurly(ctx, sourceFile, position)
    local precedingToken = format.findImmediatelyPrecedingTokenOfKind(position, Kind.CloseBraceToken, sourceFile)
    return format.formatNodeLines(ctx, sourceFile, format.findOutermostNodeWithinListLevel(precedingToken),
        FormatRequestKind.FormatOnClosingCurlyBrace)
end

function format.FormatOnSemicolon(ctx, sourceFile, position)
    local semicolon = format.findImmediatelyPrecedingTokenOfKind(position, Kind.SemicolonToken, sourceFile)
    return format.formatNodeLines(ctx, sourceFile, format.findOutermostNodeWithinListLevel(semicolon),
        FormatRequestKind.FormatOnSemicolon)
end

function format.FormatOnEnter(ctx, sourceFile, position)
    local line = scanner.GetECMALineOfPosition(sourceFile, position)
    if line == 0 then
        return nil
    end
    -- get start position for the previous line
    local startPos = scanner.GetECMALineStarts(sourceFile)[line]
    -- After the enter key, the cursor is now at a new line. The new line may or may not contain non-whitespace characters.
    -- If the new line has only whitespaces, we won't want to format this line, because that would remove the indentation as
    -- trailing whitespaces. So the end of the formatting span should be the later one between:
    --  1. the end of the previous line
    --  2. the last non-whitespace character in the current line
    local text = sourceFile:Text()
    local endOfFormatSpan = scanner.GetECMAEndLinePosition(sourceFile, line)
    while endOfFormatSpan > startPos do
        local ch, s = stringutil.DecodeRune(text, endOfFormatSpan)
        if s == 0 or stringutil.IsWhiteSpaceSingleLine(ch) then -- on multibyte character keep backing up
            endOfFormatSpan = endOfFormatSpan - 1
            goto continue
        end
        break
        ::continue::
    end

    -- if the character at the end of the span is a line break, we shouldn't include it, because it indicates we don't want to
    -- touch the current line at all. Also, on some OSes the line break consists of two characters (\r\n), we should test if the
    -- previous character before the end of format span is line break character as well.
    local ch = stringutil.DecodeRune(text, endOfFormatSpan)
    if stringutil.IsLineBreak(ch) then
        endOfFormatSpan = endOfFormatSpan - 1
    end

    local span = core.NewTextRange(
        startPos,
        -- end value is exclusive so add 1 to the result
        endOfFormatSpan + 1
    )

    return format.FormatSpan(ctx, span, sourceFile, FormatRequestKind.FormatOnEnter)
end
