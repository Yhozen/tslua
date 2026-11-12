local change = require("tslua.ls.change")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local format = require("tslua.format")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local parser = require("tslua.parser")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local LeadingTriviaOption = change.LeadingTriviaOption
local TrailingTriviaOption = change.TrailingTriviaOption

local Tracker = change.Tracker

local function rangeString(r)
    return string.format("{%d:%d-%d:%d}", r.start.line, r.start.character, r.end_.line, r.end_.character)
end

function Tracker:getTextChangesFromChanges()
    local changes = {}
    for _, sourceFile in ipairs(self.changedFiles) do
        local changesInFile = self.changes:Get(sourceFile)
        if self.unmappableFiles:Has(sourceFile:OriginalFileName()) then
            goto continue
        end
        do
            -- order changes by start position
            -- If the start position is the same, put the shorter range first, since an empty range (x, x) may precede (x, y) but not vice-versa.
            core.SortStableFunc(changesInFile, function(a, b)
                return lsproto.CompareRanges(a.range, b.range)
            end)
            -- verify that change intervals do not overlap, except possibly at end points.
            for i = 1, #changesInFile - 1 do
                if lsproto.ComparePositions(changesInFile[i].range.end_, changesInFile[i + 1].range.start) > 0 then
                    -- assert change[i].End <= change[i + 1].Start
                    error("changes overlap: " .. rangeString(changesInFile[i].range) .. " and " .. rangeString(changesInFile[i + 1].range), 0)
                end
            end

            local textChanges = core.MapNonNil(changesInFile, function(c)
                -- !!! targetSourceFile

                local newText = self:computeNewText(c, sourceFile, sourceFile)
                -- span := createTextSpanFromRange(c.Range)
                -- !!!
                -- Filter out redundant changes.
                -- if (span.length == newText.length && stringContainsAt(targetSourceFile.text, newText, span.start)) { return nil }

                return {
                    newText = newText,
                    range = c.range,
                }
            end)

            if core.Len(textChanges) > 0 then
                local fileName = sourceFile:OriginalFileName()
                if self.unmappableFiles:Has(fileName) then
                    goto continue
                end
                changes[fileName] = core.AppendAll(changes[fileName], textChanges)
            end
        end
        ::continue::
    end
    return changes
end

local function trimLeftSpace(s)
    local pos = 0
    while pos < #s do
        local r, size = core.DecodeRune(s, pos)
        if not stringutil.UnicodeIsSpace(r) then
            break
        end
        pos = pos + size
    end
    return string.sub(s, pos + 1)
end

function Tracker:computeNewText(c, targetSourceFile, sourceFile)
    if c.kind == change.trackerEditKindRemove then
        return ""
    elseif c.kind == change.trackerEditKindText then
        return c.newText
    end

    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, c.range.start, spanmap.Feature.All)
    local result = ""
    local found = false
    -- The original range may have multiple verbatim copies; it is safe to lose their identity only when
    -- formatting at every exact projection produces the same edit.
    for _, mapped in ipairs(positions) do
        if not spanmap.Fidelity_IsExact(mapped.fidelity) then
            goto continue
        end
        do
            local projection = mapped.script
            local pos = mapped.position
            local formatNode = function(n)
                return self:getFormattedTextOfNode(n, targetSourceFile, projection, pos, c.options)
            end

            local text
            if c.kind == change.trackerEditKindReplaceWithMultipleNodes then
                local joiner = c.options.joiner
                if joiner == "" then
                    joiner = self.newLine
                end
                local parts = core.Map(c.nodes, function(n)
                    local s = formatNode(n)
                    if self.newLine ~= "" and string.sub(s, -#self.newLine) == self.newLine then
                        s = string.sub(s, 1, #s - #self.newLine)
                    end
                    return s
                end)
                text = table.concat(parts, joiner)
            elseif c.kind == change.trackerEditKindReplaceWithSingleNode then
                text = formatNode(c.node)
            else
                error(string.format("change kind %d should have been handled earlier", c.kind), 0)
            end
            -- Strip initial indentation if text will be inserted in the middle of the line.
            local noIndent = text
            if not (c.options.indentation ~= nil or format.GetLineStartPositionForPosition(pos, projection) == pos) then
                noIndent = trimLeftSpace(text)
            end
            local suffix = c.options.suffix
            local hasSuffix = suffix == "" or string.sub(noIndent, -#suffix) == suffix
            local candidate = c.options.prefix .. noIndent .. (hasSuffix and "" or suffix)
            if found and candidate ~= result then
                self.unmappableFiles:Add(sourceFile:OriginalFileName())
                return ""
            end
            result = candidate
            found = true
        end
        ::continue::
    end
    if not found then
        self.unmappableFiles:Add(sourceFile:OriginalFileName())
    end
    return result
end

--[[ Note: this may mutate `nodeIn`. ]]
function Tracker:getFormattedTextOfNode(nodeIn, targetSourceFile, sourceFile, pos, options)
    local text, sourceFileLike = self:getNonformattedText(nodeIn, targetSourceFile)
    -- !!! if (validate) validate(node, text);
    local formatOptions = change.GetFormatCodeSettingsForWriting(self.formatSettings, targetSourceFile)

    local initialIndentation, delta = 0, 0
    if options.indentation == nil then
        initialIndentation = format.GetIndentation(pos, sourceFile, formatOptions, options.prefix == self.newLine or format.GetLineStartPositionForPosition(pos, sourceFile) == pos)
    else
        initialIndentation = options.indentation
    end

    if options.delta ~= nil then
        delta = options.delta
    elseif formatOptions.indentSize ~= 0 and format.ShouldIndentChildNode(formatOptions, nodeIn, nil, nil) then
        delta = formatOptions.indentSize
    end

    local changes = format.FormatNodeGivenIndentation(self.ctx, sourceFileLike, sourceFileLike:AsSourceFile(), targetSourceFile.languageVariant, initialIndentation, delta)
    return core.ApplyBulkEdits(text, changes)
end

function change.GetFormatCodeSettingsForWriting(options, sourceFile)
    local shouldAutoDetectSemicolonPreference = options.semicolons == lsutil.SemicolonPreference.Ignore
    local shouldRemoveSemicolons = options.semicolons == lsutil.SemicolonPreference.Remove or shouldAutoDetectSemicolonPreference and not lsutil.ProbablyUsesSemicolons(sourceFile)
    if shouldRemoveSemicolons then
        options = options:Clone()
        options.semicolons = lsutil.SemicolonPreference.Remove
    end

    return options
end

-- Returns (text, *ast.Node).
function Tracker:getNonformattedText(node, sourceFile)
    local text, nodeOut = printer.PrintAndPositionNode(self.nodeFactory, node, sourceFile, self.newLine, self.formatSettings.indentSize, self.emitContext)
    local sourceFileLike = printer.CreateSyntheticSourceFile(
        self.nodeFactory,
        nodeOut,
        text,
        ast.NewSourceFileParseOptions(sourceFile:FileName(), sourceFile:Path())
    )
    return text, sourceFileLike:AsNode()
end

-- method on the changeTracker because use of converters
-- GetAdjustedRange computes the adjusted range for a node in a source file, accounting for trivia.
function Tracker:GetAdjustedRange(sourceFile, startNode, endNode, leadingOption, trailingOption)
    return self:toLSPEditRange(
        sourceFile,
        core.NewTextRange(
            self:getAdjustedStartPosition(sourceFile, startNode, leadingOption, false),
            self:getAdjustedEndPosition(sourceFile, endNode, trailingOption)
        )
    )
end

-- method on the changeTracker because use of converters
function Tracker:getAdjustedStartPosition(sourceFile, node, leadingOption, hasTrailingComment)
    if leadingOption == LeadingTriviaOption.JSDoc then
        local JSDocComments = parser.GetJSDocCommentRanges(self.nodeFactory, nil, node, sourceFile:Text())
        if core.Len(JSDocComments) > 0 then
            return format.GetLineStartPositionForPosition(JSDocComments[1]:Pos(), sourceFile)
        end
    end

    local start = astnav.GetStartOfNode(node, sourceFile, false)
    local startOfLinePos = format.GetLineStartPositionForPosition(start, sourceFile)

    if leadingOption == LeadingTriviaOption.Exclude then
        return start
    elseif leadingOption == LeadingTriviaOption.StartLine then
        if node.loc:ContainsInclusive(startOfLinePos) then
            return startOfLinePos
        end
        return start
    end

    local fullStart = node:Pos()
    if fullStart == start then
        return start
    end
    local lineStarts = sourceFile:ECMALineMap()
    local fullStartLineIndex = scanner.ComputeLineOfPosition(lineStarts, fullStart)
    local fullStartLinePos = lineStarts[fullStartLineIndex + 1]
    if startOfLinePos == fullStartLinePos then
        -- full start and start of the node are on the same line
        --   a,     b;
        --    ^     ^
        --    |   start
        -- fullstart
        -- when b is replaced - we usually want to keep the leading trvia
        -- when b is deleted - we delete it
        if leadingOption == LeadingTriviaOption.IncludeAll then
            return fullStart
        end
        return start
    end

    -- if node has a trailing comments, use comment end position as the text has already been included.
    if hasTrailingComment then
        -- Check first for leading comments as if the node is the first import, we want to exclude the trivia;
        -- otherwise we get the trailing comments.
        local comments = core.Collect(scanner.GetLeadingCommentRanges(self.nodeFactory, sourceFile:Text(), fullStart))
        if #comments == 0 then
            comments = core.Collect(scanner.GetTrailingCommentRanges(self.nodeFactory, sourceFile:Text(), fullStart))
        end
        if #comments > 0 then
            return scanner.SkipTriviaEx(sourceFile:Text(), comments[1]:End(), { stopAfterLineBreak = true, stopAtComments = true })
        end
    end

    -- get start position of the line following the line that contains fullstart position
    -- (but only if the fullstart isn't the very beginning of the file)
    local nextLineStart = fullStart > 0 and 1 or 0
    local adjustedStartPosition = lineStarts[fullStartLineIndex + nextLineStart + 1]
    -- skip whitespaces/newlines
    adjustedStartPosition = scanner.SkipTriviaEx(sourceFile:Text(), adjustedStartPosition, { stopAtComments = true })
    return lineStarts[scanner.ComputeLineOfPosition(lineStarts, adjustedStartPosition) + 1]
end

-- method on the changeTracker because of converters
-- Return the end position of a multiline comment of it is on another line; otherwise returns `undefined`;
function Tracker:getEndPositionOfMultilineTrailingComment(sourceFile, node, trailingOpt)
    if trailingOpt == TrailingTriviaOption.Include then
        -- If the trailing comment is a multiline comment that extends to the next lines,
        -- return the end of the comment and track it for the next nodes to adjust.
        local lineStarts = sourceFile:ECMALineMap()
        local nodeEndLine = scanner.ComputeLineOfPosition(lineStarts, node:End())
        for comment in scanner.GetTrailingCommentRanges(self.nodeFactory, sourceFile:Text(), node:End()) do
            -- Single line can break the loop as trivia will only be this line.
            -- Comments on subsequent lines are also ignored.
            if comment.kind == Kind.SingleLineCommentTrivia or scanner.ComputeLineOfPosition(lineStarts, comment:Pos()) > nodeEndLine then
                break
            end

            -- Get the end line of the comment and compare against the end line of the node.
            -- If the comment end line position and the multiline comment extends to multiple lines,
            -- then is safe to return the end position.
            local commentEndLine = scanner.ComputeLineOfPosition(lineStarts, comment:End())
            if commentEndLine > nodeEndLine then
                return scanner.SkipTriviaEx(sourceFile:Text(), comment:End(), { stopAfterLineBreak = true, stopAtComments = true })
            end
        end
    end

    return 0
end

-- method on the changeTracker because of converters
function Tracker:getAdjustedEndPosition(sourceFile, node, trailingTriviaOption)
    if trailingTriviaOption == TrailingTriviaOption.Exclude then
        return node:End()
    end
    if trailingTriviaOption == TrailingTriviaOption.ExcludeWhitespace then
        local comments = core.Collect(scanner.GetTrailingCommentRanges(self.nodeFactory, sourceFile:Text(), node:End()))
        for c in scanner.GetLeadingCommentRanges(self.nodeFactory, sourceFile:Text(), node:End()) do
            comments[#comments + 1] = c
        end
        if #comments > 0 then
            local realEnd = comments[#comments]:End()
            if realEnd ~= 0 then
                return realEnd
            end
        end
        return node:End()
    end

    local multilineEndPosition = self:getEndPositionOfMultilineTrailingComment(sourceFile, node, trailingTriviaOption)
    if multilineEndPosition ~= 0 then
        return multilineEndPosition
    end

    local newEnd = scanner.SkipTriviaEx(sourceFile:Text(), node:End(), { stopAfterLineBreak = true })

    if newEnd ~= node:End() and (trailingTriviaOption == TrailingTriviaOption.Include or stringutil.IsLineBreak(string.byte(sourceFile:Text(), newEnd))) then
        return newEnd
    end
    return node:End()
end

-- ============= utilities =============

function change.hasCommentsBeforeLineBreak(text, start)
    for _, ch in core.Runes(string.sub(text, start + 1)) do
        if not stringutil.IsWhiteSpaceSingleLine(ch) then
            return ch == 0x2F
        end
    end
    return false
end

function change.needSemicolonBetween(a, b)
    return (ast.IsPropertySignatureDeclaration(a) or ast.IsPropertyDeclaration(a)) and
        ast.IsClassOrTypeElement(b) and
        b:Name().kind == Kind.ComputedPropertyName or
        ast.IsStatementButNotDeclaration(a) and
        ast.IsStatementButNotDeclaration(b) -- TODO: only if b would start with a `(` or `[`
end

function Tracker:getInsertionPositionAtSourceFileTop(sourceFile)
    local lastPrologue
    for _, node in ipairs(sourceFile.statements.nodes) do
        if ast.IsPrologueDirective(node) then
            lastPrologue = node
        else
            break
        end
    end

    local position = 0
    local text = sourceFile:Text()
    local advancePastLineBreak = function()
        if position >= #text then
            return
        end
        local char = string.byte(text, position + 1)
        if stringutil.IsLineBreak(char) then
            position = position + 1
            if position < #text and char == 0x0D and string.byte(text, position + 1) == 0x0A then
                position = position + 1
            end
        end
    end
    if lastPrologue ~= nil then
        position = lastPrologue:End()
        advancePastLineBreak()
        return position
    end

    local shebang = scanner.GetShebang(text)
    if shebang ~= "" then
        position = #shebang
        advancePastLineBreak()
    end

    local ranges = core.Collect(scanner.GetLeadingCommentRanges(self.nodeFactory, text, position))
    if #ranges == 0 then
        return position
    end
    -- Find the first attached comment to the first node and add before it
    local lastComment
    local pinnedOrTripleSlash = false
    local firstNodeLine = -1

    local lenStatements = #sourceFile.statements.nodes
    local lineMap = sourceFile:ECMALineMap()
    for _, r in ipairs(ranges) do
        if r.kind == Kind.MultiLineCommentTrivia then
            if printer.IsPinnedComment(text, r) then
                lastComment = r
                pinnedOrTripleSlash = true
                goto continue
            end
        elseif printer.IsRecognizedTripleSlashComment(text, r) then
            lastComment = r
            pinnedOrTripleSlash = true
            goto continue
        end

        if lastComment ~= nil then
            -- Always insert after pinned or triple slash comments
            if pinnedOrTripleSlash then
                break
            end

            -- There was a blank line between the last comment and this comment.
            -- This comment is not part of the copyright comments
            local commentLine = scanner.ComputeLineOfPosition(lineMap, r:Pos())
            local lastCommentEndLine = scanner.ComputeLineOfPosition(lineMap, lastComment:End())
            if commentLine >= lastCommentEndLine + 2 then
                break
            end
        end

        if lenStatements > 0 then
            if firstNodeLine == -1 then
                firstNodeLine = scanner.ComputeLineOfPosition(lineMap, astnav.GetStartOfNode(sourceFile.statements.nodes[1], sourceFile, false))
            end
            local commentEndLine = scanner.ComputeLineOfPosition(lineMap, r:End())
            if firstNodeLine < commentEndLine + 2 then
                break
            end
        end
        lastComment = r
        pinnedOrTripleSlash = false
        ::continue::
    end

    if lastComment ~= nil then
        position = lastComment:End()
        advancePastLineBreak()
    end
    return position
end
