local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

ls.maxSelectionRangeDepth = 1000

local function rangeEquals(a, b)
    if a == nil or b == nil then
        return a == b
    end
    return a.start.line == b.start.line and a.start.character == b.start.character and
        a.end_.line == b.end_.line and a.end_.character == b.end_.character
end

-- selectionRangeBuilder: { ranges, capacity, oldestIndex }
local selectionRangeBuilder = {}
selectionRangeBuilder.__index = selectionRangeBuilder
ls.selectionRangeBuilder = selectionRangeBuilder

function ls.newSelectionRangeBuilder(capacity)
    return setmetatable({
        ranges = {},
        capacity = capacity,
        oldestIndex = 0,
    }, selectionRangeBuilder)
end

function selectionRangeBuilder:push(selectionRange)
    if #self.ranges < self.capacity then
        self.ranges[#self.ranges + 1] = selectionRange
        return
    end

    self.ranges[self.oldestIndex + 1] = selectionRange
    self.oldestIndex = (self.oldestIndex + 1) % #self.ranges
end

function selectionRangeBuilder:build(result)
    for i = 0, #self.ranges - 1 do
        local index = (self.oldestIndex + i) % #self.ranges
        result = {
            range = self.ranges[index + 1],
            parent = result,
        }
    end
    return result
end

function LanguageService:ProvideSelectionRanges(ctx, params)
    local _, sourceFile = self:getProgramAndFile(params.textDocument.uri)
    if sourceFile == nil then
        return {}, nil
    end

    local results = {}
    for _, position in ipairs(params.positions or {}) do
        local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, position, spanmap.Feature.SelectionRanges)
        if #positions ~= 1 or not spanmap.Fidelity_IsSingleSegment(positions[1].fidelity) then
            return {}, nil
        end
        local selectionRange = ls.getSmartSelectionRange(self, positions[1].script, positions[1].position)
        if selectionRange ~= nil then
            results[#results + 1] = selectionRange
        end
    end

    return { selectionRanges = results }, nil
end

function ls.getSelectionChildren(factory, node, sourceFile)
    if not ast.IsMappedTypeNode(node) then
        return ls.getChildrenFromNonJSDocNode(node, sourceFile)
    end

    local children = ls.getChildrenFromNonJSDocNode(node, sourceFile)
    if core.Len(children) < 2 then
        return children
    end

    local openBraceToken = children[1]
    local closeBraceToken = children[#children]
    if openBraceToken.kind ~= Kind.OpenBraceToken or closeBraceToken.kind ~= Kind.CloseBraceToken then
        return children
    end

    local mappedType = node
    children = core.Slice(children, 1, #children - 1)

    -- Group `-/+readonly` and `-/+?`.
    local groupedWithPlusMinusTokens = ls.groupChildren(factory, children, function(child)
        return child == mappedType.readonlyToken or
            child.kind == Kind.ReadonlyKeyword or
            child == mappedType.questionToken or
            child.kind == Kind.QuestionToken
    end)

    -- Group the type parameter with its surrounding brackets.
    local groupedWithBrackets = ls.groupChildren(factory, groupedWithPlusMinusTokens, function(child)
        return child.kind == Kind.OpenBracketToken or
            child.kind == Kind.TypeParameter or
            child.kind == Kind.CloseBracketToken
    end)

    -- Go exposes the trailing semicolon directly, so keep it in the right-hand
    -- group to produce the same effective selection tree as Strada.
    return {
        openBraceToken,
        ls.createSyntaxList(factory, ls.splitChildren(factory, groupedWithBrackets, function(child)
            return child.kind == Kind.ColonToken
        end, false)),
        closeBraceToken,
    }
end

function ls.groupChildren(factory, children, groupOn)
    local result
    local group
    for _, child in ipairs(children or {}) do
        if groupOn(child) then
            group = core.Append(group, child)
        else
            if core.Len(group) > 0 then
                result = core.Append(result, ls.createSyntaxList(factory, group))
                group = nil
            end
            result = core.Append(result, child)
        end
    end
    if core.Len(group) > 0 then
        result = core.Append(result, ls.createSyntaxList(factory, group))
    end
    return result
end

function ls.splitChildren(factory, children, pivotOn, separateTrailingSemicolon)
    if core.Len(children) < 2 then
        return children
    end

    local splitTokenIndex = -1
    for i1, child in ipairs(children) do
        if pivotOn(child) then
            splitTokenIndex = i1 - 1
            break
        end
    end
    if splitTokenIndex == -1 then
        return children
    end

    local leftChildren = core.Slice(children, 0, splitTokenIndex)
    local splitToken = children[splitTokenIndex + 1]
    local lastToken = children[#children]
    local separateLastToken = separateTrailingSemicolon and lastToken.kind == Kind.SemicolonToken
    local rightEnd = #children
    if separateLastToken then
        rightEnd = rightEnd - 1
    end
    local rightChildren = core.Slice(children, splitTokenIndex + 1, rightEnd)

    local result = {}
    if #leftChildren > 0 then
        result[#result + 1] = ls.createSyntaxList(factory, leftChildren)
    end
    result[#result + 1] = splitToken
    if #rightChildren > 0 then
        result[#result + 1] = ls.createSyntaxList(factory, rightChildren)
    end
    if separateLastToken then
        result[#result + 1] = lastToken
    end
    return result
end

function ls.createSyntaxList(factory, children)
    local list = factory:NewSyntaxList(children)
    list.loc = core.NewTextRange(children[1]:Pos(), children[#children]:End())
    return list
end

function ls.getSmartSelectionRange(l, sourceFile, pos)
    local factory = ast.NewNodeFactory(nil)
    -- Traversal discovers ranges from broadest to most specific, so retain the newest ranges nearest to the cursor
    local ranges = ls.newSelectionRangeBuilder(ls.maxSelectionRangeDepth - 1)
    local root
    local lastRange = { start = { line = 0, character = 0 }, end_ = { line = 0, character = 0 } }
    if sourceFile:ContentMapper() == "" then
        local fullRange = l.converters:ToLSPRange(sourceFile, core.NewTextRange(sourceFile:Pos(), sourceFile:End()))
        root = { range = fullRange }
        lastRange = fullRange
    end

    local function nodeContainsPosition(node)
        if node == nil then
            return false
        end
        local start = scanner.GetTokenPosOfNode(node, sourceFile, true --[[includeJSDoc]])
        local end_ = node:End()
        return start <= pos and pos < end_
    end

    local function positionShouldSnapToNode(node)
        if pos < node:End() then
            return true
        end
        if node:End() == pos then
            local touchingPropertyName = astnav.GetTouchingPropertyName(sourceFile, pos)
            return touchingPropertyName ~= nil and touchingPropertyName:Pos() < node:End()
        end
        return false
    end

    local function pushSelectionRange(start, end_)
        if start == end_ then
            return
        end

        if not (start <= pos and pos <= end_) then
            return
        end

        local lspRange, fidelity = l.converters:ToLSPRangeForFeature(sourceFile, core.NewTextRange(start, end_), spanmap.Feature.SelectionRanges)
        if spanmap.Fidelity_IsNone(fidelity) then
            return
        end

        if rangeEquals(lastRange, lspRange) then
            return
        end
        lastRange = lspRange

        ranges:push(lspRange)
    end

    local function pushSelectionCommentRange(start, end_)
        pushSelectionRange(start, end_)

        local commentPos = start
        local text = sourceFile:Text()
        while commentPos < end_ and commentPos < #text and string.byte(text, commentPos + 1) == 0x2F --[[ '/' ]] do
            commentPos = commentPos + 1
        end
        pushSelectionRange(commentPos, end_)
    end

    local function positionsAreOnSameLine(pos1, pos2)
        if pos1 == pos2 then
            return true
        end
        local lineStarts = sourceFile:ECMALineMap()
        return scanner.ComputeLineOfPosition(lineStarts, pos1) == scanner.ComputeLineOfPosition(lineStarts, pos2)
    end

    local function shouldSkipNode(node, parent)
        if ast.IsBlock(node) then
            return true
        end

        if ast.IsTemplateSpan(node) or ast.IsTemplateHead(node) or ast.IsTemplateTail(node) then
            return true
        end

        if parent ~= nil and ast.IsVariableDeclarationList(node) and ast.IsVariableStatement(parent) then
            return true
        end

        -- Skip lone variable declarations
        if parent ~= nil and ast.IsVariableDeclaration(node) and ast.IsVariableDeclarationList(parent) then
            local decl = parent
            if decl ~= nil and #decl.declarations.nodes == 1 then
                return true
            end
        end

        if ast.IsJSDocTypeExpression(node) or ast.IsJSDocSignature(node) or ast.IsJSDocTypeLiteral(node) then
            return true
        end

        return false
    end

    local current = sourceFile
    while current ~= nil do
        local next_
        local parent = current

        local function visit(node)
            if node ~= nil and next_ == nil then
                -- Only the first trailing comment range is of interest.
                local nextComment, state, control = scanner.GetTrailingCommentRanges(factory, sourceFile:Text(), node:End())
                local foundComment = nextComment(state, control)
                if foundComment ~= nil and foundComment.kind == Kind.SingleLineCommentTrivia then
                    pushSelectionCommentRange(foundComment:Pos(), foundComment:End())
                end

                if nodeContainsPosition(node) then
                    -- Add range for multi-line function bodies before skipping the block
                    if ast.IsBlock(node) and ast.IsFunctionLikeDeclaration(parent) then
                        if not positionsAreOnSameLine(astnav.GetStartOfNode(node, sourceFile, false), node:End()) then
                            local start = astnav.GetStartOfNode(node, sourceFile, false)
                            local end_ = node:End()
                            pushSelectionRange(start, end_)
                        end
                    end

                    -- Synthesize a stop for '${ ... }' since '${' and '}' actually belong to siblings.
                    if ast.IsTemplateSpan(parent) then
                        local templateSpan = parent
                        if templateSpan.literal ~= nil then
                            -- Start from just before the '${' and end after the '}'
                            -- The '${' is 2 characters before the expression start
                            local spanStart = node:Pos() - 2
                            -- The '}' is the first character of the template literal (middle or tail)
                            local spanEnd = astnav.GetStartOfNode(templateSpan.literal, sourceFile, false) + 1
                            -- Validate the positions are reasonable
                            local text = sourceFile:Text()
                            if spanStart >= 0 and spanEnd <= #text and spanStart < spanEnd then
                                pushSelectionRange(spanStart, spanEnd)
                            end
                        end
                    end

                    if not shouldSkipNode(node, parent) then
                        local start = astnav.GetStartOfNode(node, sourceFile, false)
                        local end_ = node:End()
                        pushSelectionRange(start, end_)

                        if ast.IsMappedTypeNode(node) then
                            local selectionParent = node
                            while true do
                                local selectionChild
                                for _, child in ipairs(ls.getSelectionChildren(factory, selectionParent, sourceFile) or {}) do
                                    local childStart = scanner.GetTokenPosOfNode(child, sourceFile, true --[[includeJSDoc]])
                                    if childStart > pos then
                                        break
                                    end
                                    if positionShouldSnapToNode(child) then
                                        pushSelectionRange(childStart, child:End())
                                        selectionChild = child
                                        break
                                    end
                                end
                                if selectionChild == nil or not ast.IsSyntaxList(selectionChild) then
                                    break
                                end
                                selectionParent = selectionChild
                            end
                        end

                        -- String literals should have a stop both inside and outside their quotes.
                        if ast.IsStringLiteral(node) or node.kind == Kind.TemplateExpression or node.kind == Kind.NoSubstitutionTemplateLiteral then
                            -- Only add inner content range if there's actually content (handles unterminated literals)
                            if start + 1 < end_ - 1 then
                                pushSelectionRange(start + 1, end_ - 1)
                            end
                        end
                    end

                    next_ = node
                end
            end
            return node
        end

        local function visitNodes(nodes, v)
            if nodes ~= nil and #nodes.nodes > 0 then
                local shouldSkipList = parent ~= nil and (ast.IsVariableDeclarationList(parent) or ast.IsTemplateExpression(parent))

                if not shouldSkipList then
                    local start = astnav.GetStartOfNode(nodes.nodes[1], sourceFile, false)
                    local end_ = nodes.nodes[#nodes.nodes]:End()

                    if start <= pos and pos < end_ then
                        pushSelectionRange(start, end_)
                    end
                end
            end
            return v:VisitNodes(nodes)
        end

        -- Visit JSDoc nodes first if they exist
        for _, jsdoc in ipairs(current:JSDoc(sourceFile) or {}) do
            visit(jsdoc)
        end

        local tempVisitor = ast.NewNodeVisitor(visit, nil, {
            visitNodes = visitNodes,
        })

        current:VisitEachChild(tempVisitor)
        current = next_
    end
    return ranges:build(root)
end
