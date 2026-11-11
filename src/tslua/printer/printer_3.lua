-- Go printer.go, part 3: emitShebangIfNeeded .. getClosingBracket
local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

local Printer = printer.Printer
local Kind = ast.Kind
local EF = printer.EmitFlags
local LF = printer.ListFormat
local WriteKind = printer.WriteKind
local Tristate = core.Tristate

local function kindString(k)
    return tostring(ast.Kind_names[k] or k)
end

function Printer:emitShebangIfNeeded(node)
    if ast.NodeIsSynthesized(node) then
        return
    end
    local shebang = scanner.GetShebang(node:Text())
    if shebang ~= "" then
        self:writeComment(shebang)
        self:writeLine()
    end
end

function Printer:emitPrologueDirectives(statements)
    for i1, statement in ipairs((statements.nodes or {})) do
        if ast.IsPrologueDirective(statement) then
            self:writeLine()
            self:emitStatement(statement)
        else
            return i1 - 1
        end
    end
    return #(statements.nodes or {})
end

function Printer:emitHelpers(node)
    local helpersEmitted = false
    local sourceFile = self.currentSourceFile
    local shouldSkip = self.options.noEmitHelpers or (sourceFile ~= nil and self.emitContext:HasRecordedExternalHelpers(sourceFile))
    local helpers = {}
    for i, h in ipairs(self.emitContext:GetEmitHelpers(node) or {}) do
        helpers[i] = h
    end
    if #helpers > 0 then
        printer.sortStableFunc(helpers, printer.compareEmitHelpers)
        for _, helper in ipairs(helpers) do
            if not helper.scoped then
                -- Skip the helper if it can be skipped and the noEmitHelpers compiler
                -- option is set, or if it can be imported and the importHelpers compiler
                -- option is set.
                if shouldSkip then
                    goto continue
                end
            end
            if helper.textCallback ~= nil then
                self:writeLines(helper.textCallback(self.makeFileLevelOptimisticUniqueName))
            else
                self:writeLines(helper.text)
            end
            helpersEmitted = true
            ::continue::
        end
    end

    return helpersEmitted
end

function Printer:emitSourceFile(node)
    local savedCurrentSourceFile = self.currentSourceFile
    local savedCommentsDisabled = self.commentsDisabled
    self.currentSourceFile = node

    self:writeLine()

    self:pushNameGenerationScope(node)
    self:generateAllNames(node.statements)

    local index = 0
    local state
    if node.scriptKind ~= core.ScriptKind.JSON then
        self:emitShebangIfNeeded(node)
        index = self:emitPrologueDirectives(node.statements)
        if not self.writer:IsAtStartOfLine() then
            self:writeLine()
        end
        state = self:emitDetachedCommentsBeforeStatementList(node, node.statements.loc)
        self:emitHelpers(node)
        if node.isDeclarationFile then
            self:emitTripleSlashDirectives(node)
        end
    else
        state = self:emitDetachedCommentsBeforeStatementList(node, node.statements.loc)
    end

    -- !!! Emit triple-slash directives
    self:emitListRange(
        Printer.emitStatement,
        node,
        node.statements,
        LF.LFMultiLine,
        index,
        -1 --[[count]]
    )
    self:popNameGenerationScope(node)
    self:emitDetachedCommentsAfterStatementList(node, node.statements.loc, state)
    self.currentSourceFile = savedCurrentSourceFile
    self.commentsDisabled = savedCommentsDisabled
end

function Printer:emitTripleSlashDirectives(node)
    self:emitDirective("path", node.referencedFiles)
    self:emitDirective("types", node.typeReferenceDirectives)
    self:emitDirective("lib", node.libReferenceDirectives)
end

function Printer:emitDirective(kind, refs)
    for _, ref in ipairs(refs or {}) do
        local resolutionMode = ""
        if ref.resolutionMode ~= core.ModuleKind.ResolutionModeNone then
            resolutionMode = string.format('resolution-mode="%s" ', ref.resolutionMode == core.ModuleKind.ResolutionModeESM and "import" or "require")
        end
        self:writeComment(string.format("/// <reference %s=\"%s\" %s%s/>", kind, ref.fileName, resolutionMode, ref.preserve and 'preserve="true" ' or ""))
        self:writeLine()
    end
end

--
-- Lists
--

function Printer:emitList(emit, parentNode, children, format)
    if self:shouldEmitOnMultipleLines(parentNode) then
        format = format | LF.LFPreferNewLine | LF.LFIndented
    end

    self:emitListRange(emit, parentNode, children, format, -1 --[[start]], -1 --[[count]])
end

function Printer:emitListRange(emit, parentNode, children, format, start, count)
    local isNil = children == nil

    local length = 0
    if not isNil then
        length = #(children.nodes or {})
    end

    if start < 0 then
        start = 0
    end

    if count < 0 then
        count = length - start
    end

    if isNil and format & LF.LFOptionalIfNil ~= 0 then
        return
    end

    local isEmpty = isNil or start >= length or count <= 0
    if isEmpty and format & LF.LFOptionalIfEmpty ~= 0 then
        if self.onBeforeEmitNodeList ~= nil then
            self.onBeforeEmitNodeList(children)
        end
        if self.onAfterEmitNodeList ~= nil then
            self.onAfterEmitNodeList(children)
        end
        return
    end

    if format & LF.LFBracketsMask ~= 0 then
        self:writePunctuation(printer.getOpeningBracket(format))
        if isEmpty and not isNil then
            self:emitTrailingComments(children:Pos(), printer.commentSeparatorBefore) -- Emit comments within empty lists
        end
    end

    if self.onBeforeEmitNodeList ~= nil then
        self.onBeforeEmitNodeList(children)
    end

    if isEmpty then
        -- Write a line terminator if the parent node was multi-line
        if format & LF.LFMultiLine ~= 0 and not (self.options.preserveSourceNewlines and (parentNode == nil or self.currentSourceFile ~= nil and printer.RangeIsOnSingleLine(parentNode.loc, self.currentSourceFile))) then
            self:writeLine()
        elseif format & LF.LFSpaceBetweenBraces ~= 0 and format & LF.LFNoSpaceIfEmpty == 0 then
            self:writeSpace()
        end
    else
        local end_ = math.min(start + count, length)

        self:emitListItems(emit, parentNode, core.Slice((children.nodes or {}), start, end_), format, self:hasTrailingComma(parentNode, children), children.loc)
    end

    if self.onAfterEmitNodeList ~= nil then
        self.onAfterEmitNodeList(children)
    end

    if format & LF.LFBracketsMask ~= 0 then
        if isEmpty and not isNil then
            self:emitLeadingComments(children:End(), false --[[elided]]) -- Emit comments within empty lists
        end
        self:writePunctuation(printer.getClosingBracket(format))
    end
end

function Printer:hasTrailingComma(parentNode, children)
    -- NodeList.HasTrailingComma() is unreliable on transformed nodes as some nodes may have been removed. In the event
    -- we believe we may need to emit a trailing comma, we must first look to the respective node list on the original
    -- node first.
    if not children:HasTrailingComma() then
        return false
    end

    local originalParent = self.emitContext:MostOriginal(parentNode)
    if originalParent == parentNode then
        -- if this node is the original node, we can trust the result
        return true
    end

    if originalParent.kind ~= parentNode.kind then
        -- if the original node is some other kind of node, we cannot correlate the list
        return false
    end

    -- find the respective node list on the original parent
    local originalList = children
    local k = originalParent.kind
    if k == Kind.ObjectLiteralExpression then
        originalList = originalParent:PropertyList()
    elseif k == Kind.ArrayLiteralExpression then
        originalList = originalParent:ElementList()
    elseif k == Kind.CallExpression or k == Kind.NewExpression then
        if children == parentNode:TypeArgumentList() then
            originalList = originalParent:TypeArgumentList()
        elseif children == parentNode:ArgumentList() then
            originalList = originalParent:ArgumentList()
        end
    elseif k == Kind.Constructor or
        k == Kind.MethodDeclaration or
        k == Kind.GetAccessor or
        k == Kind.SetAccessor or
        k == Kind.FunctionDeclaration or
        k == Kind.FunctionExpression or
        k == Kind.ArrowFunction or
        k == Kind.FunctionType or
        k == Kind.ConstructorType or
        k == Kind.CallSignature or
        k == Kind.ConstructSignature then
        if children == parentNode:TypeParameterList() then
            originalList = originalParent:TypeParameterList()
        elseif children == parentNode:ParameterList() then
            originalList = originalParent:ParameterList()
        end
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression or k == Kind.InterfaceDeclaration or k == Kind.TypeAliasDeclaration or k == Kind.JSTypeAliasDeclaration then
        if children == parentNode:TypeParameterList() then
            originalList = originalParent:TypeParameterList()
        end
    elseif k == Kind.ObjectBindingPattern or k == Kind.ArrayBindingPattern then
        if children == parentNode:ElementList() then
            originalList = originalParent:ElementList()
        end
    elseif k == Kind.NamedImports or k == Kind.NamedExports then
        originalList = originalParent:ElementList()
    elseif k == Kind.ImportAttributes then
        originalList = originalParent:AsImportAttributes().attributes
    end

    -- if we have the original list, we can use it's result.
    if originalList ~= nil then
        return originalList:HasTrailingComma()
    end

    return false
end

function Printer:writeDelimiter(format)
    local d = format & LF.LFDelimitersMask
    if d == LF.LFNone then
        -- break
    elseif d == LF.LFCommaDelimited then
        self:writePunctuation(",")
    elseif d == LF.LFBarDelimited then
        self:writeSpace()
        self:writePunctuation("|")
    elseif d == LF.LFAsteriskDelimited then
        self:writeSpace()
        self:writePunctuation("*")
        self:writeSpace()
    elseif d == LF.LFAmpersandDelimited then
        self:writeSpace()
        self:writePunctuation("&")
    end
end

-- Emits a list without brackets or raising events.
--
-- NOTE: You probably don't want to call this directly and should be using `emitList` instead.
-- `children` is a plain array of nodes.
function Printer:emitListItems(emit, parentNode, children, format, hasTrailingComma, childrenTextRange)
    -- Write the opening line terminator or leading whitespace.
    local mayEmitInterveningComments = format & LF.LFNoInterveningComments == 0
    local shouldEmitInterveningComments = mayEmitInterveningComments

    local leadingLineTerminatorCount = 0
    if #children > 0 then
        leadingLineTerminatorCount = self:getLeadingLineTerminatorCount(parentNode, children[1], format)
    end
    if leadingLineTerminatorCount > 0 then
        for _ = 1, leadingLineTerminatorCount do
            self:writeLine()
        end
        shouldEmitInterveningComments = false
    elseif format & LF.LFSpaceBetweenBraces ~= 0 then
        self:writeSpace()
    end

    -- Increase the indent, if requested.
    if format & LF.LFIndented ~= 0 then
        self:increaseIndent()
    end

    local parentEnd = printer.greatestEnd(-1, parentNode)

    -- Emit each child.
    local previousSibling
    local shouldDecreaseIndentAfterEmit = false
    for _, child in ipairs(children) do
        -- Write the delimiter if this is not the first node.
        if format & LF.LFAsteriskDelimited ~= 0 then
            -- always write JSDoc in the format "\n *"
            self:writeLine()
            self:writeDelimiter(format)
        elseif previousSibling ~= nil then
            -- i.e
            --      function commentedParameters(
            --          /* Parameter a */
            --          a
            --          /* End of parameter a */ -> this comment isn't considered to be trailing comment of parameter "a" due to newline
            --          ,
            if format & LF.LFDelimitersMask ~= 0 and previousSibling:End() ~= parentEnd then
                if not self.commentsDisabled and self:shouldEmitTrailingComments(previousSibling) then
                    self:emitLeadingComments(previousSibling:End(), false --[[elided]])
                end
            end

            self:writeDelimiter(format)

            -- Write either a line terminator or whitespace to separate the elements.
            local separatingLineTerminatorCount = self:getSeparatingLineTerminatorCount(previousSibling, child, format)
            if separatingLineTerminatorCount > 0 then
                -- If a synthesized node in a single-line list starts on a new
                -- line, we should increase the indent.
                if format & (LF.LFLinesMask | LF.LFIndented) == LF.LFSingleLine then
                    self:increaseIndent()
                    shouldDecreaseIndentAfterEmit = true
                end

                if shouldEmitInterveningComments and format & LF.LFDelimitersMask ~= 0 and not ast.PositionIsSynthesized(child:Pos()) and self:shouldEmitLeadingComments(child) then
                    local commentRange = self.emitContext:CommentRange(child)
                    self:emitTrailingCommentsOfPosition(commentRange.pos, format & LF.LFSpaceBetweenSiblings ~= 0, true --[[forceNoNewline]])
                end

                for _ = 1, separatingLineTerminatorCount do
                    self:writeLine()
                end

                shouldEmitInterveningComments = false
            elseif format & LF.LFSpaceBetweenSiblings ~= 0 then
                self:writeSpace()
            end
        end

        -- Emit this child.
        if shouldEmitInterveningComments and self:shouldEmitLeadingComments(child) then
            local commentRange = self.emitContext:CommentRange(child)
            self:emitTrailingCommentsOfPosition(commentRange.pos, false --[[prefixSpace]], false --[[forceNoNewline]])
        else
            shouldEmitInterveningComments = mayEmitInterveningComments
        end

        self.nextListElementPos = child:Pos()
        emit(self, child)

        if shouldDecreaseIndentAfterEmit then
            self:decreaseIndent()
            shouldDecreaseIndentAfterEmit = false
        end

        previousSibling = child
    end

    -- Write a trailing comma, if requested.
    local skipTrailingComments = self.commentsDisabled or not self:shouldEmitTrailingComments(previousSibling)
    local emitTrailingComma = hasTrailingComma and format & LF.LFAllowTrailingComma ~= 0 and format & LF.LFCommaDelimited ~= 0
    if emitTrailingComma then
        if previousSibling ~= nil and not skipTrailingComments then
            self:emitToken(Kind.CommaToken, previousSibling:End(), WriteKind.Punctuation, previousSibling)
        else
            self:writePunctuation(",")
        end
    end

    -- Emit any trailing comment of the last element in the list
    -- i.e
    --       var array = [...
    --          2
    --          /* end of element 2 */
    --       ];
    if previousSibling ~= nil and parentEnd ~= previousSibling:End() and format & LF.LFDelimitersMask ~= 0 and not skipTrailingComments then
        local commentsPos
        if emitTrailingComma and childrenTextRange:End() > 0 then
            commentsPos = childrenTextRange:End()
        else
            commentsPos = previousSibling:End()
        end
        self:emitLeadingComments(commentsPos, false --[[elided]])
    end

    -- Decrease the indent, if requested.
    if format & LF.LFIndented ~= 0 then
        self:decreaseIndent()
    end

    -- Write the closing line terminator or closing whitespace.
    local closingLineTerminatorCount = self:getClosingLineTerminatorCount(parentNode, core.LastOrNil(children), format, childrenTextRange)
    if closingLineTerminatorCount > 0 then
        for _ = 1, closingLineTerminatorCount do
            self:writeLine()
        end
    elseif format & (LF.LFSpaceAfterList | LF.LFSpaceBetweenBraces) ~= 0 then
        self:writeSpace()
    end
end

--
-- General
--

function Printer:Emit(node, sourceFile)
    -- ensure a reusable writer
    if self.ownWriter == nil then
        self.ownWriter = printer.NewTextWriter(core.NewLineKind_GetNewLineCharacter(self.options.newLine), 0)
    end

    self:Write(node, sourceFile, self.ownWriter, nil --[[sourceMapGenerator]])
    local text = self.ownWriter:String()

    self.ownWriter:Clear()
    return text
end

function Printer:EmitSourceFile(sourceFile)
    return self:Emit(sourceFile, sourceFile)
end

function Printer:setSourceFile(sourceFile)
    self.currentSourceFile = sourceFile
    self.uniqueHelperNames = nil
    self.externalHelpersModuleName = nil
    if sourceFile ~= nil then
        if self.emitContext:EmitFlags(self.emitContext:MostOriginal(sourceFile)) & EF.EFExternalHelpers ~= 0 then
            self.uniqueHelperNames = {}
        end
        self.externalHelpersModuleName = self.emitContext:GetExternalHelpersModuleName(sourceFile)
        self:setSourceMapSource(sourceFile)
    end

    -- !!!
end

-- Dispatch table for Printer:Write, keyed by kind (same cases as the Go switch).
local writeDispatch = {
    -- Pseudo-literals
    [Kind.TemplateHead] = function(p, node) p:emitTemplateHead(node) end,
    [Kind.TemplateMiddle] = function(p, node) p:emitTemplateMiddle(node) end,
    [Kind.TemplateTail] = function(p, node) p:emitTemplateTail(node) end,

    -- Identifiers
    [Kind.Identifier] = function(p, node) p:emitIdentifierName(node) end,

    -- PrivateIdentifiers
    [Kind.PrivateIdentifier] = function(p, node) p:emitPrivateIdentifier(node) end,

    -- Parse tree nodes
    -- Names
    [Kind.QualifiedName] = function(p, node) p:emitQualifiedName(node) end,
    [Kind.ComputedPropertyName] = function(p, node) p:emitComputedPropertyName(node) end,

    -- Signature elements
    [Kind.TypeParameter] = function(p, node) p:emitTypeParameter(node) end,
    [Kind.Parameter] = function(p, node) p:emitParameter(node) end,
    [Kind.Decorator] = function(p, node) p:emitDecorator(node) end,

    -- Type members
    [Kind.PropertySignature] = function(p, node) p:emitPropertySignature(node) end,
    [Kind.PropertyDeclaration] = function(p, node) p:emitPropertyDeclaration(node) end,
    [Kind.MethodSignature] = function(p, node) p:emitMethodSignature(node) end,
    [Kind.MethodDeclaration] = function(p, node) p:emitMethodDeclaration(node) end,
    [Kind.ClassStaticBlockDeclaration] = function(p, node) p:emitClassStaticBlockDeclaration(node) end,
    [Kind.Constructor] = function(p, node) p:emitConstructor(node) end,
    [Kind.GetAccessor] = function(p, node) p:emitGetAccessorDeclaration(node) end,
    [Kind.SetAccessor] = function(p, node) p:emitSetAccessorDeclaration(node) end,
    [Kind.CallSignature] = function(p, node) p:emitCallSignature(node) end,
    [Kind.ConstructSignature] = function(p, node) p:emitConstructSignature(node) end,
    [Kind.IndexSignature] = function(p, node) p:emitIndexSignature(node) end,

    -- Binding patterns
    [Kind.ObjectBindingPattern] = function(p, node) p:emitObjectBindingPattern(node) end,
    [Kind.ArrayBindingPattern] = function(p, node) p:emitArrayBindingPattern(node) end,
    [Kind.BindingElement] = function(p, node) p:emitBindingElement(node) end,

    -- Misc
    [Kind.TemplateSpan] = function(p, node) p:emitTemplateSpan(node) end,
    [Kind.SemicolonClassElement] = function(p, node) p:emitSemicolonClassElement(node) end,

    -- Declarations (non-statement)
    [Kind.VariableDeclaration] = function(p, node) p:emitVariableDeclaration(node) end,
    [Kind.VariableDeclarationList] = function(p, node) p:emitVariableDeclarationList(node) end,
    [Kind.ModuleBlock] = function(p, node) p:emitModuleBlock(node) end,
    [Kind.CaseBlock] = function(p, node) p:emitCaseBlock(node) end,
    [Kind.ImportClause] = function(p, node) p:emitImportClause(node) end,
    [Kind.NamespaceImport] = function(p, node) p:emitNamespaceImport(node) end,
    [Kind.NamespaceExport] = function(p, node) p:emitNamespaceExport(node) end,
    [Kind.NamedImports] = function(p, node) p:emitNamedImports(node) end,
    [Kind.ImportSpecifier] = function(p, node) p:emitImportSpecifier(node) end,
    [Kind.NamedExports] = function(p, node) p:emitNamedExports(node) end,
    [Kind.ExportSpecifier] = function(p, node) p:emitExportSpecifier(node) end,
    [Kind.ImportAttributes] = function(p, node) p:emitImportAttributes(node) end,
    [Kind.ImportAttribute] = function(p, node) p:emitImportAttribute(node) end,

    -- Module references
    [Kind.ExternalModuleReference] = function(p, node) p:emitExternalModuleReference(node) end,

    -- JSX (non-expression)
    [Kind.JsxText] = function(p, node) p:emitJsxText(node) end,
    [Kind.JsxOpeningElement] = function(p, node) p:emitJsxOpeningElement(node) end,
    [Kind.JsxOpeningFragment] = function(p, node) p:emitJsxOpeningFragment(node) end,
    [Kind.JsxClosingElement] = function(p, node) p:emitJsxClosingElement(node) end,
    [Kind.JsxClosingFragment] = function(p, node) p:emitJsxClosingFragment(node) end,
    [Kind.JsxAttribute] = function(p, node) p:emitJsxAttribute(node) end,
    [Kind.JsxAttributes] = function(p, node) p:emitJsxAttributes(node) end,
    [Kind.JsxSpreadAttribute] = function(p, node) p:emitJsxSpreadAttribute(node) end,
    [Kind.JsxExpression] = function(p, node) p:emitJsxExpression(node) end,
    [Kind.JsxNamespacedName] = function(p, node) p:emitJsxNamespacedName(node) end,

    -- Clauses
    [Kind.CaseClause] = function(p, node) p:emitCaseClause(node) end,
    [Kind.DefaultClause] = function(p, node) p:emitDefaultClause(node) end,
    [Kind.HeritageClause] = function(p, node) p:emitHeritageClause(node) end,
    [Kind.CatchClause] = function(p, node) p:emitCatchClause(node) end,

    -- Property assignments
    [Kind.PropertyAssignment] = function(p, node) p:emitPropertyAssignment(node) end,
    [Kind.ShorthandPropertyAssignment] = function(p, node) p:emitShorthandPropertyAssignment(node) end,
    [Kind.SpreadAssignment] = function(p, node) p:emitSpreadAssignment(node) end,

    -- Enum
    [Kind.EnumMember] = function(p, node) p:emitEnumMember(node) end,

    -- Top-level nodes
    [Kind.SourceFile] = function(p, node) p:emitSourceFile(node) end,

    -- Transformation nodes
    [Kind.NotEmittedTypeElement] = function(p, node) p:emitNotEmittedTypeElement(node) end,
}

function Printer:Write(node, sourceFile, writer, sourceMapGenerator)
    local savedCurrentSourceFile = self.currentSourceFile
    local savedWriter = self.writer
    local savedUniqueHelperNames = self.uniqueHelperNames
    local savedSourceMapsDisabled = self.sourceMapsDisabled
    local savedSourceMapGenerator = self.sourceMapGenerator
    local savedSourceMapSource = self.sourceMapSource
    local savedSourceMapSourceIndex = self.sourceMapSourceIndex
    local savedSourceMapLineCharCache = self.sourceMapLineCharCache

    self.sourceMapsDisabled = sourceMapGenerator == nil
    self.sourceMapGenerator = sourceMapGenerator
    self.sourceMapSource = nil
    self.sourceMapSourceIndex = -1
    self.sourceMapLineCharCache = nil

    self:setSourceFile(sourceFile)
    if self.options.omitTrailingSemicolon then
        writer = printer.getTrailingSemicolonDeferringWriter(writer)
    end
    self.writer = writer
    self.writer:Clear()
    if sourceFile ~= nil then
        if self.writer.Grow ~= nil then
            self.writer:Grow(#sourceFile:Text())
        end
    end

    local emit = writeDispatch[node.kind]
    if emit ~= nil then
        emit(self, node)
    elseif ast.IsTypeNode(node) then
        self:emitTypeNodeOutsideExtends(node)
    elseif ast.IsStatement(node) then
        self:emitStatement(node)
    elseif ast.IsExpression(node) then
        self:emitExpression(node, ast.OperatorPrecedence.Lowest)
    elseif ast.IsKeywordKind(node.kind) then
        self:emitKeywordNode(node)
    elseif ast.IsPunctuationKind(node.kind) then
        self:emitPunctuationNode(node)
    elseif ast.IsJSDocKind(node.kind) then
        self:emitJSDocNode(node)
    else
        error("unhandled Node: " .. kindString(node.kind), 0)
    end

    self.currentSourceFile = savedCurrentSourceFile
    self.writer = savedWriter
    self.uniqueHelperNames = savedUniqueHelperNames
    self.sourceMapsDisabled = savedSourceMapsDisabled
    self.sourceMapGenerator = savedSourceMapGenerator
    self.sourceMapSource = savedSourceMapSource
    self.sourceMapSourceIndex = savedSourceMapSourceIndex
    self.sourceMapLineCharCache = savedSourceMapLineCharCache
end

--
-- Comments
--

local function newCommentState(emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd)
    return {
        emitFlags = emitFlags,
        commentRange = commentRange,
        containerPos = containerPos,
        containerEnd = containerEnd,
        declarationListContainerEnd = declarationListContainerEnd,
    }
end

function Printer:emitCommentsBeforeNode(node)
    if not self:shouldEmitComments(node) then
        return nil
    end

    local emitFlags = self.emitContext:EmitFlags(node)
    local commentRange = self.emitContext:CommentRange(node)
    local containerPos = self.containerPos
    local containerEnd = self.containerEnd
    local declarationListContainerEnd = self.declarationListContainerEnd

    -- Emit leading comments
    self:emitLeadingCommentsOfNode(node, emitFlags, commentRange)
    self:emitLeadingSyntheticCommentsOfNode(node, emitFlags)
    if emitFlags & EF.EFNoNestedComments ~= 0 then
        self.commentsDisabled = true
    end

    return newCommentState(emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd)
end

function Printer:emitCommentsAfterNode(node, state)
    if state == nil then
        return
    end

    local emitFlags = state.emitFlags
    local commentRange = state.commentRange
    local containerPos = state.containerPos
    local containerEnd = state.containerEnd
    local declarationListContainerEnd = state.declarationListContainerEnd

    -- Emit trailing comments
    if emitFlags & EF.EFNoNestedComments ~= 0 then
        self.commentsDisabled = false
    end

    self:emitTrailingSyntheticCommentsOfNode(node, emitFlags)
    self:emitTrailingCommentsOfNode(node, emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd)

    -- Preserve comments from erased type annotation
    local typeNode = self.emitContext:GetTypeNode(node)
    if typeNode ~= nil then
        self:emitTrailingCommentsOfNode(node, emitFlags, typeNode.loc, containerPos, containerEnd, declarationListContainerEnd)
    end
end

-- Returns state, pos.
function Printer:emitCommentsBeforeToken(token, pos, contextNode, flags)
    if flags & printer.tefNoComments ~= 0 or self.commentsDisabled then
        -- Still skip trivia so that the returned pos correctly identifies the token position.
        -- This is needed for trailing source map positions (writeTokenText advances pos by token length).
        if self.currentSourceFile ~= nil and not ast.PositionIsSynthesized(pos) then
            pos = scanner.SkipTrivia(self.currentSourceFile:Text(), pos)
        end
        return nil, pos
    end

    local startPos = pos
    if self.currentSourceFile ~= nil then
        pos = scanner.SkipTrivia(self.currentSourceFile:Text(), startPos)
    end

    local node = self.emitContext:ParseNode(contextNode)
    local isSimilarNode = node ~= nil and node.kind == contextNode.kind
    if not isSimilarNode then
        return nil, pos
    end

    if contextNode:Pos() ~= startPos then
        local indentLeading = flags & printer.tefIndentLeadingComments ~= 0
        local needsIndent = indentLeading and self.currentSourceFile ~= nil and not printer.PositionsAreOnSameLine(startPos, pos, self.currentSourceFile)
        self:increaseIndentIf(needsIndent)
        self:emitLeadingComments(startPos, false --[[elided]])
        self:decreaseIndentIf(needsIndent)
    end

    return newCommentState(0, core.NewTextRange(0, 0), 0, 0, 0), pos
end

function Printer:emitCommentsAfterToken(token, pos, contextNode, state)
    if state == nil then
        return
    end

    if contextNode:End() ~= pos then
        local isJsxExprContext = contextNode.kind == Kind.JsxExpression
        self:emitTrailingComments(pos, isJsxExprContext and printer.commentSeparatorNone or printer.commentSeparatorBefore)
    end
end

function Printer:emitDetachedCommentsBeforeStatementList(node, detachedRange)
    if not self:shouldEmitDetachedComments(node) then
        return nil
    end

    local emitFlags = self.emitContext:EmitFlags(node)
    local containerPos = self.containerPos
    local containerEnd = self.containerEnd
    local declarationListContainerEnd = self.declarationListContainerEnd
    local skipLeadingComments = ast.PositionIsSynthesized(detachedRange:Pos()) or emitFlags & EF.EFNoLeadingComments ~= 0

    if not skipLeadingComments then
        self:emitDetachedCommentsAndUpdateCommentsInfo(detachedRange)
    end

    if emitFlags & EF.EFNoNestedComments ~= 0 then
        self.commentsDisabled = true
    end

    return newCommentState(emitFlags, detachedRange, containerPos, containerEnd, declarationListContainerEnd)
end

function Printer:emitDetachedCommentsAfterStatementList(node, detachedRange, state)
    if state == nil then
        return
    end

    local emitFlags = state.emitFlags
    local skipTrailingComments = self.commentsDisabled or ast.PositionIsSynthesized(detachedRange:End()) or emitFlags & EF.EFNoTrailingComments ~= 0

    if not skipTrailingComments then
        local hasWrittenComment = self:emitLeadingComments(detachedRange:End(), false --[[elided]])
        if hasWrittenComment and not self.writer:IsAtStartOfLine() then
            self:writeLine()
        end
    end
end

function Printer:emitLeadingCommentsOfNode(node, emitFlags, commentRange)
    local pos = commentRange:Pos()
    local end_ = commentRange:End()

    -- Save current container state on the stack.
    if (not ast.PositionIsSynthesized(pos) or not ast.PositionIsSynthesized(end_)) and pos ~= end_ then
        -- We have to explicitly check that the node is JsxText because if the compilerOptions.jsx is "preserve" we will not do any transformation.
        -- It is expensive to walk entire tree just to set one kind of node to have no comments.
        local skipLeadingComments = ast.PositionIsSynthesized(pos) or emitFlags & EF.EFNoLeadingComments ~= 0 or node.kind == Kind.JsxText
        local skipTrailingComments = ast.PositionIsSynthesized(end_) or emitFlags & EF.EFNoTrailingComments ~= 0 or node.kind == Kind.JsxText

        -- Emit leading comments if the position is not synthesized and the node
        -- has not opted out from emitting leading comments.
        if not skipLeadingComments then
            self:emitLeadingComments(pos, node.kind == Kind.NotEmittedStatement --[[elided]])
        end

        if not skipLeadingComments or (pos >= 0 and (emitFlags & EF.EFNoLeadingComments) ~= 0) then
            -- Advance the container position if comments get emitted or if they've been disabled explicitly using NoLeadingComments.
            self.containerPos = pos
        end

        if not skipTrailingComments or (end_ >= 0 and (emitFlags & EF.EFNoTrailingComments) ~= 0) then
            -- Advance the container end if comments get emitted or if they've been disabled explicitly using NoTrailingComments.
            self.containerEnd = end_

            -- To avoid invalid comment emit in a down-level binding pattern, we
            -- keep track of the last declaration list container's end
            if node.kind == Kind.VariableDeclarationList then
                self.declarationListContainerEnd = end_
            end
        end
    end
end

function Printer:emitTrailingCommentsOfNode(node, emitFlags, commentRange, containerPos, containerEnd, declarationListContainerEnd)
    local pos = commentRange:Pos()
    local end_ = commentRange:End()
    local skipTrailingComments = end_ < 0 or (emitFlags & EF.EFNoTrailingComments) ~= 0 or node.kind == Kind.JsxText
    if (not ast.PositionIsSynthesized(pos) or not ast.PositionIsSynthesized(end_)) and pos ~= end_ then
        -- Restore previous container state.
        self.containerPos = containerPos
        self.containerEnd = containerEnd
        self.declarationListContainerEnd = declarationListContainerEnd

        -- Emit trailing comments if the position is not synthesized and the node
        -- has not opted out from emitting leading comments and is an emitted node.
        if not skipTrailingComments and node.kind ~= Kind.NotEmittedStatement then
            self:emitTrailingComments(end_, printer.commentSeparatorBefore)
        end
    end
end

function Printer:emitLeadingSyntheticCommentsOfNode(node, emitFlags)
    if emitFlags & EF.EFNoLeadingComments ~= 0 then
        return
    end
    local synth = self.emitContext:GetSyntheticLeadingComments(node)
    for _, c in ipairs(synth or {}) do
        self:emitLeadingSynthesizedComment(c)
    end
end

function Printer:emitLeadingSynthesizedComment(comment)
    if comment.hasLeadingNewLine or comment.kind == Kind.SingleLineCommentTrivia then
        self.writer:WriteLine()
    end
    self:writeSynthesizedComment(comment)
    if comment.hasTrailingNewLine or comment.kind == Kind.SingleLineCommentTrivia then
        self.writer:WriteLine()
    else
        self.writer:WriteSpace(" ")
    end
end

function Printer:emitTrailingSyntheticCommentsOfNode(node, emitFlags)
    if emitFlags & EF.EFNoTrailingComments ~= 0 then
        return
    end
    local synth = self.emitContext:GetSyntheticTrailingComments(node)
    for _, c in ipairs(synth or {}) do
        self:emitTrailingSynthesizedComment(c)
    end
end

function Printer:emitTrailingSynthesizedComment(comment)
    if not self.writer:IsAtStartOfLine() then
        self.writer:WriteSpace(" ")
    end
    self:writeSynthesizedComment(comment)
    if comment.hasTrailingNewLine then
        self.writer:WriteLine()
    end
end

function printer.formatSynthesizedComment(comment)
    if comment.kind == Kind.MultiLineCommentTrivia then
        return "/*" .. comment.text .. "*/"
    end
    return "//" .. comment.text
end

function Printer:writeSynthesizedComment(comment)
    local text = printer.formatSynthesizedComment(comment)
    local lineMap
    if comment.kind == Kind.MultiLineCommentTrivia then
        lineMap = core.ComputeECMALineStarts(text)
    end
    self:writeCommentRangeWorker(text, lineMap, comment.kind, core.NewTextRange(0, #text))
end

function Printer:emitLeadingComments(pos, elided)
    -- Emit the leading comments only if the container's pos doesn't match because the container should take care of emitting these comments
    if self.commentsDisabled or self.currentSourceFile == nil or ast.PositionIsSynthesized(pos) or pos == self.containerPos then
        return false
    end

    local tripleSlash = Tristate.TSUnknown
    if not elided then
        if pos == 0 and self.currentSourceFile ~= nil and self.currentSourceFile.isDeclarationFile then
            tripleSlash = Tristate.TSFalse
        end
    elseif pos == 0 then
        -- If the node will not be emitted in JS, remove all the comments(normal, pinned and ///) associated with the node,
        -- unless it is a triple slash comment at the top of the file.
        -- For Example:
        --      /// <reference-path ...>
        --      declare var x;
        --      /// <reference-path ...>
        --      interface F {}
        --  The first /// will NOT be removed while the second one will be removed even though both node will not be emitted
        tripleSlash = Tristate.TSTrue
    else
        return false
    end

    -- skip detached comments
    if self.detachedCommentsInfo:Len() > 0 then
        local info = self.detachedCommentsInfo:Peek()
        if info.nodePos == pos then
            pos = self.detachedCommentsInfo:Pop().detachedCommentEndPos
        end
    end

    local comments = {}
    for comment in scanner.GetLeadingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), pos) do
        if self:shouldWriteComment(comment) and self:shouldEmitCommentIfTripleSlash(comment, tripleSlash) then
            comments[#comments + 1] = comment
        end
    end

    if #comments > 0 and self:shouldEmitNewLineBeforeLeadingCommentOfPosition(pos, comments[1].pos) then
        self:writeLine()
    end

    -- Leading comments are emitted as /*leading comment1*/space/*leading comment*/space
    return self:emitComments(comments, printer.commentSeparatorAfter)
end

function Printer:shouldEmitCommentIfTripleSlash(comment, tripleSlash)
    if tripleSlash == Tristate.TSTrue then
        return self:isTripleSlashComment(comment)
    elseif tripleSlash == Tristate.TSFalse then
        return not self:isTripleSlashComment(comment)
    else
        return true
    end
end

function Printer:shouldEmitNewLineBeforeLeadingCommentOfPosition(pos, commentPos)
    -- If the leading comments start on different line than the start of node, write new line
    return self.currentSourceFile ~= nil and
        pos ~= commentPos and
        scanner.ComputeLineOfPosition(self.currentSourceFile:ECMALineMap(), pos) ~= scanner.ComputeLineOfPosition(self.currentSourceFile:ECMALineMap(), commentPos)
end

function Printer:emitLeadingCommentsOfPosition(pos)
    if self.commentsDisabled or pos == -1 then
        return
    end

    self:emitLeadingComments(pos, false --[[elided]])
end

function Printer:emitTrailingComments(pos, commentSeparator)
    if self.commentsDisabled then
        return
    end
    -- Emit the trailing comments only if the container's end doesn't match because the container should take care of emitting these comments
    if self.commentsDisabled or self.currentSourceFile == nil or self.containerEnd ~= -1 and (pos == self.containerEnd or pos == self.declarationListContainerEnd) then
        return
    end

    local comments = {}
    for comment in scanner.GetTrailingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), pos) do
        if self:shouldWriteComment(comment) then
            comments[#comments + 1] = comment
        end
    end

    -- trailing comments are normally emitted as space/*trailing comment1*/space/*trailing comment2*/
    self:emitComments(comments, commentSeparator)
end

function Printer:emitTrailingCommentsOfPosition(pos, prefixSpace, forceNoNewline)
    if self.commentsDisabled or self.currentSourceFile == nil then
        return
    end
    if self.containerEnd ~= -1 and (pos == self.containerEnd or pos == self.declarationListContainerEnd) then
        return
    end

    local comments = {}
    for comment in scanner.GetTrailingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), pos) do
        comments[#comments + 1] = comment
    end
    if #comments == 0 then
        return
    end

    for _, comment in ipairs(comments) do
        if prefixSpace then
            if not self:shouldWriteComment(comment) then
                goto continue
            end
            if not self.writer:IsAtStartOfLine() then
                self:writeSpace()
            end
            self:emitComment(comment)
            if comment.hasTrailingNewLine then
                self:writeLine()
            end
            goto continue
        end

        self:emitComment(comment)
        if forceNoNewline then
            if comment.kind == Kind.SingleLineCommentTrivia then
                self:writeLine()
            end
        elseif comment.hasTrailingNewLine then
            self:writeLine()
        else
            self:writeSpace()
        end
        ::continue::
    end
end

function Printer:emitDetachedCommentsAndUpdateCommentsInfo(textRange)
    if self.currentSourceFile == nil then
        return
    end
    local currentDetachedCommentInfo, ok = self:emitDetachedComments(textRange)
    if ok then
        self.detachedCommentsInfo:Push(currentDetachedCommentInfo)
    end
end

-- Returns result (detachedCommentsInfo {nodePos, detachedCommentEndPos}), hasResult.
function Printer:emitDetachedComments(textRange)
    local result = { nodePos = 0, detachedCommentEndPos = 0 }
    local hasResult = false
    if self.currentSourceFile == nil then
        return result, hasResult
    end

    local text = self.currentSourceFile:Text()
    local lineMap = self.currentSourceFile:ECMALineMap()

    local leadingComments = {}
    if self.commentsDisabled then
        -- removeComments is true, only reserve pinned comment at the top of file
        -- For example:
        --      /*! Pinned Comment */
        --
        --      var x = 10;
        if textRange:Pos() == 0 then
            for comment in scanner.GetLeadingCommentRanges(self.emitContext.factory:AsNodeFactory(), text, textRange:Pos()) do
                if printer.IsPinnedComment(text, comment) then
                    leadingComments[#leadingComments + 1] = comment
                end
            end
        end
    else
        -- removeComments is false, just get detached as normal and bypass the process to filter comment
        for comment in scanner.GetLeadingCommentRanges(self.emitContext.factory:AsNodeFactory(), text, textRange:Pos()) do
            leadingComments[#leadingComments + 1] = comment
        end
    end

    if #leadingComments > 0 then
        local detachedComments = {}
        local lastComment
        for i1, comment in ipairs(leadingComments) do
            if i1 > 1 then
                local lastCommentLine = scanner.ComputeLineOfPosition(lineMap, lastComment.end_)
                local commentLine = scanner.ComputeLineOfPosition(lineMap, comment.pos)

                if commentLine >= lastCommentLine + 2 then
                    -- There was a blank line between the last comment and this comment.  This
                    -- comment is not part of the copyright comments.  Return what we have so
                    -- far.
                    break
                end
            end

            detachedComments[#detachedComments + 1] = comment
            lastComment = comment
        end

        if #detachedComments > 0 then
            -- All comments look like they could have been part of the copyright header.  Make
            -- sure there is at least one blank line between it and the node.  If not, it's not
            -- a copyright header.
            local lastCommentLine = scanner.ComputeLineOfPosition(lineMap, core.LastOrNil(detachedComments).end_)
            local nodeLine = scanner.ComputeLineOfPosition(lineMap, scanner.SkipTrivia(text, textRange:Pos()))
            if nodeLine >= lastCommentLine + 2 then
                -- Valid detachedComments

                -- Filter to only comments that should be written (e.g., JSDoc-style in declaration emit)
                local commentsToEmit = {}
                for _, comment in ipairs(detachedComments) do
                    if self:shouldWriteComment(comment) then
                        commentsToEmit[#commentsToEmit + 1] = comment
                    end
                end

                if #commentsToEmit > 0 then
                    if self:shouldEmitNewLineBeforeLeadingCommentOfPosition(textRange:Pos(), commentsToEmit[1].pos) then
                        self:writeLine()
                    end

                    self:emitComments(commentsToEmit, printer.commentSeparatorAfter)
                end
                result = { nodePos = textRange:Pos(), detachedCommentEndPos = core.LastOrNil(detachedComments).end_ }
                hasResult = true
            end
        end
    end
    return result, hasResult
end

-- commentSeparator
printer.commentSeparatorNone = 0
printer.commentSeparatorBefore = 1
printer.commentSeparatorAfter = 2

function Printer:emitComments(comments, commentSeparator)
    local interveningSeparator = false
    if #comments == 0 then
        return false
    end

    if commentSeparator == printer.commentSeparatorBefore then
        self:writeSpace()
    end

    for _, comment in ipairs(comments) do
        if interveningSeparator then
            self:writeSpace()
            interveningSeparator = false
        end

        self:emitComment(comment)

        if comment.kind == Kind.SingleLineCommentTrivia or comment.hasTrailingNewLine and commentSeparator ~= printer.commentSeparatorNone then
            self:writeLine()
        else
            interveningSeparator = commentSeparator ~= printer.commentSeparatorNone
        end
    end

    if interveningSeparator and commentSeparator == printer.commentSeparatorAfter then
        self:writeSpace()
    end

    return true
end

function Printer:emitComment(comment)
    self:emitPos(comment.pos)
    self:writeCommentRange(comment)
    self:emitPos(comment.end_)
end

function Printer:isTripleSlashComment(comment)
    return self.currentSourceFile ~= nil and
        printer.IsRecognizedTripleSlashComment(self.currentSourceFile:Text(), comment)
end

--
-- Source Maps
--

function Printer:setSourceMapSource(source)
    if self.sourceMapsDisabled then
        return
    end

    self.sourceMapSource = source
    self.sourceMapLineCharCache = printer.newLineCharacterCache(source)
    if self.mostRecentSourceMapSource == source then
        self.sourceMapSourceIndex = self.mostRecentSourceMapSourceIndex
        return
    end

    self.sourceMapSourceIsJson = tspath.FileExtensionIs(source:FileName(), tspath.ExtensionJson)
    if self.sourceMapSourceIsJson then
        return
    end

    self.sourceMapSourceIndex = self.sourceMapGenerator:AddSource(source:FileName())
    if self.options.inlineSources then
        local err = self.sourceMapGenerator:SetSourceContent(self.sourceMapSourceIndex, source:Text())
        if err ~= nil then
            error(err, 0)
        end
    end

    self.mostRecentSourceMapSource = source
    self.mostRecentSourceMapSourceIndex = self.sourceMapSourceIndex
end

function Printer:emitPos(pos)
    if self.sourceMapsDisabled or self.sourceMapSource == nil or self.sourceMapGenerator == nil or self.sourceMapSourceIsJson or ast.PositionIsSynthesized(pos) then
        return
    end

    local sourceLine, sourceCharacter = self.sourceMapLineCharCache:getLineAndCharacter(pos)
    local err = self.sourceMapGenerator:AddSourceMapping(
        self.writer:GetLine(),
        self.writer:GetColumn(),
        self.sourceMapSourceIndex,
        sourceLine,
        sourceCharacter
    )
    if err ~= nil then
        error(err, 0)
    end
end

-- TODO: Support emitting nameIndex for source maps (Go: emitPosName, commented out upstream)

function Printer:emitSourcePos(source, pos)
    if source ~= self.sourceMapSource then
        local savedSourceMapSource = self.sourceMapSource
        local savedSourceMapSourceIndex = self.sourceMapSourceIndex
        local savedSourceMapLineCharCache = self.sourceMapLineCharCache
        self:setSourceMapSource(source)
        self:emitPos(pos)
        self.sourceMapSource = savedSourceMapSource
        self.sourceMapSourceIndex = savedSourceMapSourceIndex
        self.sourceMapLineCharCache = savedSourceMapLineCharCache
    else
        self:emitPos(pos)
    end
end

-- TODO: Support emitting nameIndex for source maps (Go: emitSourcePosName, commented out upstream)

local function newSourceMapState(emitFlags, sourceMapRange, hasTokenSourceMapRange)
    return {
        emitFlags = emitFlags,
        sourceMapRange = sourceMapRange,
        hasTokenSourceMapRange = hasTokenSourceMapRange,
    }
end

function Printer:emitSourceMapsBeforeNode(node)
    if not self:shouldEmitSourceMaps(node) then
        return nil
    end

    local emitFlags = self.emitContext:EmitFlags(node)
    local loc = self.emitContext:SourceMapRange(node)

    if not ast.IsNotEmittedStatement(node) and
        emitFlags & EF.EFNoLeadingSourceMap == 0 and
        self.currentSourceFile ~= nil and
        not ast.PositionIsSynthesized(loc:Pos()) then
        self:emitSourcePos(self.sourceMapSource, scanner.SkipTrivia(self.currentSourceFile:Text(), loc:Pos()))
    end

    if emitFlags & EF.EFNoNestedSourceMaps ~= 0 then
        self.sourceMapsDisabled = true
    end

    return newSourceMapState(emitFlags, loc, false)
end

function Printer:emitSourceMapsAfterNode(node, previousState)
    if previousState == nil then
        return
    end

    local emitFlags = previousState.emitFlags
    local loc = previousState.sourceMapRange

    if emitFlags & EF.EFNoNestedSourceMaps ~= 0 then
        self.sourceMapsDisabled = false
    end

    if not ast.IsNotEmittedStatement(node) and
        emitFlags & EF.EFNoTrailingSourceMap == 0 and
        not ast.PositionIsSynthesized(loc:End()) then
        self:emitSourcePos(self.sourceMapSource, loc:End())
    end
end

function Printer:emitSourceMapsBeforeToken(token, pos, contextNode, flags)
    if not self:shouldEmitTokenSourceMaps(token, pos, contextNode, flags) then
        return nil
    end

    local emitFlags = self.emitContext:EmitFlags(contextNode)
    local loc, hasLoc = self.emitContext:TokenSourceMapRange(contextNode, token)
    if hasLoc then
        pos = loc:Pos()
    end
    if pos >= 0 and self.currentSourceFile ~= nil then
        pos = scanner.SkipTrivia(self.currentSourceFile:Text(), pos)
    end
    if emitFlags & EF.EFNoTokenLeadingSourceMaps == 0 and pos >= 0 then
        self:emitSourcePos(self.sourceMapSource, pos)
    end

    return newSourceMapState(emitFlags, loc, hasLoc)
end

function Printer:emitSourceMapsAfterToken(token, pos, contextNode, previousState)
    if previousState == nil then
        return
    end

    local emitFlags = previousState.emitFlags
    local loc = previousState.sourceMapRange
    local hasLoc = previousState.hasTokenSourceMapRange
    if emitFlags & EF.EFNoTokenTrailingSourceMaps == 0 then
        if hasLoc then
            pos = loc:End()
        end
        if pos >= 0 then
            self:emitSourcePos(self.sourceMapSource, pos)
        end
    end
end

--
-- Name Generation
--

function Printer:shouldReuseTempVariableScope(node)
    return node ~= nil and self.emitContext:EmitFlags(node) & EF.EFReuseTempVariableScope ~= 0
end

function Printer:pushNameGenerationScope(node)
    self.nameGenerator:PushScope(self:shouldReuseTempVariableScope(node))
end

function Printer:popNameGenerationScope(node)
    self.nameGenerator:PopScope(self:shouldReuseTempVariableScope(node))
end

function Printer:generateAllNames(nodes)
    if nodes == nil then
        return
    end
    for _, node in ipairs((nodes.nodes or {})) do
        self:generateNames(node)
    end
end

function Printer:generateNames(node)
    if node == nil then
        return
    end

    local k = node.kind
    if k == Kind.Block or k == Kind.CaseClause or k == Kind.DefaultClause then
        self:generateAllNames(node:StatementList())
    elseif k == Kind.LabeledStatement or k == Kind.WithStatement or k == Kind.DoStatement or k == Kind.WhileStatement then
        self:generateNames(node:Statement())
    elseif k == Kind.IfStatement then
        self:generateNames(node.thenStatement)
        self:generateNames(node.elseStatement)
    elseif k == Kind.ForStatement or k == Kind.ForOfStatement or k == Kind.ForInStatement then
        self:generateNames(node:Initializer())
        self:generateNames(node:Statement())
    elseif k == Kind.SwitchStatement then
        self:generateNames(node.caseBlock)
    elseif k == Kind.CaseBlock then
        self:generateAllNames(node.clauses)
    elseif k == Kind.TryStatement then
        self:generateNames(node.tryBlock)
        self:generateNames(node.catchClause)
        self:generateNames(node.finallyBlock)
    elseif k == Kind.CatchClause then
        self:generateNames(node.variableDeclaration)
        self:generateNames(node.block)
    elseif k == Kind.VariableStatement then
        self:generateNames(node.declarationList)
    elseif k == Kind.VariableDeclarationList then
        self:generateAllNames(node.declarations)
    elseif k == Kind.VariableDeclaration or k == Kind.Parameter or k == Kind.BindingElement or k == Kind.ClassDeclaration then
        self:generateNameIfNeeded(node:Name())
    elseif k == Kind.FunctionDeclaration then
        self:generateNameIfNeeded(node:Name())
        if self:shouldReuseTempVariableScope(node) then
            self:generateAllNames(node.parameters)
            self:generateNames(node.body)
        end
    elseif k == Kind.ObjectBindingPattern or k == Kind.ArrayBindingPattern then
        self:generateAllNames(node:ElementList())
    elseif k == Kind.ImportDeclaration or k == Kind.JSImportDeclaration then
        self:generateNames(node.importClause)
    elseif k == Kind.ImportClause then
        self:generateNameIfNeeded(node:Name())
        self:generateNames(node.namedBindings)
    elseif k == Kind.NamespaceImport or k == Kind.NamespaceExport then
        self:generateNameIfNeeded(node:Name())
    elseif k == Kind.NamedImports then
        self:generateAllNames(node:ElementList())
    elseif k == Kind.ImportSpecifier then
        if node.propertyName ~= nil then
            self:generateNameIfNeeded(node.propertyName)
        else
            self:generateNameIfNeeded(node:Name())
        end
    end
end

function Printer:generateAllMemberNames(nodes)
    if nodes == nil then
        return
    end
    for _, node in ipairs((nodes.nodes or {})) do
        self:generateMemberNames(node)
    end
end

function Printer:generateMemberNames(node)
    if node == nil then
        return
    end
    local k = node.kind
    if k == Kind.PropertyAssignment or
        k == Kind.ShorthandPropertyAssignment or
        k == Kind.PropertyDeclaration or
        k == Kind.PropertySignature or
        k == Kind.MethodDeclaration or
        k == Kind.MethodSignature or
        k == Kind.GetAccessor or
        k == Kind.SetAccessor then
        self:generateNameIfNeeded(node:Name())
    end
end

function Printer:generateNameIfNeeded(name)
    if name ~= nil then
        if ast.IsMemberName(name) then
            self:generateName(name)
        elseif ast.IsBindingPattern(name) then
            self:generateNames(name)
        end
    end
end

-- Generate the text for a generated identifier or private identifier
function Printer:generateName(name)
    local _ = self.nameGenerator:GenerateName(name)
end

-- Returns a value indicating whether a name is unique globally or within the current file.
function Printer:isFileLevelUniqueNameInCurrentFile(name, _)
    if self.currentSourceFile ~= nil then
        return self.emitContext:IsFileLevelUniqueName(self.currentSourceFile, name, self.hasGlobalName)
    else
        return true
    end
end

--
-- Scoped operations
--

-- printerState is a table { commentState = ..., sourceMapState = ... }.
function Printer:enterNode(node)
    local state = {}

    if self.onBeforeEmitNode ~= nil then
        self.onBeforeEmitNode(node)
    end

    state.commentState = self:emitCommentsBeforeNode(node)
    state.sourceMapState = self:emitSourceMapsBeforeNode(node)
    return state
end

function Printer:exitNode(node, previousState)
    self:emitSourceMapsAfterNode(node, previousState.sourceMapState)
    self:emitCommentsAfterNode(node, previousState.commentState)

    if self.onAfterEmitNode ~= nil then
        self.onAfterEmitNode(node)
    end
end

function Printer:enterTokenNode(node, flags)
    local state = {}

    if self.onBeforeEmitToken ~= nil then
        self.onBeforeEmitToken(node)
    end

    if flags & printer.tefNoComments == 0 then
        state.commentState = self:emitCommentsBeforeNode(node)
    end
    if flags & printer.tefNoSourceMaps == 0 then
        state.sourceMapState = self:emitSourceMapsBeforeNode(node)
    end
    return state
end

function Printer:exitTokenNode(node, previousState)
    self:emitSourceMapsAfterNode(node, previousState.sourceMapState)
    self:emitCommentsAfterNode(node, previousState.commentState)

    if self.onAfterEmitToken ~= nil then
        self.onAfterEmitToken(node)
    end
end

-- tokenEmitFlags
printer.tefNoComments = 1
printer.tefIndentLeadingComments = 2
printer.tefNoSourceMaps = 4

printer.tefNone = 0

-- Returns state, pos.
function Printer:enterToken(token, pos, contextNode, flags)
    local state = {}
    state.commentState, pos = self:emitCommentsBeforeToken(token, pos, contextNode, flags)
    state.sourceMapState = self:emitSourceMapsBeforeToken(token, pos, contextNode, flags)
    return state, pos
end

function Printer:exitToken(token, pos, contextNode, previousState)
    self:emitSourceMapsAfterToken(token, pos, contextNode, previousState.sourceMapState)
    self:emitCommentsAfterToken(token, pos, contextNode, previousState.commentState)
end

-- ListFormat constants are generated (printer.ListFormat).

function printer.getOpeningBracket(format)
    local b = format & LF.LFBracketsMask
    if b == LF.LFBraces then
        return "{"
    elseif b == LF.LFParenthesis then
        return "("
    elseif b == LF.LFAngleBrackets then
        return "<"
    elseif b == LF.LFSquareBrackets then
        return "["
    else
        error("Unexpected bracket: " .. tostring(b), 0)
    end
end

function printer.getClosingBracket(format)
    local b = format & LF.LFBracketsMask
    if b == LF.LFBraces then
        return "}"
    elseif b == LF.LFParenthesis then
        return ")"
    elseif b == LF.LFAngleBrackets then
        return ">"
    elseif b == LF.LFSquareBrackets then
        return "]"
    else
        error("Unexpected bracket: " .. tostring(b), 0)
    end
end
