local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")
local lsproto = require("tslua.lsp.lsproto")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local FindAncestorResult = ast.FindAncestorResult

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function rangeKey(r)
    return r.start.line .. ":" .. r.start.character .. "-" .. r.end_.line .. ":" .. r.end_.character
end

function LanguageService:ProvideDocumentHighlights(ctx, documentUri, documentPosition)
    local result, err = self:provideDocumentHighlightsWorker(ctx, documentUri, documentPosition, nil)
    if err ~= nil then
        return {}, err
    end
    -- Extract highlights for the current file only.
    local documentHighlights = nil
    if result.multiDocumentHighlights ~= nil then
        for _, mh in ipairs(result.multiDocumentHighlights) do
            if mh.uri == documentUri then
                documentHighlights = core.AppendAll(documentHighlights, mh.highlights)
            end
        end
    end
    return { documentHighlights = documentHighlights or {} }, nil
end

function LanguageService:ProvideMultiDocumentHighlights(ctx, documentUri, documentPosition, filesToSearch)
    return self:provideDocumentHighlightsWorker(ctx, documentUri, documentPosition, filesToSearch)
end

function LanguageService:provideDocumentHighlightsWorker(ctx, documentUri, documentPosition, filesToSearch)
    local program, sourceFile = self:getProgramAndFile(documentUri)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, documentPosition, spanmap.Feature.DocumentHighlights)
    local results = {}
    for _, mapped in ipairs(positions or {}) do
        if spanmap.Fidelity_IsSingleSegment(mapped.fidelity) then
            results[#results + 1] = self:provideDocumentHighlightsAtPosition(ctx, documentUri, mapped.position, program, mapped.script, filesToSearch)
        end
    end
    return ls.combineMultiDocumentHighlights(results), nil
end

function LanguageService:provideDocumentHighlightsAtPosition(ctx, documentUri, pos, program, sourceFile, filesToSearch)
    local node = astnav.GetTouchingPropertyName(sourceFile, pos)

    -- Cheap JSX check before resolving files to search.
    if node.parent ~= nil and (node.parent.kind == Kind.JsxClosingElement or (node.parent.kind == Kind.JsxOpeningElement and node.parent:TagName() == node)) then
        local openingElement, closingElement
        if ast.IsJsxElement(node.parent.parent) then
            openingElement = node.parent.parent:AsJsxElement().openingElement
            closingElement = node.parent.parent:AsJsxElement().closingElement
        end
        local highlights = nil
        local kind = lsproto.DocumentHighlightKind.Read
        if openingElement ~= nil then
            local lspRange, fidelity = self:createLspRangeFromNodeForFeature(openingElement, sourceFile, spanmap.Feature.DocumentHighlights)
            if not spanmap.Fidelity_IsNone(fidelity) then
                highlights = core.Append(highlights, { range = lspRange, kind = kind })
            end
        end
        if closingElement ~= nil then
            local lspRange, fidelity = self:createLspRangeFromNodeForFeature(closingElement, sourceFile, spanmap.Feature.DocumentHighlights)
            if not spanmap.Fidelity_IsNone(fidelity) then
                highlights = core.Append(highlights, { range = lspRange, kind = kind })
            end
        end
        local multiHighlights = {
            { uri = documentUri, highlights = highlights },
        }
        return {
            multiDocumentHighlights = multiHighlights,
        }
    end

    -- Resolve the source files to search, deduplicating by file name.
    local sourceFiles = nil
    local seenFiles = collections.NewSetWithSizeHint(core.Len(filesToSearch))
    for _, uri in ipairs(filesToSearch or {}) do
        local fileName = lsproto.DocumentUri_FileName(uri)
        if not seenFiles:AddIfAbsent(fileName) then
            goto continue
        end
        do
            local sf = program:GetSourceFile(fileName)
            if sf ~= nil then
                sourceFiles = core.Append(sourceFiles, sf)
            end
        end
        ::continue::
    end
    if core.Len(sourceFiles) == 0 then
        sourceFiles = { sourceFile }
    end

    local multiHighlights = self:getSemanticDocumentHighlights(ctx, pos, node, program, sourceFiles)
    if core.Len(multiHighlights) == 0 then
        -- Fall back to syntactic highlights for the current file only.
        local syntacticHighlights = self:getSyntacticDocumentHighlights(node, sourceFile)
        if core.Len(syntacticHighlights) > 0 then
            multiHighlights = {
                { uri = documentUri, highlights = syntacticHighlights },
            }
        end
    end
    return { multiDocumentHighlights = multiHighlights or {} }
end

function ls.combineMultiDocumentHighlights(results)
    local byURI = {}
    local seen = {}
    local combinedDocuments = {}
    for _, result in ipairs(results or {}) do
        if result.multiDocumentHighlights == nil then
            goto continue
        end
        for _, document in ipairs(result.multiDocumentHighlights) do
            local combinedDocument = byURI[document.uri]
            if combinedDocument == nil then
                combinedDocument = { uri = document.uri }
                byURI[document.uri] = combinedDocument
                combinedDocuments[#combinedDocuments + 1] = combinedDocument
            end
            local ranges = seen[document.uri]
            if ranges == nil then
                ranges = collections.NewSet()
            end
            for _, highlight in ipairs(document.highlights or {}) do
                if ranges:AddIfAbsent(rangeKey(highlight.range)) then
                    combinedDocument.highlights = core.Append(combinedDocument.highlights, highlight)
                end
            end
            seen[document.uri] = ranges
        end
        ::continue::
    end
    return { multiDocumentHighlights = combinedDocuments }
end

function LanguageService:getSemanticDocumentHighlights(ctx, pos, node, program, sourceFiles)
    local options = ls.newRefOptions({ use = ls.referenceUseNone })
    local referenceEntries = self:getReferencedSymbolsForNode(ctx, pos, node, program, sourceFiles, options)
    if referenceEntries == nil then
        return nil
    end

    -- Group highlights by file
    local fileHighlights = {}
    for _, entry in ipairs(referenceEntries) do
        for _, ref in ipairs(entry.references or {}) do
            local fileName, highlight = self:toDocumentHighlight(ref)
            if highlight == nil then
                goto continue
            end
            do
                local list = fileHighlights[fileName]
                if list == nil then
                    list = {}
                    fileHighlights[fileName] = list
                end
                list[#list + 1] = highlight
            end
            ::continue::
        end
    end

    local result = nil
    for _, sf in ipairs(sourceFiles or {}) do
        local fileName = sf:OriginalFileName()
        local highlights = fileHighlights[fileName]
        if highlights ~= nil then
            result = core.Append(result, {
                uri = lsconv.FileNameToDocumentURI(fileName),
                highlights = highlights,
            })
        end
    end
    return result
end

function LanguageService:toDocumentHighlight(entry)
    entry = self:resolveEntry(entry)
    local fileName = entry.sourceFile:OriginalFileName()

    local kind = lsproto.DocumentHighlightKind.Read
    local lspRange, ok = self:getRangeOfEntryForFeature(entry, spanmap.Feature.DocumentHighlights)
    if not ok then
        return fileName, nil
    end
    if entry.kind == ls.entryKindRange then
        return fileName, {
            range = lspRange,
            kind = kind,
        }
    end

    -- Determine write access for node references.
    if ast.IsWriteAccessForReference(entry.node) then
        kind = lsproto.DocumentHighlightKind.Write
    end

    local dh = {
        range = lspRange,
        kind = kind,
    }

    return fileName, dh
end

function LanguageService:getSyntacticDocumentHighlights(node, sourceFile)
    local k = node.kind
    if k == Kind.IfKeyword or k == Kind.ElseKeyword then
        if ast.IsIfStatement(node.parent) then
            return self:getIfElseOccurrences(node.parent:AsIfStatement(), sourceFile)
        end
        return nil
    elseif k == Kind.ReturnKeyword then
        return self:useParent(node.parent, ast.IsReturnStatement, ls.getReturnOccurrences, sourceFile)
    elseif k == Kind.ThrowKeyword then
        return self:useParent(node.parent, ast.IsThrowStatement, ls.getThrowOccurrences, sourceFile)
    elseif k == Kind.TryKeyword or k == Kind.CatchKeyword or k == Kind.FinallyKeyword then
        local tryStatement
        if node.kind == Kind.CatchKeyword then
            tryStatement = node.parent.parent
        else
            tryStatement = node.parent
        end
        return self:useParent(tryStatement, ast.IsTryStatement, ls.getTryCatchFinallyOccurrences, sourceFile)
    elseif k == Kind.SwitchKeyword then
        return self:useParent(node.parent, ast.IsSwitchStatement, ls.getSwitchCaseDefaultOccurrences, sourceFile)
    elseif k == Kind.CaseKeyword or k == Kind.DefaultKeyword then
        if ast.IsDefaultClause(node.parent) or ast.IsCaseClause(node.parent) then
            return self:useParent(node.parent.parent.parent, ast.IsSwitchStatement, ls.getSwitchCaseDefaultOccurrences, sourceFile)
        end
        return nil
    elseif k == Kind.BreakKeyword or k == Kind.ContinueKeyword then
        return self:useParent(node.parent, ast.IsBreakOrContinueStatement, ls.getBreakOrContinueStatementOccurrences, sourceFile)
    elseif k == Kind.ForKeyword or k == Kind.WhileKeyword or k == Kind.DoKeyword then
        return self:useParent(node.parent, function(n)
            return ast.IsIterationStatement(n, true)
        end, ls.getLoopBreakContinueOccurrences, sourceFile)
    elseif k == Kind.ConstructorKeyword then
        return self:getFromAllDeclarations(ast.IsConstructorDeclaration, { Kind.ConstructorKeyword }, node, sourceFile)
    elseif k == Kind.GetKeyword or k == Kind.SetKeyword then
        return self:getFromAllDeclarations(ast.IsAccessor, { Kind.GetKeyword, Kind.SetKeyword }, node, sourceFile)
    elseif k == Kind.AwaitKeyword then
        return self:useParent(node.parent, ast.IsAwaitExpression, ls.getAsyncAndAwaitOccurrences, sourceFile)
    elseif k == Kind.AsyncKeyword then
        return self:highlightSpans(ls.getAsyncAndAwaitOccurrences(node, sourceFile), sourceFile)
    elseif k == Kind.YieldKeyword then
        return self:highlightSpans(ls.getYieldOccurrences(node, sourceFile), sourceFile)
    elseif k == Kind.InKeyword or k == Kind.OutKeyword then
        return nil
    else
        if ast.IsModifierKind(node.kind) and (ast.IsDeclaration(node.parent) or ast.IsVariableStatement(node.parent)) then
            return self:highlightSpans(ls.getModifierOccurrences(node.kind, node.parent, sourceFile), sourceFile)
        end
        return nil
    end
end

function LanguageService:useParent(node, nodeTest, getNodes, sourceFile)
    if nodeTest(node) then
        return self:highlightSpans(getNodes(node, sourceFile), sourceFile)
    end
    return nil
end

function LanguageService:highlightSpans(nodes, sourceFile)
    if core.Len(nodes) == 0 then
        return nil
    end
    local highlights = nil
    local kind = lsproto.DocumentHighlightKind.Read
    for _, node in ipairs(nodes) do
        if node ~= nil then
            local lspRange, fidelity = self:createLspRangeFromNodeForFeature(node, sourceFile, spanmap.Feature.DocumentHighlights)
            if not spanmap.Fidelity_IsNone(fidelity) then
                highlights = core.Append(highlights, { range = lspRange, kind = kind })
            end
        end
    end
    return highlights
end

function LanguageService:getFromAllDeclarations(nodeTest, keywords, node, sourceFile)
    return self:useParent(node.parent, nodeTest, function(decl, sf)
        local symbolDecls = nil
        if ast.CanHaveSymbol(decl) then
            local symbol = decl:Symbol()
            if symbol ~= nil then
                for _, d in ipairs(symbol.declarations or {}) do
                    if nodeTest(d) then
                        for _, c in ipairs(ls.getChildrenFromNonJSDocNode(d, sourceFile) or {}) do
                            for _, k in ipairs(keywords) do
                                if c.kind == k then
                                    symbolDecls = core.Append(symbolDecls, c)
                                    goto outer
                                end
                            end
                        end
                        ::outer::
                    end
                end
            end
        end
        return symbolDecls
    end, sourceFile)
end

function LanguageService:getIfElseOccurrences(ifStatement, sourceFile)
    local keywords = ls.getIfElseKeywords(ifStatement, sourceFile)
    local kind = lsproto.DocumentHighlightKind.Read
    local highlights = nil

    -- We'd like to highlight else/ifs together if they are only separated by whitespace
    -- (i.e. the keywords are separated by no comments, no newlines).
    local n = core.Len(keywords)
    local i = 0
    while i < n do
        if keywords[i + 1].kind == Kind.ElseKeyword and i < n - 1 then
            local elseKeyword = keywords[i + 1]
            local ifKeyword = keywords[i + 2] -- this *should* always be an 'if' keyword.
            local shouldCombine = true

            -- Avoid recalculating getStart() by iterating backwards.
            local ifTokenStart = scanner.GetTokenPosOfNode(ifKeyword, sourceFile, false)
            if ifTokenStart < 0 then
                ifTokenStart = ifKeyword:Pos()
            end
            local text = sourceFile:Text()
            for j = ifTokenStart - 1, elseKeyword:End(), -1 do
                if not stringutil.IsWhiteSpaceSingleLine(string.byte(text, j + 1)) then
                    shouldCombine = false
                    break
                end
            end
            if shouldCombine then
                local lspRange, fidelity = self:createLspRangeFromBounds(scanner.SkipTrivia(sourceFile:Text(), elseKeyword:Pos()), ifKeyword:End(), sourceFile)
                if not spanmap.Fidelity_IsNone(fidelity) then
                    highlights = core.Append(highlights, { range = lspRange, kind = kind })
                end
                i = i + 2 -- skip the next keyword
                goto continue
            end
        end
        do
            -- Ordinary case: just highlight the keyword.
            local lspRange, fidelity = self:createLspRangeFromNodeForFeature(keywords[i + 1], sourceFile, spanmap.Feature.DocumentHighlights)
            if not spanmap.Fidelity_IsNone(fidelity) then
                highlights = core.Append(highlights, { range = lspRange, kind = kind })
            end
        end
        i = i + 1
        ::continue::
    end
    return highlights
end

function ls.getIfElseKeywords(ifStatement, sourceFile)
    -- We may be at an if statement like those in the range below:
    --
    --   ```
    --   if (...) {
    --   } else [|if (...) {}|]
    --   ````
    --
    -- Traverse upwards through all parent if-statements linked by their else-branches.
    while ast.IsIfStatement(ifStatement.parent) do
        -- See if the parent's `else` is actually the current `if` statement.
        local parentingIf = ifStatement.parent:AsIfStatement()
        local elseStatement = parentingIf.elseStatement
        if elseStatement ~= ifStatement then
            break
        end
        ifStatement = parentingIf
    end

    local keywords = nil

    -- Traverse back down through the else branches, aggregating if/else keywords of if-statements.
    while true do
        local children = ls.getChildrenFromNonJSDocNode(ifStatement, sourceFile) or {}
        if #children > 0 and children[1].kind == Kind.IfKeyword then
            keywords = core.Append(keywords, children[1])
        end
        -- Generally the 'else' keyword is second-to-last, so traverse backwards.
        for i = #children, 1, -1 do
            if children[i].kind == Kind.ElseKeyword then
                keywords = core.Append(keywords, children[i])
                break
            end
        end
        local elseStatement = ifStatement.elseStatement
        if elseStatement == nil or not ast.IsIfStatement(elseStatement) then
            break
        end
        ifStatement = elseStatement:AsIfStatement()
    end
    return keywords
end

function ls.getReturnOccurrences(node, sourceFile)
    local funcNode = ast.FindAncestor(node.parent, ast.IsFunctionLike)
    if funcNode == nil then
        return nil
    end

    local keywords = nil
    local body = funcNode:Body()
    if body ~= nil then
        ast.ForEachReturnStatement(body, function(ret)
            local keyword = astnav.FindChildOfKind(ret, Kind.ReturnKeyword, sourceFile)
            if keyword ~= nil then
                keywords = core.Append(keywords, keyword)
            end
            return false -- continue traversal
        end)

        -- Get all throw statements not in a try block
        local throwStatements = ls.aggregateOwnedThrowStatements(body, sourceFile)
        for _, throw in ipairs(throwStatements or {}) do
            local keyword = astnav.FindChildOfKind(throw, Kind.ThrowKeyword, sourceFile)
            if keyword ~= nil then
                keywords = core.Append(keywords, keyword)
            end
        end
    end
    return keywords
end

function ls.aggregateOwnedThrowStatements(node, sourceFile)
    if ast.IsThrowStatement(node) then
        return { node }
    end
    if ast.IsTryStatement(node) then
        -- Exceptions thrown within a try block lacking a catch clause are "owned" in the current context.
        local statement = node:AsTryStatement()
        local tryBlock = statement.tryBlock
        local catchClause = statement.catchClause
        local finallyBlock = statement.finallyBlock

        local result = nil
        if catchClause ~= nil then
            result = ls.aggregateOwnedThrowStatements(catchClause, sourceFile)
        elseif tryBlock ~= nil then
            result = ls.aggregateOwnedThrowStatements(tryBlock, sourceFile)
        end
        if finallyBlock ~= nil then
            result = core.AppendAll(core.Slice(result), ls.aggregateOwnedThrowStatements(finallyBlock, sourceFile))
        end
        return result
    end
    -- Do not cross function boundaries.
    if ast.IsFunctionLike(node) then
        return nil
    end
    return ls.flatMapChildren(node, sourceFile, ls.aggregateOwnedThrowStatements)
end

function ls.flatMapChildren(node, sourceFile, cb)
    local result = nil

    node:ForEachChild(function(child)
        local value = cb(child, sourceFile)
        if value ~= nil then
            result = core.AppendAll(result, value)
        end
        return false -- continue traversal
    end)
    return result
end

function ls.getThrowOccurrences(node, sourceFile)
    local owner = ls.getThrowStatementOwner(node)
    if owner == nil then
        return nil
    end

    local keywords = nil

    -- Aggregate all throw statements "owned" by this owner.
    local throwStatements = ls.aggregateOwnedThrowStatements(owner, sourceFile)
    for _, throw in ipairs(throwStatements or {}) do
        local keyword = astnav.FindChildOfKind(throw, Kind.ThrowKeyword, sourceFile)
        if keyword ~= nil then
            keywords = core.Append(keywords, keyword)
        end
    end

    -- If the "owner" is a function, then we equate 'return' and 'throw' statements in their
    -- ability to "jump out" of the function, and include occurrences for both
    if ast.IsFunctionBlock(owner) then
        ast.ForEachReturnStatement(owner, function(ret)
            local keyword = astnav.FindChildOfKind(ret, Kind.ReturnKeyword, sourceFile)
            if keyword ~= nil then
                keywords = core.Append(keywords, keyword)
            end
            return false -- continue traversal
        end)
    end

    return keywords
end

-- For lack of a better name, this function takes a throw statement and returns the
-- nearest ancestor that is a try-block (whose try statement has a catch clause),
-- function-block, or source file.
function ls.getThrowStatementOwner(throwStatement)
    local child = throwStatement
    while child.parent ~= nil do
        local parent = child.parent

        if ast.IsFunctionBlock(parent) or parent.kind == Kind.SourceFile then
            return parent
        end

        -- A throw-statement is only owned by a try-statement if the try-statement has
        -- a catch clause, and if the throw-statement occurs within the try block.
        if ast.IsTryStatement(parent) then
            local tryStatement = parent:AsTryStatement()
            if tryStatement.tryBlock == child and tryStatement.catchClause ~= nil then
                return child
            end
        end

        child = parent
    end
    return nil
end

function ls.getTryCatchFinallyOccurrences(node, sourceFile)
    local tryStatement = node:AsTryStatement()

    local keywords = nil
    local token = lsutil.GetFirstToken(node, sourceFile)
    if token ~= nil and token.kind == Kind.TryKeyword then
        keywords = core.Append(keywords, token)
    end

    if tryStatement.catchClause ~= nil then
        local catchToken = astnav.FindChildOfKind(node, Kind.CatchKeyword, sourceFile)
        if catchToken ~= nil then
            keywords = core.Append(keywords, catchToken)
        end
    end

    if tryStatement.finallyBlock ~= nil then
        local finallyKeyword = astnav.FindChildOfKind(node, Kind.FinallyKeyword, sourceFile)
        if finallyKeyword ~= nil then
            keywords = core.Append(keywords, finallyKeyword)
        end
    end

    return keywords
end

function ls.getSwitchCaseDefaultOccurrences(node, sourceFile)
    local switchStatement = node:AsSwitchStatement()

    local keywords = nil
    local token = lsutil.GetFirstToken(node, sourceFile)
    if token.kind == Kind.SwitchKeyword then
        keywords = core.Append(keywords, token)
    end

    local clauses = switchStatement.caseBlock:AsCaseBlock().clauses
    for _, clause in ipairs(clauses.nodes or {}) do
        local clauseToken = lsutil.GetFirstToken(clause, sourceFile)
        if clauseToken.kind == Kind.CaseKeyword or clauseToken.kind == Kind.DefaultKeyword then
            keywords = core.Append(keywords, clauseToken)
        end

        local breakAndContinueStatements = ls.aggregateAllBreakAndContinueStatements(clause, sourceFile)
        for _, statement in ipairs(breakAndContinueStatements or {}) do
            if statement.kind == Kind.BreakStatement and ls.ownsBreakOrContinueStatement(switchStatement, statement) then
                keywords = core.Append(keywords, lsutil.GetFirstToken(statement, sourceFile))
            end
        end
    end

    return keywords
end

function ls.aggregateAllBreakAndContinueStatements(node, sourceFile)
    if ast.IsBreakOrContinueStatement(node) then
        return { node }
    end
    if ast.IsFunctionLike(node) then
        return nil
    end
    return ls.flatMapChildren(node, sourceFile, ls.aggregateAllBreakAndContinueStatements)
end

function ls.ownsBreakOrContinueStatement(owner, statement)
    local actualOwner = ls.getBreakOrContinueOwner(statement)
    if actualOwner == nil then
        return false
    end
    return actualOwner == owner
end

function ls.getBreakOrContinueOwner(statement)
    return ast.FindAncestorOrQuit(statement, function(node)
        local k = node.kind
        local isSwitch = k == Kind.SwitchStatement
        if isSwitch and statement.kind == Kind.ContinueStatement then
            return FindAncestorResult.FindAncestorFalse
        end
        if isSwitch or
            k == Kind.ForStatement or
            k == Kind.ForInStatement or
            k == Kind.ForOfStatement or
            k == Kind.WhileStatement or
            k == Kind.DoStatement then
            -- If the statement is labeled, check if the node is labeled by the statement's label.
            if statement:Label() == nil or ls.isLabeledBy(node, statement:Label():Text()) then
                return FindAncestorResult.FindAncestorTrue
            end
            return FindAncestorResult.FindAncestorFalse
        else
            -- Don't cross function boundaries.
            if ast.IsFunctionLike(node) then
                return FindAncestorResult.FindAncestorQuit
            end
            return FindAncestorResult.FindAncestorFalse
        end
    end)
end

-- Whether or not a 'node' is preceded by a label of the given string.
-- Note: 'node' cannot be a SourceFile.
function ls.isLabeledBy(node, labelName)
    return ast.FindAncestorOrQuit(node.parent, function(owner)
        if not ast.IsLabeledStatement(owner) then
            return FindAncestorResult.FindAncestorQuit
        end
        if owner:Label():Text() == labelName then
            return FindAncestorResult.FindAncestorTrue
        end
        return FindAncestorResult.FindAncestorFalse
    end) ~= nil
end

function ls.getBreakOrContinueStatementOccurrences(node, sourceFile)
    local owner = ls.getBreakOrContinueOwner(node)
    if owner ~= nil then
        local k = owner.kind
        if k == Kind.ForStatement or k == Kind.ForInStatement or k == Kind.ForOfStatement or k == Kind.DoStatement or k == Kind.WhileStatement then
            return ls.getLoopBreakContinueOccurrences(owner, sourceFile)
        elseif k == Kind.SwitchStatement then
            return ls.getSwitchCaseDefaultOccurrences(owner, sourceFile)
        end
    end
    return nil
end

function ls.getLoopBreakContinueOccurrences(node, sourceFile)
    local keywords = nil

    local token = lsutil.GetFirstToken(node, sourceFile)
    if token.kind == Kind.ForKeyword or token.kind == Kind.DoKeyword or token.kind == Kind.WhileKeyword then
        keywords = core.Append(keywords, token)
        if node.kind == Kind.DoStatement then
            local loopTokens = ls.getChildrenFromNonJSDocNode(node, sourceFile) or {}
            for i = #loopTokens, 1, -1 do
                if loopTokens[i].kind == Kind.WhileKeyword then
                    keywords = core.Append(keywords, loopTokens[i])
                    break
                end
            end
        end
    end

    local breakAndContinueStatements = ls.aggregateAllBreakAndContinueStatements(node, sourceFile)
    for _, statement in ipairs(breakAndContinueStatements or {}) do
        local stmtToken = lsutil.GetFirstToken(statement, sourceFile)
        if ls.ownsBreakOrContinueStatement(node, statement) and (stmtToken.kind == Kind.BreakKeyword or stmtToken.kind == Kind.ContinueKeyword) then
            keywords = core.Append(keywords, stmtToken)
        end
    end

    return keywords
end

function ls.getAsyncAndAwaitOccurrences(node, sourceFile)
    local fun = ast.GetContainingFunction(node)
    if fun == nil then
        return nil
    end

    local keywords = nil

    for _, modifier in ipairs(fun:ModifierNodes() or {}) do
        if modifier.kind == Kind.AsyncKeyword then
            keywords = core.Append(keywords, modifier)
        end
    end

    fun:ForEachChild(function(child)
        ls.traverseWithoutCrossingFunction(child, sourceFile, function(c)
            if ast.IsAwaitExpression(c) then
                local token = lsutil.GetFirstToken(c, sourceFile)
                if token.kind == Kind.AwaitKeyword then
                    keywords = core.Append(keywords, token)
                end
            end
        end)
        return false -- continue traversal
    end)

    return keywords
end

function ls.getYieldOccurrences(node, sourceFile)
    local parentFunc = ast.FindAncestor(node.parent, ast.IsFunctionLike)
    if parentFunc == nil then
        return nil
    end

    local keywords = nil

    parentFunc:ForEachChild(function(child)
        ls.traverseWithoutCrossingFunction(child, sourceFile, function(c)
            if ast.IsYieldExpression(c) then
                local token = lsutil.GetFirstToken(c, sourceFile)
                if token.kind == Kind.YieldKeyword then
                    keywords = core.Append(keywords, token)
                end
            end
        end)
        return false -- continue traversal
    end)

    return keywords
end

function ls.traverseWithoutCrossingFunction(node, sourceFile, cb)
    cb(node)
    if not ast.IsFunctionLike(node) and not ast.IsClassLike(node) and not ast.IsInterfaceDeclaration(node) and not ast.IsModuleDeclaration(node) and not ast.IsTypeAliasDeclaration(node) and not ast.IsTypeNode(node) then
        node:ForEachChild(function(child)
            ls.traverseWithoutCrossingFunction(child, sourceFile, cb)
            return false -- continue traversal
        end)
    end
end

function ls.getModifierOccurrences(kind, node, sourceFile)
    local result = nil

    local nodesToSearch = ls.getNodesToSearchForModifier(node, ast.ModifierToFlag(kind))
    for _, n in ipairs(nodesToSearch or {}) do
        local modifier = ls.findModifier(n, kind)
        if modifier ~= nil then
            result = core.Append(result, modifier)
        end
    end
    return result
end

function ls.getNodesToSearchForModifier(declaration, modifierFlag)
    local result = nil

    local container = declaration.parent
    if container == nil then
        return nil
    end

    -- Types of node whose children might have modifiers.
    local k = container.kind
    if k == Kind.ModuleBlock or k == Kind.SourceFile or k == Kind.Block or k == Kind.CaseClause or k == Kind.DefaultClause then
        -- Container is either a class declaration or the declaration is a classDeclaration
        if (modifierFlag & ModifierFlags.Abstract) ~= 0 and ast.IsClassDeclaration(declaration) then
            result = core.AppendAll(result, declaration:Members())
            return core.Append(result, declaration)
        else
            return core.AppendAll(result, container:Statements())
        end
    elseif k == Kind.Constructor or k == Kind.MethodDeclaration or k == Kind.FunctionDeclaration then
        -- Parameters and, if inside a class, also class members
        result = core.AppendAll(result, container:Parameters())
        if ast.IsClassLike(container.parent) then
            result = core.AppendAll(result, container.parent:Members())
        end
        return result
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression or k == Kind.InterfaceDeclaration or k == Kind.TypeLiteral then
        local nodes = container:Members()
        result = core.AppendAll(result, nodes)
        -- If we're an accessibility modifier, we're in an instance member and should search
        -- the constructor's parameter list for instance members as well.
        if (modifierFlag & (ModifierFlags.AccessibilityModifier | ModifierFlags.Readonly)) ~= 0 then
            local constructor = nil

            for _, member in ipairs(nodes or {}) do
                if ast.IsConstructorDeclaration(member) then
                    constructor = member
                    break
                end
            end
            if constructor ~= nil then
                result = core.AppendAll(result, constructor:Parameters())
            end
        elseif (modifierFlag & ModifierFlags.Abstract) ~= 0 then
            result = core.Append(result, container)
        end
        return result
    else
        -- Syntactically invalid positions or unsupported containers
        return nil
    end
end

function ls.findModifier(node, kind)
    for _, modifier in ipairs(node:ModifierNodes() or {}) do
        if modifier.kind == kind then
            return modifier
        end
    end
    return nil
end
