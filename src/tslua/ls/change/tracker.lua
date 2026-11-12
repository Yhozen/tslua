local change = require("tslua.ls.change")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local collections = require("tslua.collections")
local core = require("tslua.core")
local format = require("tslua.format")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local LeadingTriviaOption = change.LeadingTriviaOption
local TrailingTriviaOption = change.TrailingTriviaOption

-- NodeOptions is a Go value struct:
-- {
--   prefix = string,            -- Text to be inserted before the new node
--   suffix = string,            -- Text to be inserted after the new node
--   indentation = int or nil,   -- Text of inserted node will be formatted with this indentation, otherwise indentation will be inferred from the old node
--   delta = int or nil,         -- Text of inserted node will be formatted with this delta, otherwise delta will be inferred from the new node kind
--   leadingTriviaOption = LeadingTriviaOption,   (embedded)
--   trailingTriviaOption = TrailingTriviaOption, (embedded)
--   joiner = string,
-- }
-- NodeOptions_new(init) is Go's `NodeOptions{...}` (zero values filled in).
function change.NodeOptions_new(init)
    init = init or {}
    return {
        prefix = init.prefix or "",
        suffix = init.suffix or "",
        indentation = init.indentation,
        delta = init.delta,
        leadingTriviaOption = init.leadingTriviaOption or LeadingTriviaOption.None,
        trailingTriviaOption = init.trailingTriviaOption or TrailingTriviaOption.None,
        joiner = init.joiner or "",
    }
end

local function copyNodeOptions(o)
    return change.NodeOptions_new(o)
end

change.trackerEditKindText = 1
change.trackerEditKindRemove = 2
change.trackerEditKindReplaceWithSingleNode = 3
change.trackerEditKindReplaceWithMultipleNodes = 4

-- trackerEdit: { kind, range (lsproto.Range, embedded), newText (kind == text), node (single),
--   nodes (multiple), options (NodeOptions) }

-- nodesInsertedAtStartState: { node, sourceFile }

-- Tracker embeds *printer.EmitContext and *ast.NodeFactory: they are the fields emitContext and
-- nodeFactory, and their methods are promoted (callable on the tracker).
local Tracker = change.Tracker
Tracker.__index = function(self, k)
    local m = Tracker[k]
    if m ~= nil then
        return m
    end
    local nf = rawget(self, "nodeFactory")
    if nf ~= nil then
        local fm = nf[k]
        if type(fm) == "function" then
            return function(_, ...)
                return fm(nf, ...)
            end
        end
    end
    local ec = rawget(self, "emitContext")
    if ec ~= nil then
        local em = ec[k]
        if type(em) == "function" then
            return function(_, ...)
                return em(ec, ...)
            end
        end
    end
    return nil
end

-- deletedNode: { sourceFile, node }

function change.NewTracker(ctx, compilerOptions, formatOptions, converters)
    local emitContext = printer.NewEmitContext()
    local newLine = core.NewLineKind_GetNewLineCharacter(compilerOptions.newLine)
    ctx = format.WithFormatCodeSettings(ctx, formatOptions, newLine) -- !!! formatSettings in context?
    return setmetatable({
        emitContext = emitContext,
        nodeFactory = emitContext.factory,
        changes = collections.NewMultiMap(),
        changedFiles = {}, -- source files of changes, in insertion order (Go map iteration)
        ctx = ctx,
        converters = converters,
        formatSettings = formatOptions,
        newLine = newLine,
        deletedNodes = {},
        nodesWithInsertionsAtStart = {},
        nodesWithInsertionsAtStartOrder = {},
        -- unmappableFiles collects the files for which an edit could not be represented within a single
        -- verbatim span of the original text. GetChanges drops their edits so a partial, corrupting change is
        -- never emitted for a content-mapped file.
        unmappableFiles = collections.NewSet(),
        -- created during call to getChanges
        writer = nil,
    }, Tracker)
end

function Tracker:addChange(sourceFile, edit)
    if not self.changes:Has(sourceFile) then
        self.changedFiles[#self.changedFiles + 1] = sourceFile
    end
    self.changes:Add(sourceFile, edit)
end

-- GetChanges returns the accumulated text edits grouped by file name. Any file whose edits could not be
-- faithfully mapped back onto content-mapped original text is omitted from the returned map, and its name
-- is included in the returned slice. Dropping the whole file (rather than the individual edit) keeps a
-- logical change atomic, and returning the result inline means a caller cannot forget to check it or
-- accidentally emit a partial, corrupting change.
-- Note: after calling this, the Tracker object must be discarded!
-- Returns (map[fileName][]*lsproto.TextEdit, []string).
function Tracker:GetChanges()
    self:finishDeleteDeclarations()
    self:finishNodesWithInsertionsAtStart()
    local changes = self:getTextChangesFromChanges()
    -- !!! changes for new files
    if self.unmappableFiles:Len() == 0 then
        return changes, nil
    end
    local unmappable = {}
    for fileName in self.unmappableFiles:Keys() do
        changes[fileName] = nil
        unmappable[#unmappable + 1] = fileName
    end
    table.sort(unmappable)
    return changes, unmappable
end

-- toLSPEditRange converts a transformed-text range to an LSP range for an edit, mapping through the
-- content mapper's span map when the file is content-mapped. If the range does not fall entirely within a
-- single verbatim span the edit cannot be represented safely in the original text: the file is recorded so
-- GetChanges drops its edits, and a best-effort range is returned so the accumulated edits stay well-formed.
function Tracker:toLSPEditRange(sourceFile, textRange)
    local r, fidelity = self.converters:ToLSPRange(sourceFile, textRange)
    if not spanmap.Fidelity_IsExact(fidelity) then
        -- The range does not map into a single verbatim span, so the edit cannot be represented safely in
        -- the original text. Record the file so GetChanges drops its edits, keeping the best-effort range so
        -- the accumulated edits stay well-formed.
        self.unmappableFiles:Add(sourceFile:OriginalFileName())
    end
    return r
end

-- toLSPEditPos converts a transformed-text offset to an LSP position for a zero-length edit (an insertion),
-- applying the same content-mapping safety check as toLSPEditRange.
function Tracker:toLSPEditPos(sourceFile, pos)
    return self:toLSPEditRange(sourceFile, core.NewTextRange(pos, pos)).start
end

local function newRange(start, end_)
    return { start = start, end_ = end_ }
end

function Tracker:ReplaceNode(sourceFile, oldNode, newNode, options)
    if options == nil then
        -- defaults to `useNonAdjustedPositions`
        options = change.NodeOptions_new({
            leadingTriviaOption = LeadingTriviaOption.Exclude,
            trailingTriviaOption = TrailingTriviaOption.Exclude,
        })
    end
    self:ReplaceRange(sourceFile, self:GetAdjustedRange(sourceFile, oldNode, oldNode, options.leadingTriviaOption, options.trailingTriviaOption), newNode, copyNodeOptions(options))
end

function Tracker:ReplaceNodeWithNodes(sourceFile, oldNode, newNodes, options)
    if options == nil then
        options = change.NodeOptions_new({
            leadingTriviaOption = LeadingTriviaOption.Exclude,
            trailingTriviaOption = TrailingTriviaOption.Exclude,
        })
    end
    self:ReplaceRangeWithNodes(sourceFile, self:GetAdjustedRange(sourceFile, oldNode, oldNode, options.leadingTriviaOption, options.trailingTriviaOption), newNodes, copyNodeOptions(options))
end

function Tracker:ReplaceRange(sourceFile, lsprotoRange, newNode, options)
    self:addChange(sourceFile, { kind = change.trackerEditKindReplaceWithSingleNode, range = lsprotoRange, newText = "", options = copyNodeOptions(options), node = newNode })
end

function Tracker:ReplaceRangeWithText(sourceFile, lsprotoRange, text)
    self:addChange(sourceFile, { kind = change.trackerEditKindText, range = lsprotoRange, newText = text, options = change.NodeOptions_new() })
end

-- ReplaceTextRangeWithText replaces textRange (in transformed-text coordinates) with text, mapping the
-- range through the content-mapping guard so an edit that cannot be represented in the original text marks
-- the file unmappable and is dropped by GetChanges.
function Tracker:ReplaceTextRangeWithText(sourceFile, textRange, text)
    self:ReplaceRangeWithText(sourceFile, self:toLSPEditRange(sourceFile, textRange), text)
end

function Tracker:ReplaceRangeWithNodes(sourceFile, lsprotoRange, newNodes, options)
    if core.Len(newNodes) == 1 then
        self:ReplaceRange(sourceFile, lsprotoRange, newNodes[1], options)
        return
    end
    self:addChange(sourceFile, { kind = change.trackerEditKindReplaceWithMultipleNodes, range = lsprotoRange, newText = "", nodes = newNodes, options = copyNodeOptions(options) })
end

function Tracker:InsertText(sourceFile, pos, text)
    self:ReplaceRangeWithText(sourceFile, newRange(pos, pos), text)
end

function Tracker:InsertNodeAt(sourceFile, pos, newNode, options)
    local lsPos = self:toLSPEditPos(sourceFile, pos)
    self:ReplaceRange(sourceFile, newRange(lsPos, lsPos), newNode, options)
end

function Tracker:InsertNodesAt(sourceFile, pos, newNodes, options)
    local lsPos = self:toLSPEditPos(sourceFile, pos)
    self:ReplaceRangeWithNodes(sourceFile, newRange(lsPos, lsPos), newNodes, options)
end

function Tracker:InsertNodeAfter(sourceFile, after, newNode)
    local endPosition = self:endPosForInsertNodeAfter(sourceFile, after, newNode)
    self:InsertNodeAt(sourceFile, endPosition, newNode, self:getInsertNodeAfterOptions(sourceFile, after))
end

function Tracker:InsertNodesAfter(sourceFile, after, newNodes)
    local endPosition = self:endPosForInsertNodeAfter(sourceFile, after, newNodes[1])
    self:InsertNodesAt(sourceFile, endPosition, newNodes, self:getInsertNodeAfterOptions(sourceFile, after))
end

function Tracker:InsertNodeBefore(sourceFile, before, newNode, blankLineBetween, leadingTriviaOption)
    self:InsertNodeAt(sourceFile, self:getAdjustedStartPosition(sourceFile, before, leadingTriviaOption, false), newNode, self:getOptionsForInsertNodeBefore(before, newNode, blankLineBetween))
end

-- TryInsertTypeAnnotation inserts a type annotation after the appropriate position on a node
-- (after the close paren for function-like, after the name/exclamation/question for variable-like).
-- Returns true if successful.
function Tracker:TryInsertTypeAnnotation(sourceFile, node, typeNode)
    local endNode
    if ast.IsFunctionLike(node) then
        endNode = astnav.FindChildOfKind(node, Kind.CloseParenToken, sourceFile)
        if endNode == nil then
            if not ast.IsArrowFunction(node) then
                return false
            end
            -- If no `)`, is an arrow function `x => x`, so use the end of the first parameter
            local params = node:Parameters()
            if core.Len(params) == 0 then
                return false
            end
            endNode = params[1]
        end
    else
        local kind = node.kind
        if kind == Kind.VariableDeclaration then
            endNode = node:AsVariableDeclaration().exclamationToken
        elseif kind == Kind.PropertySignature then
            endNode = node:AsPropertySignatureDeclaration().postfixToken
        elseif kind == Kind.PropertyDeclaration then
            endNode = node:AsPropertyDeclaration().postfixToken
        elseif kind == Kind.Parameter then
            endNode = node:AsParameterDeclaration().questionToken
        end
        if endNode == nil then
            endNode = node:Name()
        end
    end
    if endNode == nil then
        return false
    end
    self:InsertNodeAt(sourceFile, endNode:End(), typeNode, change.NodeOptions_new({ prefix = ": " }))
    return true
end

-- ParenthesizeArrowParameters wraps the parameters of a paren-less arrow function in `(` and `)`.
-- This is a no-op if the arrow function already has parens.
function Tracker:ParenthesizeArrowParameters(sourceFile, arrowFunc)
    if astnav.FindChildOfKind(arrowFunc, Kind.CloseParenToken, sourceFile) ~= nil then
        return
    end
    local params = arrowFunc:Parameters()
    if core.Len(params) == 0 then
        return
    end
    local firstParam = params[1]
    local lastParam = params[#params]
    local startPos = astnav.GetStartOfNode(firstParam, sourceFile, false)
    self:InsertText(sourceFile, self:toLSPEditPos(sourceFile, startPos), "(")
    self:InsertText(sourceFile, self:toLSPEditPos(sourceFile, lastParam:End()), ")")
end

-- InsertModifierBefore inserts a modifier token (like 'type') before a node with a trailing space.
function Tracker:InsertModifierBefore(sourceFile, modifier, before)
    local pos = astnav.GetStartOfNode(before, sourceFile, false)
    local token = self.nodeFactory:NewToken(modifier)
    token.loc = core.NewTextRange(pos, pos)
    token.parent = before.parent
    self:InsertNodeAt(sourceFile, pos, token, change.NodeOptions_new({ suffix = " " }))
end

-- Delete queues a node for deletion with smart handling of list items, imports, etc.
-- The actual deletion happens in finishDeleteDeclarations during GetChanges.
function Tracker:Delete(sourceFile, node)
    self.deletedNodes[#self.deletedNodes + 1] = { sourceFile = sourceFile, node = node }
end

-- DeleteRange deletes a text range from the source file.
function Tracker:DeleteRange(sourceFile, textRange)
    local lspRange = self:toLSPEditRange(sourceFile, textRange)
    self:ReplaceRangeWithText(sourceFile, lspRange, "")
end

-- DeleteNode deletes a node immediately with specified trivia options.
-- Stop! Consider using Delete instead, which has logic for deleting nodes from delimited lists.
function Tracker:DeleteNode(sourceFile, node, leadingTrivia, trailingTrivia)
    local rng = self:GetAdjustedRange(sourceFile, node, node, leadingTrivia, trailingTrivia)
    self:ReplaceRangeWithText(sourceFile, rng, "")
end

-- DeleteNodeRange deletes a range of nodes with specified trivia options.
function Tracker:DeleteNodeRange(sourceFile, startNode, endNode, leadingTrivia, trailingTrivia)
    local startPosition = self:getAdjustedStartPosition(sourceFile, startNode, leadingTrivia, false)
    local endPosition = self:getAdjustedEndPosition(sourceFile, endNode, trailingTrivia)
    self:ReplaceRangeWithText(sourceFile, self:toLSPEditRange(sourceFile, core.NewTextRange(startPosition, endPosition)), "")
end

-- finishDeleteDeclarations processes all queued deletions with smart handling for lists and trailing commas.
function Tracker:finishDeleteDeclarations()
    local deletedNodesInLists = { set = {}, order = {} }

    for _, deleted in ipairs(self.deletedNodes) do
        -- Skip if this node is contained within another deleted node
        local isContained = false
        for _, other in ipairs(self.deletedNodes) do
            if other.sourceFile == deleted.sourceFile and other.node ~= deleted.node and
                change.rangeContainsRangeExclusive(other.node, deleted.node) then
                isContained = true
                break
            end
        end
        if not isContained then
            change.deleteDeclaration(self, deletedNodesInLists, deleted.sourceFile, deleted.node)
        end
    end

    -- Handle trailing commas for last elements in lists
    for _, node in ipairs(deletedNodesInLists.order) do
        local sourceFile = ast.GetSourceFileOfNode(node)
        local list = format.GetContainingList(node, sourceFile)
        if list == nil or node ~= list.nodes[#list.nodes] then
            goto continue
        end

        do
            local lastNonDeletedIndex = -1
            for i = #list.nodes - 2, 0, -1 do
                if not deletedNodesInLists.set[list.nodes[i + 1]] then
                    lastNonDeletedIndex = i
                    break
                end
            end

            if lastNonDeletedIndex ~= -1 then
                local start = list.nodes[lastNonDeletedIndex + 1]:End()
                local end_ = self:startPositionToDeleteNodeInList(sourceFile, list.nodes[lastNonDeletedIndex + 2])
                self:ReplaceRangeWithText(sourceFile, self:toLSPEditRange(sourceFile, core.NewTextRange(start, end_)), "")
            end
        end
        ::continue::
    end
end

function Tracker:endPosForInsertNodeAfter(sourceFile, after, newNode)
    if change.needSemicolonBetween(after, newNode) and (string.byte(sourceFile:Text(), after:End()) ~= 0x3B) then
        -- check if previous statement ends with semicolon
        -- if not - insert semicolon to preserve the code from changing the meaning due to ASI
        local endPos = self:toLSPEditPos(sourceFile, after:End())
        local semicolon = self.nodeFactory:NewToken(Kind.SemicolonToken)
        semicolon.loc = core.NewTextRange(after:End(), after:End())
        semicolon.parent = after.parent
        self:ReplaceRange(
            sourceFile,
            newRange(endPos, endPos),
            semicolon,
            change.NodeOptions_new()
        )
    end
    return self:getAdjustedEndPosition(sourceFile, after, TrailingTriviaOption.None)
end

--[[
* This function should be used to insert nodes in lists when nodes don't carry separators as the part of the node range,
* i.e. arguments in arguments lists, parameters in parameter lists etc.
* Note that separators are part of the node in statements and class elements.
]]
function Tracker:InsertNodeInListAfter(sourceFile, after, newNode, containingList)
    if containingList == nil then
        containingList = format.GetContainingList(after, sourceFile)
    end
    if containingList == nil then
        -- Debug.fail("node is not a list element")
        return
    end
    local index = core.FindIndex(containingList.nodes, function(n)
        return n == after
    end)
    if index < 0 then
        return
    end
    local end_ = after:End()
    if index ~= #containingList.nodes - 1 then
        -- any element except the last one
        -- use next sibling as an anchor
        local nextToken = astnav.GetTokenAtPosition(sourceFile, after:End())
        if nextToken ~= nil and change.isSeparator(after, nextToken) then
            -- for list
            -- a, b, c
            -- create change for adding 'e' after 'a' as
            -- - find start of next element after a (it is b)
            -- - use next element start as start and end position in final change
            -- - build text of change by formatting the text of node + whitespace trivia of b

            -- in multiline case it will work as
            --   a,
            --   b,
            --   c,
            -- result - '*' denotes leading trivia that will be inserted after new text (displayed as '#')
            --   a,
            --   insertedtext<separator>#
            -- ###b,
            --   c,
            local nextNode = containingList.nodes[index + 2]
            local startPos = scanner.SkipTriviaEx(sourceFile:Text(), nextNode:Pos(), { stopAfterLineBreak = false, stopAtComments = true })

            -- write separator and leading trivia of the next element as suffix
            local suffix = scanner.TokenToString(nextToken.kind) .. string.sub(sourceFile:Text(), nextToken:End() + 1, startPos)
            self:InsertNodesAt(sourceFile, startPos, { newNode }, change.NodeOptions_new({ suffix = suffix }))
        end
        return
    end

    local afterStart = astnav.GetStartOfNode(after, sourceFile, false)
    local afterStartLinePosition = format.GetLineStartPositionForPosition(afterStart, sourceFile)

    -- insert element after the last element in the list that has more than one item
    -- pick the element preceding the after element to:
    -- - pick the separator
    -- - determine if list is a multiline
    local multilineList = false

    -- if list has only one element then we'll format is as multiline if node has comment in trailing trivia, or as singleline otherwise
    -- i.e. var x = 1 // this is x
    --     | new element will be inserted at this position
    local separator = Kind.CommaToken -- SyntaxKind.CommaToken | SyntaxKind.SemicolonToken
    if #containingList.nodes ~= 1 then
        -- otherwise, if list has more than one element, pick separator from the list
        local tokenBeforeInsertPosition = astnav.FindPrecedingToken(sourceFile, after:Pos())
        if change.isSeparator(after, tokenBeforeInsertPosition) then
            separator = tokenBeforeInsertPosition.kind
        else
            separator = Kind.CommaToken
        end
        -- determine if list is multiline by checking lines of after element and element that precedes it.
        local afterMinusOneStartLinePosition = format.GetLineStartPositionForPosition(astnav.GetStartOfNode(containingList.nodes[index], sourceFile, false), sourceFile)
        multilineList = afterMinusOneStartLinePosition ~= afterStartLinePosition
    end
    if change.hasCommentsBeforeLineBreak(sourceFile:Text(), after:End()) or not change.positionsAreOnSameLine(containingList:Pos(), containingList:End(), sourceFile) then
        -- in this case we'll always treat containing list as multiline
        multilineList = true
    end
    if multilineList then
        -- insert separator immediately following the 'after' node to preserve comments in trailing trivia
        local separatorToken = self.nodeFactory:NewToken(separator)
        local separatorString = scanner.TokenToString(separator)
        separatorToken.loc = core.NewTextRange(end_, end_ + #separatorString)
        separatorToken.parent = after.parent
        local endPos = self:toLSPEditPos(sourceFile, end_)
        self:ReplaceRange(sourceFile, newRange(endPos, endPos), separatorToken, change.NodeOptions_new())
        -- use the same indentation as 'after' item
        local indentation = format.FindFirstNonWhitespaceColumn(afterStartLinePosition, afterStart, sourceFile, self.formatSettings)
        -- insert element before the line break on the line that contains 'after' element
        local insertPos = scanner.SkipTriviaEx(sourceFile:Text(), end_, { stopAfterLineBreak = true, stopAtComments = false })
        -- find position before "\n" or "\r\n"
        while insertPos ~= end_ and stringutil.IsLineBreak(string.byte(sourceFile:Text(), insertPos)) do
            insertPos = insertPos - 1
        end
        local insertLSPos = self:toLSPEditPos(sourceFile, insertPos)
        self:ReplaceRange(
            sourceFile,
            newRange(insertLSPos, insertLSPos),
            newNode,
            change.NodeOptions_new({
                indentation = indentation,
                prefix = self.newLine,
            })
        )
    else
        local separatorString = scanner.TokenToString(separator)
        local endPos = self:toLSPEditPos(sourceFile, end_)
        self:ReplaceRange(sourceFile, newRange(endPos, endPos), newNode, change.NodeOptions_new({ prefix = separatorString .. " " }))
    end
end

-- InsertImportSpecifierAtIndex inserts a new import specifier at the specified index in a NamedImports list
function Tracker:InsertImportSpecifierAtIndex(sourceFile, newSpecifier, namedImports, index)
    local namedImportsNode = namedImports:AsNamedImports()
    local elements = namedImportsNode.elements.nodes

    local prevSpecifier
    if index > 0 and index - 1 < #elements then
        prevSpecifier = elements[index]
    end
    if prevSpecifier ~= nil then
        self:InsertNodeInListAfter(sourceFile, prevSpecifier, newSpecifier, nil)
    else
        self:InsertNodeBefore(
            sourceFile,
            elements[1],
            newSpecifier,
            not change.positionsAreOnSameLine(astnav.GetStartOfNode(elements[1], sourceFile, false), astnav.GetStartOfNode(namedImports.parent.parent, sourceFile, false), sourceFile),
            LeadingTriviaOption.None
        )
    end
end

function Tracker:InsertAtTopOfFile(sourceFile, insert, blankLineBetween)
    if core.Len(insert) == 0 then
        return
    end

    local pos = self:getInsertionPositionAtSourceFileTop(sourceFile)
    local originalPos = pos
    -- A content mapper may synthesize a header. Advance to the first writable segment so the insertion
    -- maps exactly to the original file, and use its original position when deciding leading trivia.
    local spanMap = sourceFile:SpanMap()
    if spanMap ~= nil then
        for _, segment in ipairs(spanMap:Segments() or {}) do
            if segment.kind ~= spanmap.Kind.Verbatim or segment.virtualEnd <= pos then
                goto continue
            end
            if segment.virtualStart > pos then
                pos = segment.virtualStart
            end
            originalPos = segment.originalStart + pos - segment.virtualStart
            break
            ::continue::
        end
    end
    local options = change.NodeOptions_new()
    if originalPos ~= 0 then
        options.prefix = self.newLine
    end
    if #sourceFile:Text() == 0 or not stringutil.IsLineBreak(string.byte(sourceFile:Text(), pos + 1) or 0) then
        options.suffix = self.newLine
    end
    if blankLineBetween then
        options.suffix = options.suffix .. self.newLine
    end

    if #insert == 1 then
        self:InsertNodeAt(sourceFile, pos, insert[1], options)
    else
        self:InsertNodesAt(sourceFile, pos, insert, options)
    end
end

function Tracker:InsertMemberAtStart(sourceFile, node, newElement)
    self:insertNodeAtStartWorker(sourceFile, node, newElement)
end

function Tracker:insertNodeAtStartWorker(sourceFile, node, newElement)
    local indentation = self:tryComputeIndentationFromExistingMembers(sourceFile, node)
    if indentation < 0 then
        indentation = self:tryComputeIndentationForNewMember(sourceFile, node)
    end

    local members = change.getMembersOrProperties(node)
    if members == nil then
        return
    end

    self:InsertNodeAt(sourceFile, members:Pos(), newElement, self:getInsertNodeAtStartInsertOptions(sourceFile, node, indentation))
end

function Tracker:tryComputeIndentationForNewMember(sourceFile, node)
    local nodeStart = astnav.GetStartOfNode(node, sourceFile, false)
    local lineStart = format.GetLineStartPositionForPosition(nodeStart, sourceFile)

    local tabSize = self.formatSettings.tabSize
    if tabSize <= 0 then
        tabSize = 4
    end

    local indentSize = self.formatSettings.indentSize
    if indentSize <= 0 then
        indentSize = 4
    end
    return math.max(change.findIndentationColumn(sourceFile:Text(), lineStart, nodeStart, tabSize), 0) + indentSize
end

function Tracker:tryComputeIndentationFromExistingMembers(sourceFile, node)
    local members = change.getMembersOrProperties(node)
    if members == nil then
        return -1
    end

    local indentation = -1
    local text = sourceFile:Text()
    local tabSize = self.formatSettings.tabSize
    local last = node

    if tabSize <= 0 then
        tabSize = 4
    end

    for _, member in ipairs(members.nodes) do
        if member == nil then
            goto continue
        end
        if printer.RangeStartPositionsAreOnSameLine(last.loc, member.loc, sourceFile) then
            return -1
        end

        do
            local memberStart = astnav.GetStartOfNode(member, sourceFile, false)
            local lineStart = format.GetLineStartPositionForPosition(memberStart, sourceFile)
            local column = change.findIndentationColumn(text, lineStart, memberStart, tabSize)
            if column < 0 then
                return -1
            end

            if indentation >= 0 then
                if indentation ~= column then
                    return -1
                end
                last = member
                goto continue
            end

            indentation = column
            last = member
        end
        ::continue::
    end

    return indentation
end

function Tracker:getInsertNodeAfterOptions(sourceFile, node)
    local newLineChar = self.newLine
    local options
    local kind = node.kind
    if kind == Kind.Parameter then
        -- default opts
        options = change.NodeOptions_new()
    elseif kind == Kind.ClassDeclaration or kind == Kind.ModuleDeclaration then
        options = change.NodeOptions_new({ prefix = newLineChar, suffix = newLineChar })
    elseif kind == Kind.VariableDeclaration or kind == Kind.StringLiteral or kind == Kind.Identifier then
        options = change.NodeOptions_new({ prefix = ", " })
    elseif kind == Kind.PropertyAssignment then
        options = change.NodeOptions_new({ suffix = "," .. newLineChar })
    elseif kind == Kind.ExportKeyword then
        options = change.NodeOptions_new({ prefix = " " })
    else
        if not (ast.IsStatement(node) or ast.IsClassOrTypeElement(node)) then
            -- Else we haven't handled this kind of node yet -- add it
            error("unimplemented node type " .. ast.Kind_String(node.kind) .. " in changeTracker.getInsertNodeAfterOptions", 0)
        end
        options = change.NodeOptions_new({ suffix = newLineChar })
    end
    if node:End() == sourceFile:End() and ast.IsStatement(node) then
        options.prefix = self.newLine .. options.prefix
    end

    return options
end

function Tracker:getOptionsForInsertNodeBefore(before, inserted, blankLineBetween)
    if ast.IsStatement(before) or ast.IsClassOrTypeElement(before) then
        if blankLineBetween then
            return change.NodeOptions_new({ suffix = self.newLine .. self.newLine })
        end
        return change.NodeOptions_new({ suffix = self.newLine })
    elseif before.kind == Kind.VariableDeclaration then
        -- insert `x = 1, ` into `const x = 1, y = 2;
        return change.NodeOptions_new({ suffix = ", " })
    elseif before.kind == Kind.Parameter then
        if inserted.kind == Kind.Parameter then
            return change.NodeOptions_new({ suffix = ", " })
        end
        return change.NodeOptions_new()
    elseif (before.kind == Kind.StringLiteral and before.parent ~= nil and before.parent.kind == Kind.ImportDeclaration) or before.kind == Kind.NamedImports then
        return change.NodeOptions_new({ suffix = ", " })
    elseif before.kind == Kind.ImportSpecifier then
        local suffix = ","
        if blankLineBetween then
            suffix = suffix .. self.newLine
        else
            suffix = suffix .. " "
        end
        return change.NodeOptions_new({ suffix = suffix })
    end
    -- We haven't handled this kind of node yet -- add it
    error("unimplemented node type " .. ast.Kind_String(before.kind) .. " in changeTracker.getOptionsForInsertNodeBefore", 0)
end

function Tracker:getInsertNodeAtStartInsertOptions(sourceFile, node, indentation)
    local state = self.nodesWithInsertionsAtStart[node]
    local hasPreviousInsertion = state ~= nil
    if state == nil then
        state = {
            node = node,
            sourceFile = sourceFile,
        }
        self.nodesWithInsertionsAtStart[node] = state
        self.nodesWithInsertionsAtStartOrder[#self.nodesWithInsertionsAtStartOrder + 1] = node
    end

    local members = change.getMembersOrProperties(node)
    local isObjectLiteral = ast.IsObjectLiteralExpression(node)
    local isJSON = ast.IsJsonSourceFile(sourceFile)

    local hasMembers = members ~= nil and #members.nodes > 0

    local insertTrailingComma = isObjectLiteral and (hasMembers or not isJSON)
    local insertLeadingComma = isObjectLiteral and isJSON and not hasMembers and hasPreviousInsertion

    local suffix = ""
    if insertTrailingComma then
        suffix = ","
    elseif ast.IsInterfaceDeclaration(node) and not hasMembers then
        suffix = ";"
    end

    local prefix = self.newLine
    if insertLeadingComma then
        prefix = "," .. prefix
    end

    return change.NodeOptions_new({ indentation = indentation, prefix = prefix, suffix = suffix })
end

function Tracker:finishNodesWithInsertionsAtStart()
    for _, key in ipairs(self.nodesWithInsertionsAtStartOrder) do
        local state = self.nodesWithInsertionsAtStart[key]
        if state == nil then
            goto continue
        end

        do
            local openBrace = astnav.FindChildOfKind(state.node, Kind.OpenBraceToken, state.sourceFile)
            if openBrace == nil then
                goto continue
            end

            local closeBrace = astnav.FindChildOfKind(state.node, Kind.CloseBraceToken, state.sourceFile)
            if closeBrace == nil then
                goto continue
            end

            local members = change.getMembersOrProperties(state.node)
            local isEmpty = members == nil or #members.nodes == 0
            local isSingleLine = change.positionsAreOnSameLine(openBrace:End(), closeBrace:End(), state.sourceFile)

            if isEmpty and isSingleLine and openBrace:End() ~= closeBrace:End() - 1 then
                self:DeleteRange(state.sourceFile, core.NewTextRange(openBrace:End(), closeBrace:End() - 1))
            end

            if isSingleLine then
                self:InsertText(state.sourceFile, self:toLSPEditPos(state.sourceFile, closeBrace:End() - 1), self.newLine)
            end
        end
        ::continue::
    end
end

function change.getMembersOrProperties(node)
    if ast.IsObjectLiteralExpression(node) then
        return node:PropertyList()
    end
    return node:MemberList()
end

function change.rangeContainsRangeExclusive(outer, inner)
    return outer:Pos() < inner:Pos() and inner:End() < outer:End()
end

function change.isSeparator(node, candidate)
    return candidate ~= nil and node.parent ~= nil and (candidate.kind == Kind.CommaToken or (candidate.kind == Kind.SemicolonToken and node.parent.kind == Kind.ObjectLiteralExpression))
end

function change.findIndentationColumn(text, lineStart, memberStart, tabSize)
    local column = 0

    local i = lineStart
    while i < memberStart and i < #text do
        local ch = string.byte(text, i + 1)

        if stringutil.IsLineBreak(ch) then
            return -1
        end
        if stringutil.IsWhiteSpaceSingleLine(ch) then
            column = change.advanceIndentationColumn(column, ch, tabSize)
        else
            return column
        end
        i = i + 1
    end

    return column
end

function change.advanceIndentationColumn(column, ch, tabSize)
    if ch == 0x09 then
        return column + tabSize - (column % tabSize)
    end
    return column + 1
end
