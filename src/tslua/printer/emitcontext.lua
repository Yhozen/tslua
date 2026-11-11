local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local EF = printer.EmitFlags

-- Stores side-table information used during transformation that can be read by the printer to customize emit
--
-- NOTE: EmitContext is not guaranteed to be thread-safe.
--
-- Fields: factory (printer NodeFactory), autoGenerate (node -> AutoGenerateInfo), textSource
-- (StringLiteral node -> node), original (node -> node), emitNodes (node -> emitNode; Go
-- core.LinkStore), assignedName, classThis, varScopeStack / letScopeStack (printer.newStack()),
-- emitHelpers (printer.newOrderedSet()). Maps are always tables (never nil).
local EmitContext = {}
EmitContext.__index = EmitContext
printer.EmitContext = EmitContext

-- environmentFlags
printer.environmentFlagsNone = 0
printer.environmentFlagsInParameters = 1 -- currently visiting a parameter list
printer.environmentFlagsVariablesHoistedInParameters = 2 -- a temp variable was hoisted while visiting a parameter list

-- varScope { variables, functions, flags, initializationStatements }
function printer.newVarScope()
    return { variables = {}, functions = {}, flags = printer.environmentFlagsNone, initializationStatements = {} }
end

local function initEmitContextFields(c)
    c.autoGenerate = {}
    c.textSource = {}
    c.original = {}
    c.emitNodes = {}
    c.assignedName = {}
    c.classThis = {}
    c.varScopeStack = printer.newStack()
    c.letScopeStack = printer.newStack()
    c.emitHelpers = printer.newOrderedSet()
end

function printer.NewEmitContext()
    local c = setmetatable({}, EmitContext)
    initEmitContextFields(c)
    c.factory = printer.NewNodeFactory(c)
    return c
end

-- Go pools emit contexts; Lua allocates a fresh one. Returns context, release function.
function printer.GetEmitContext()
    local c = printer.NewEmitContext()
    return c, function()
        c:Reset()
    end
end

function EmitContext:Reset()
    initEmitContextFields(self)
end

function EmitContext:onCreate(node)
    node.flags = node.flags | ast.NodeFlags.Synthesized
end

function EmitContext:onUpdate(updated, original)
    self:SetOriginal(updated, original)
end

function EmitContext:onClone(updated, original)
    self:SetOriginal(updated, original)
    if ast.IsIdentifier(updated) or ast.IsPrivateIdentifier(updated) then
        local autoGenerate = self.autoGenerate[original]
        if autoGenerate ~= nil then
            local autoGenerateCopy = {
                flags = autoGenerate.flags,
                id = autoGenerate.id,
                prefix = autoGenerate.prefix,
                suffix = autoGenerate.suffix,
                node = autoGenerate.node,
            }
            self.autoGenerate[updated] = autoGenerateCopy
        end
    end
end

-- Creates a new NodeVisitor attached to this EmitContext
function EmitContext:NewNodeVisitor(visit)
    return ast.NewNodeVisitor(visit, self.factory:AsNodeFactory(), {
        visitParameters = function(nodes, v) return self:VisitParameters(nodes, v) end,
        visitFunctionBody = function(node, v) return self:VisitFunctionBody(node, v) end,
        visitIterationBody = function(node, v) return self:VisitIterationBody(node, v) end,
        visitTopLevelStatements = function(nodes, v) return self:VisitVariableEnvironment(nodes, v) end,
        visitEmbeddedStatement = function(node, v) return self:VisitEmbeddedStatement(node, v) end,
    })
end

--
-- Environment tracking
--

-- Starts a new VariableEnvironment used to track hoisted `var` statements and function declarations.
--
-- see: https://tc39.es/ecma262/#table-additional-state-components-for-ecmascript-code-execution-contexts
--
-- NOTE: This is the equivalent of `transformContext.startLexicalEnvironment` in Strada.
function EmitContext:StartVariableEnvironment()
    self.varScopeStack:Push(printer.newVarScope())
    self:StartLexicalEnvironment()
end

-- Ends the current VariableEnvironment, returning a list of statements that should be emitted at the start of the current scope.
--
-- NOTE: This is the equivalent of `transformContext.endLexicalEnvironment` in Strada.
function EmitContext:EndVariableEnvironment()
    local scope = self.varScopeStack:Pop()
    local statements = {}
    if #scope.functions > 0 then
        for _, f in ipairs(scope.functions) do
            statements[#statements + 1] = f
        end
    end
    if #scope.variables > 0 then
        local varDeclList = self.factory:NewVariableDeclarationList(self.factory:NewNodeList(scope.variables), ast.NodeFlags.None)
        local varStatement = self.factory:NewVariableStatement(nil --[[modifiers]], varDeclList)
        self:SetEmitFlags(varStatement, EF.EFCustomPrologue)
        statements[#statements + 1] = varStatement
    end
    if #scope.initializationStatements > 0 then
        for _, s in ipairs(scope.initializationStatements) do
            statements[#statements + 1] = s
        end
    end
    for _, s in ipairs(self:EndLexicalEnvironment()) do
        statements[#statements + 1] = s
    end
    return statements
end

-- Invokes c.EndVariableEnvironment() and merges the results into `statements`
function EmitContext:EndAndMergeVariableEnvironmentList(statements)
    local nodes
    if statements ~= nil then
        nodes = statements.nodes
    end

    local result, changed = self:endAndMergeVariableEnvironment(nodes)
    if changed then
        local list = self.factory:NewNodeList(result)
        list.loc = statements.loc
        return list
    end

    return statements
end

-- Invokes c.EndVariableEnvironment() and merges the results into `statements`
function EmitContext:EndAndMergeVariableEnvironment(statements)
    local result = self:endAndMergeVariableEnvironment(statements)
    return result
end

function EmitContext:endAndMergeVariableEnvironment(statements)
    return self:mergeEnvironment(statements, self:EndVariableEnvironment())
end

-- Adds a `var` declaration to the current VariableEnvironment
--
-- NOTE: This is the equivalent of `transformContext.hoistVariableDeclaration` in Strada.
function EmitContext:AddVariableDeclaration(name)
    local varDecl = self.factory:NewVariableDeclaration(name, nil --[[exclamationToken]], nil --[[typeNode]], nil --[[initializer]])
    self:SetEmitFlags(varDecl, EF.EFNoNestedSourceMaps)
    local scope = self.varScopeStack:Peek()
    scope.variables[#scope.variables + 1] = varDecl
    if scope.flags & printer.environmentFlagsInParameters ~= 0 then
        scope.flags = scope.flags | printer.environmentFlagsVariablesHoistedInParameters
    end
end

-- Adds a hoisted function declaration to the current VariableEnvironment
--
-- NOTE: This is the equivalent of `transformContext.hoistFunctionDeclaration` in Strada.
function EmitContext:AddHoistedFunctionDeclaration(node)
    self:SetEmitFlags(node, EF.EFCustomPrologue)
    local scope = self.varScopeStack:Peek()
    scope.functions[#scope.functions + 1] = node
end

-- Starts a new LexicalEnvironment used to track block-scoped `let`, `const`, and `using` declarations.
--
-- see: https://tc39.es/ecma262/#table-additional-state-components-for-ecmascript-code-execution-contexts
--
-- NOTE: This is the equivalent of `transformContext.startBlockScope` in Strada.
-- NOTE: This is *not* the same as `startLexicalEnvironment` in Strada as that method is incorrectly named.
function EmitContext:StartLexicalEnvironment()
    self.letScopeStack:Push(printer.newVarScope())
end

-- Ends the current EndLexicalEnvironment, returning a list of statements that should be emitted at the start of the current scope.
--
-- NOTE: This is the equivalent of `transformContext.endLexicalEnvironment` in Strada.
-- NOTE: This is *not* the same as `endLexicalEnvironment` in Strada as that method is incorrectly named.
function EmitContext:EndLexicalEnvironment()
    local scope = self.letScopeStack:Pop()
    local statements = {}
    if #scope.variables > 0 then
        local varDeclList = self.factory:NewVariableDeclarationList(self.factory:NewNodeList(scope.variables), ast.NodeFlags.Let)
        local varStatement = self.factory:NewVariableStatement(nil --[[modifiers]], varDeclList)
        self:SetEmitFlags(varStatement, EF.EFCustomPrologue)
        statements[#statements + 1] = varStatement
    end
    return statements
end

-- Invokes c.EndLexicalEnvironment() and merges the results into `statements`
function EmitContext:EndAndMergeLexicalEnvironmentList(statements)
    local nodes
    if statements ~= nil then
        nodes = statements.nodes
    end

    local result, changed = self:endAndMergeLexicalEnvironment(nodes)
    if changed then
        local list = self.factory:NewNodeList(result)
        list.loc = statements.loc
        return list
    end

    return statements
end

-- Invokes c.EndLexicalEnvironment() and merges the results into `statements`
function EmitContext:EndAndMergeLexicalEnvironment(statements)
    local result = self:endAndMergeLexicalEnvironment(statements)
    return result
end

-- Invokes c.EndLexicalEnvironment() and merges the results into `statements`
function EmitContext:endAndMergeLexicalEnvironment(statements)
    return self:mergeEnvironment(statements, self:EndLexicalEnvironment())
end

-- Adds a `let` declaration to the current LexicalEnvironment.
function EmitContext:AddLexicalDeclaration(name)
    local varDecl = self.factory:NewVariableDeclaration(name, nil --[[exclamationToken]], nil --[[typeNode]], nil --[[initializer]])
    self:SetEmitFlags(varDecl, EF.EFNoNestedSourceMaps)
    local scope = self.letScopeStack:Peek()
    scope.variables[#scope.variables + 1] = varDecl
end

-- Merges declarations produced by c.EndVariableEnvironment() or c.EndLexicalEnvironment() into a statement list
function EmitContext:MergeEnvironmentList(statements, declarations)
    local result, changed = self:mergeEnvironment((statements.nodes or {}), declarations)
    if changed then
        local list = self.factory:NewNodeList(result)
        list.loc = statements.loc
        return list
    end
    return statements
end

-- Merges declarations produced by c.EndVariableEnvironment() or c.EndLexicalEnvironment() into a slice of statements
function EmitContext:MergeEnvironment(statements, declarations)
    local result = self:mergeEnvironment(statements, declarations)
    return result
end

-- Returns statements, changed. `statements` may be nil (Go nil slice).
function EmitContext:mergeEnvironment(statements, declarations)
    if declarations == nil or #declarations == 0 then
        return statements, false
    end
    statements = statements or {}

    -- When we merge new lexical statements into an existing statement list, we merge them in the following manner:
    --
    -- Given:
    --
    -- | Left                               | Right                               |
    -- |------------------------------------|-------------------------------------|
    -- | [standard prologues (left)]        | [standard prologues (right)]        |
    -- | [hoisted functions (left)]         | [hoisted functions (right)]         |
    -- | [hoisted variables (left)]         | [hoisted variables (right)]         |
    -- | [lexical init statements (left)]   | [lexical init statements (right)]   |
    -- | [other statements (left)]          |                                     |
    --
    -- The resulting statement list will be:
    --
    -- | Result                              |
    -- |-------------------------------------|
    -- | [standard prologues (right)]        |
    -- | [standard prologues (left)]         |
    -- | [hoisted functions (right)]         |
    -- | [hoisted functions (left)]          |
    -- | [hoisted variables (right)]         |
    -- | [hoisted variables (left)]          |
    -- | [lexical init statements (right)]   |
    -- | [lexical init statements (left)]    |
    -- | [other statements (left)]           |
    --
    -- NOTE: It is expected that new lexical init statements must be evaluated before existing lexical init statements,
    -- as the prior transformation may depend on the evaluation of the lexical init statements to be in the correct state.

    local changed = false

    -- find standard prologues on left in the following order: standard directives, hoisted functions, hoisted variables, other custom
    local leftStandardPrologueEnd = printer.findSpanEnd(statements, ast.IsPrologueDirective, 0)
    local leftHoistedFunctionsEnd = printer.findSpanEndWithEmitContext(self, statements, EmitContext.isHoistedFunction, leftStandardPrologueEnd)
    local leftHoistedVariablesEnd = printer.findSpanEndWithEmitContext(self, statements, EmitContext.isHoistedVariableStatement, leftHoistedFunctionsEnd)

    -- find standard prologues on right in the following order: standard directives, hoisted functions, hoisted variables, other custom
    local rightStandardPrologueEnd = printer.findSpanEnd(declarations, ast.IsPrologueDirective, 0)
    local rightHoistedFunctionsEnd = printer.findSpanEndWithEmitContext(self, declarations, EmitContext.isHoistedFunction, rightStandardPrologueEnd)
    local rightHoistedVariablesEnd = printer.findSpanEndWithEmitContext(self, declarations, EmitContext.isHoistedVariableStatement, rightHoistedFunctionsEnd)
    local rightCustomPrologueEnd = printer.findSpanEndWithEmitContext(self, declarations, EmitContext.isCustomPrologue, rightHoistedVariablesEnd)
    if rightCustomPrologueEnd ~= #declarations then
        error("Expected declarations to be valid standard or custom prologues", 0)
    end

    local left = statements

    -- splice other custom prologues from right into left
    if rightCustomPrologueEnd > rightHoistedVariablesEnd then
        left = core.Splice(left, leftHoistedVariablesEnd, 0, table.unpack(core.Slice(declarations, rightHoistedVariablesEnd, rightCustomPrologueEnd)))
        changed = true
    end

    -- splice hoisted variables from right into left
    if rightHoistedVariablesEnd > rightHoistedFunctionsEnd then
        left = core.Splice(left, leftHoistedFunctionsEnd, 0, table.unpack(core.Slice(declarations, rightHoistedFunctionsEnd, rightHoistedVariablesEnd)))
        changed = true
    end

    -- splice hoisted functions from right into left
    if rightHoistedFunctionsEnd > rightStandardPrologueEnd then
        left = core.Splice(left, leftStandardPrologueEnd, 0, table.unpack(core.Slice(declarations, rightStandardPrologueEnd, rightHoistedFunctionsEnd)))
        changed = true
    end

    -- splice standard prologues from right into left (that are not already in left)
    if rightStandardPrologueEnd > 0 then
        if leftStandardPrologueEnd == 0 then
            left = core.Splice(left, 0, 0, table.unpack(core.Slice(declarations, 0, rightStandardPrologueEnd)))
            changed = true
        else
            local leftPrologues = printer.newSet()
            for i = 0, leftStandardPrologueEnd - 1 do
                local leftPrologue = statements[i + 1]
                leftPrologues:Add(leftPrologue:Expression():Text())
            end
            for i = rightStandardPrologueEnd - 1, 0, -1 do
                local rightPrologue = declarations[i + 1]
                if not leftPrologues:Has(rightPrologue:Expression():Text()) then
                    left = core.Concatenate({ rightPrologue }, left)
                    changed = true
                end
            end
        end
    end

    return left, changed
end

function EmitContext:isCustomPrologue(node)
    return self:EmitFlags(node) & EF.EFCustomPrologue ~= 0
end

function EmitContext:isHoistedFunction(node)
    return self:isCustomPrologue(node) and ast.IsFunctionDeclaration(node)
end

function printer.isHoistedVariable(node)
    return ast.IsIdentifier(node:Name()) and node:Initializer() == nil
end

function EmitContext:isHoistedVariableStatement(node)
    return self:isCustomPrologue(node) and
        ast.IsVariableStatement(node) and
        core.Every((node:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes or {}), printer.isHoistedVariable)
end

--
-- Name Generation
--

-- Gets whether a given name has an associated AutoGenerateInfo entry.
function EmitContext:HasAutoGenerateInfo(node)
    if node ~= nil then
        return self.autoGenerate[node] ~= nil
    end
    return false
end

-- Gets the associated AutoGenerateInfo entry for a given name.
function EmitContext:GetAutoGenerateInfo(name)
    if name == nil then
        return nil
    end
    return self.autoGenerate[name]
end

-- Walks the associated AutoGenerateInfo entries of a name to find the root Nopde from which the name should be generated.
function EmitContext:GetNodeForGeneratedName(name)
    local autoGenerate = self.autoGenerate[name]
    if autoGenerate ~= nil and printer.GeneratedIdentifierFlags_IsNode(autoGenerate.flags) then
        return self:getNodeForGeneratedNameWorker(autoGenerate.node, autoGenerate.id)
    end
    return name
end

function EmitContext:getNodeForGeneratedNameWorker(node, autoGenerateId)
    local original = self:Original(node)
    while original ~= nil do
        node = original
        if ast.IsMemberName(node) then
            -- if "node" is a different generated name (having a different "autoGenerateId"), use it and stop traversing.
            local autoGenerate = self.autoGenerate[node]
            if autoGenerate == nil or printer.GeneratedIdentifierFlags_IsNode(autoGenerate.flags) and autoGenerate.id ~= autoGenerateId then
                break
            end
            if printer.GeneratedIdentifierFlags_IsNode(autoGenerate.flags) then
                original = autoGenerate.node
                goto continue
            end
        end
        original = self:Original(node)
        ::continue::
    end
    return node
end

-- AutoGenerateOptions is a plain table { flags = GeneratedIdentifierFlags, prefix = "", suffix = "" }
-- (nil or missing fields mean Go zero values).

-- nextAutoGenerateId (Go atomic.Uint32) is printer.nextAutoGenerateId (factory.lua).

-- AutoGenerateInfo is a table:
--   flags  GeneratedIdentifierFlags -- Specifies whether to auto-generate the text for an identifier.
--   id     AutoGenerateId           -- Ensures unique generated identifiers get unique names, but clones get the same name.
--   prefix string                   -- Optional prefix to apply to the start of the generated name
--   suffix string                   -- Optional suffix to apply to the end of the generated name
--   node   ast.Node                 -- For a GeneratedIdentifierFlagsNode, the node from which to generate an identifier

--
-- Original Node Tracking
--

-- Sets the original node for a given node.
--
-- NOTE: This is the equivalent to `setOriginalNode` in Strada.
function EmitContext:SetOriginal(node, original)
    self:SetOriginalEx(node, original, false)
end

function EmitContext:UnsetOriginal(node)
    self.original[node] = nil
end

function EmitContext:SetOriginalEx(node, original, allowOverwrite)
    if original == nil then
        error("Original cannot be nil.", 0)
    end

    local existing = self.original[node]
    if existing == nil then
        self.original[node] = original
        local emitNode = self.emitNodes[original]
        if emitNode ~= nil then
            self:getEmitNode(node):copyFrom(emitNode)
        end
    elseif not allowOverwrite and existing ~= original then
        error("Original node already set.", 0)
    elseif allowOverwrite then
        self.original[node] = original
    end
end

-- Gets the original node for a given node.
--
-- NOTE: This is the equivalent to reading `node.original` in Strada.
function EmitContext:Original(node)
    return self.original[node]
end

-- Gets the most original node associated with this node by walking Original pointers.
--
-- NOTE: This method is analogous to `getOriginalNode` in the old compiler, but the name has changed to avoid accidental
-- conflation with `SetOriginal`/`Original`
function EmitContext:MostOriginal(node)
    if node ~= nil then
        local original = self:Original(node)
        while original ~= nil do
            node = original
            original = self:Original(node)
        end
    end
    return node
end

-- Gets the original parse tree node for a given node.
--
-- NOTE: This is the equivalent to `getParseTreeNode` in Strada.
function EmitContext:ParseNode(node)
    node = self:MostOriginal(node)
    if node ~= nil and ast.IsParseTreeNode(node) then
        return node
    end
    return nil
end

function EmitContext:IsFileLevelUniqueName(sourceFile, name, hasGlobalName)
    if hasGlobalName ~= nil and hasGlobalName(name) then
        return false
    end
    sourceFile = self:MostOriginal(sourceFile):AsSourceFile()
    return not sourceFile:HasIdentifier(name)
end

--
-- Emit-related Data
--

-- emitNodeFlags
printer.hasCommentRange = 1
printer.hasSourceMapRange = 2

-- SnippetKind constants are generated (printer.SnippetKind.TabStop).

-- SnippetElement is a table { kind = SnippetKind, order = int }.

-- SynthesizedComment is a table { kind = ast.Kind, loc = core.TextRange, hasLeadingNewLine = bool,
-- hasTrailingNewLine = bool, text = string }.

local emitNode = {}
emitNode.__index = emitNode
printer.emitNode = emitNode

function printer.newEmitNode()
    return setmetatable({
        flags = 0,
        emitFlags = EF.EFNone,
        commentRange = core.NewTextRange(0, 0),
        sourceMapRange = core.NewTextRange(0, 0),
        tokenSourceMapRanges = nil,
        helpers = nil,
        externalHelpersModuleName = nil,
        leadingComments = nil,
        trailingComments = nil,
        typeNode = nil,
        snippetElement = nil,
    }, emitNode)
end

-- Go c.emitNodes.Get(node): returns the emitNode for node, creating it if needed.
function EmitContext:getEmitNode(node)
    local e = self.emitNodes[node]
    if e == nil then
        e = printer.newEmitNode()
        self.emitNodes[node] = e
    end
    return e
end

-- NOTE: This method is not guaranteed to be thread-safe
function emitNode:copyFrom(source)
    self.flags = source.flags
    self.emitFlags = source.emitFlags
    self.commentRange = source.commentRange
    self.sourceMapRange = source.sourceMapRange
    if source.tokenSourceMapRanges ~= nil then
        local m = {}
        for k, v in pairs(source.tokenSourceMapRanges) do
            m[k] = v
        end
        self.tokenSourceMapRanges = m
    else
        self.tokenSourceMapRanges = nil
    end
    if source.helpers ~= nil then
        local hs = {}
        for i, h in ipairs(source.helpers) do
            hs[i] = h
        end
        self.helpers = hs
    else
        self.helpers = nil
    end
    self.externalHelpersModuleName = source.externalHelpersModuleName
    if source.snippetElement ~= nil then
        self.snippetElement = { kind = source.snippetElement.kind, order = source.snippetElement.order }
    end
end

function EmitContext:EmitFlags(node)
    local e = self.emitNodes[node]
    if e ~= nil then
        return e.emitFlags
    end
    return EF.EFNone
end

function EmitContext:SetEmitFlags(node, flags)
    self:getEmitNode(node).emitFlags = flags
end

function EmitContext:AddEmitFlags(node, flags)
    local e = self:getEmitNode(node)
    e.emitFlags = e.emitFlags | flags
end

function EmitContext:SnippetElement(node)
    local e = self.emitNodes[node]
    if e ~= nil then
        return e.snippetElement
    end
    return nil
end

function EmitContext:SetSnippetElement(node, snippetElement)
    self:getEmitNode(node).snippetElement = { kind = snippetElement.kind or 0, order = snippetElement.order or 0 }
end

-- Gets the range to use for a node when emitting comments.
function EmitContext:CommentRange(node)
    local e = self.emitNodes[node]
    if e ~= nil and e.flags & printer.hasCommentRange ~= 0 then
        return e.commentRange
    end
    return node.loc
end

-- Sets the range to use for a node when emitting comments.
function EmitContext:SetCommentRange(node, loc)
    local e = self:getEmitNode(node)
    e.commentRange = loc
    e.flags = e.flags | printer.hasCommentRange
end

-- Sets the range to use for a node when emitting comments.
function EmitContext:AssignCommentRange(to, from)
    self:SetCommentRange(to, self:CommentRange(from))
end

-- Gets the range to use for a node when emitting source maps.
function EmitContext:SourceMapRange(node)
    local e = self.emitNodes[node]
    if e ~= nil and e.flags & printer.hasSourceMapRange ~= 0 then
        return e.sourceMapRange
    end
    return node.loc
end

-- Sets the range to use for a node when emitting source maps.
function EmitContext:SetSourceMapRange(node, loc)
    local e = self:getEmitNode(node)
    e.sourceMapRange = loc
    e.flags = e.flags | printer.hasSourceMapRange
end

-- Sets the range to use for a node when emitting source maps.
function EmitContext:AssignSourceMapRange(to, from)
    self:SetSourceMapRange(to, self:SourceMapRange(from))
end

-- Sets the range to use for a node when emitting comments and source maps.
function EmitContext:AssignCommentAndSourceMapRanges(to, from)
    local e = self:getEmitNode(to)
    local commentRange = self:CommentRange(from)
    local sourceMapRange = self:SourceMapRange(from)
    e.commentRange = commentRange
    e.sourceMapRange = sourceMapRange
    e.flags = e.flags | printer.hasCommentRange | printer.hasSourceMapRange
end

-- Gets the range for a token of a node when emitting source maps. Returns loc, ok.
function EmitContext:TokenSourceMapRange(node, kind)
    local e = self.emitNodes[node]
    if e ~= nil and e.tokenSourceMapRanges ~= nil then
        local loc = e.tokenSourceMapRanges[kind]
        if loc ~= nil then
            return loc, true
        end
    end
    return core.NewTextRange(0, 0), false
end

-- Sets the range for a token of a node when emitting source maps.
function EmitContext:SetTokenSourceMapRange(node, kind, loc)
    local e = self:getEmitNode(node)
    if e.tokenSourceMapRanges == nil then
        e.tokenSourceMapRanges = {}
    end
    e.tokenSourceMapRanges[kind] = loc
end

function EmitContext:AssignedName(node)
    return self.assignedName[node]
end

function EmitContext:TextSource(node)
    return self.textSource[node]
end

function EmitContext:SetAssignedName(node, name)
    self.assignedName[node] = name
end

function EmitContext:ClassThis(node)
    return self.classThis[node]
end

function EmitContext:SetClassThis(node, classThis)
    self.classThis[node] = classThis
end

function EmitContext:RequestEmitHelper(helper)
    if helper.scoped then
        error("Cannot request a scoped emit helper", 0)
    end
    for _, h in ipairs(helper.dependencies or {}) do
        self:RequestEmitHelper(h)
    end
    self.emitHelpers:Add(helper)
end

function EmitContext:ReadEmitHelpers()
    local helpers = self.emitHelpers:Values()
    self.emitHelpers:Clear()
    return helpers
end

function EmitContext:AddEmitHelper(node, ...)
    local e = self:getEmitNode(node)
    for _, h in ipairs({ ... }) do
        e.helpers = core.AppendIfUnique(e.helpers, h)
    end
end

function EmitContext:MoveEmitHelpers(source, target, predicate)
    local sourceEmitNode = self.emitNodes[source]
    if sourceEmitNode == nil then
        return
    end
    local sourceEmitHelpers = sourceEmitNode.helpers
    if sourceEmitHelpers == nil or #sourceEmitHelpers == 0 then
        return
    end

    local targetEmitNode = self:getEmitNode(target)
    local helpersRemoved = 0
    for i = 0, #sourceEmitHelpers - 1 do
        local helper = sourceEmitHelpers[i + 1]
        if predicate(helper) then
            helpersRemoved = helpersRemoved + 1
            targetEmitNode.helpers = core.AppendIfUnique(targetEmitNode.helpers, helper)
        elseif helpersRemoved > 0 then
            sourceEmitHelpers[i - helpersRemoved + 1] = helper
        end
    end

    if helpersRemoved > 0 then
        local n = #sourceEmitHelpers
        local kept = {}
        for i = 1, n - helpersRemoved do
            kept[i] = sourceEmitHelpers[i]
        end
        sourceEmitNode.helpers = kept
    end
end

function EmitContext:GetEmitHelpers(node)
    local e = self.emitNodes[node]
    if e ~= nil then
        return e.helpers
    end
    return nil
end

function EmitContext:GetExternalHelpersModuleName(node)
    local parseNode = self:ParseNode(node)
    if parseNode ~= nil then
        local e = self.emitNodes[parseNode]
        if e ~= nil then
            return e.externalHelpersModuleName
        end
    end
    return nil
end

function EmitContext:SetExternalHelpersModuleName(node, name)
    local parseNode = self:ParseNode(node)
    if parseNode == nil then
        error("Node must be a parse tree node or have an Original pointer to a parse tree node.", 0)
    end

    local e = self:getEmitNode(parseNode)
    e.externalHelpersModuleName = name
end

function EmitContext:HasRecordedExternalHelpers(node)
    local parseNode = self:ParseNode(node)
    if parseNode ~= nil then
        local e = self.emitNodes[parseNode]
        return e ~= nil and (e.externalHelpersModuleName ~= nil or e.emitFlags & EF.EFExternalHelpers ~= 0)
    end
    return false
end

function EmitContext:IsCallToHelper(firstSegment, helperName)
    return ast.IsCallExpression(firstSegment) and
        ast.IsIdentifier(firstSegment:Expression()) and
        (self:EmitFlags(firstSegment:Expression()) & EF.EFHelperName) ~= 0 and
        firstSegment:Expression():Text() == helperName
end

--
-- Visitor Hooks
--

function EmitContext:VisitVariableEnvironment(nodes, visitor)
    self:StartVariableEnvironment()
    return self:EndAndMergeVariableEnvironmentList(visitor:VisitNodes(nodes))
end

function EmitContext:VisitParameters(nodes, visitor)
    self:StartVariableEnvironment()
    local scope = self.varScopeStack:Peek()
    local oldFlags = scope.flags
    scope.flags = scope.flags | printer.environmentFlagsInParameters
    nodes = visitor:VisitNodes(nodes)

    -- As of ES2015, any runtime execution of that occurs in for a parameter (such as evaluating an
    -- initializer or a binding pattern), occurs in its own lexical scope. As a result, any expression
    -- that we might transform that introduces a temporary variable would fail as the temporary variable
    -- exists in a different lexical scope. To address this, we move any binding patterns and initializers
    -- in a parameter list to the body if we detect a variable being hoisted while visiting a parameter list
    -- when the emit target is greater than ES2015. (Which is now all targets.)
    if scope.flags & printer.environmentFlagsVariablesHoistedInParameters ~= 0 then
        nodes = self:addDefaultValueAssignmentsIfNeeded(nodes)
    end
    scope.flags = oldFlags
    -- !!! c.suspendVariableEnvironment()
    return nodes
end

function EmitContext:addDefaultValueAssignmentsIfNeeded(nodeList)
    if nodeList == nil then
        return nodeList
    end
    local result
    local nodes = (nodeList.nodes or {})
    for i1, parameter in ipairs(nodes) do
        local updated = self:addDefaultValueAssignmentIfNeeded(parameter:AsParameterDeclaration())
        if updated ~= parameter then
            if result == nil then
                result = {}
                for j, n in ipairs(nodes) do
                    result[j] = n
                end
            end
            result[i1] = updated
        end
    end
    if result ~= nil then
        local res = self.factory:NewNodeList(result)
        res.loc = nodeList.loc
        return res
    end
    return nodeList
end

function EmitContext:addDefaultValueAssignmentIfNeeded(parameter)
    -- A rest parameter cannot have a binding pattern or an initializer,
    -- so let's just ignore it.
    if parameter.dotDotDotToken ~= nil then
        return parameter
    elseif ast.IsBindingPattern(parameter:Name()) then
        return self:addDefaultValueAssignmentForBindingPattern(parameter)
    elseif parameter.initializer ~= nil then
        return self:addDefaultValueAssignmentForInitializer(parameter, parameter:Name(), parameter.initializer)
    end
    return parameter
end

function EmitContext:addDefaultValueAssignmentForBindingPattern(parameter)
    local f = self.factory
    local initNode
    if parameter.initializer ~= nil then
        initNode = f:NewConditionalExpression(
            f:NewStrictEqualityExpression(
                f:NewGeneratedNameForNode(parameter),
                f:NewVoidZeroExpression()
            ),
            f:NewToken(Kind.QuestionToken),
            parameter.initializer,
            f:NewToken(Kind.ColonToken),
            f:NewGeneratedNameForNode(parameter)
        )
    else
        initNode = f:NewGeneratedNameForNode(parameter)
    end
    self:AddInitializationStatement(f:NewVariableStatement(
        nil,
        f:NewVariableDeclarationList(f:NewNodeList({ f:NewVariableDeclaration(
            parameter:Name(),
            nil,
            parameter.type,
            initNode
        ) }), ast.NodeFlags.None)
    ))
    return f:UpdateParameterDeclaration(
        parameter,
        parameter:Modifiers(),
        parameter.dotDotDotToken,
        f:NewGeneratedNameForNode(parameter),
        parameter.questionToken,
        parameter.type,
        nil
    )
end

function EmitContext:addDefaultValueAssignmentForInitializer(parameter, name, initializer)
    local f = self.factory
    self:AddEmitFlags(initializer, EF.EFNoSourceMap | EF.EFNoComments)
    local nameClone = name:Clone(f)
    self:AddEmitFlags(nameClone, EF.EFNoSourceMap)
    local initAssignment = f:NewAssignmentExpression(
        nameClone,
        initializer
    )
    initAssignment.loc = parameter.loc
    self:AddEmitFlags(initAssignment, EF.EFNoComments)
    local initBlock = f:NewBlock(f:NewNodeList({ f:NewExpressionStatement(initAssignment) }), false)
    initBlock.loc = parameter.loc
    self:AddEmitFlags(initBlock, EF.EFSingleLine | EF.EFNoTrailingSourceMap | EF.EFNoTokenSourceMaps | EF.EFNoComments)
    self:AddInitializationStatement(f:NewIfStatement(
        f:NewTypeCheck(name:Clone(f), "undefined"),
        initBlock,
        nil
    ))
    return f:UpdateParameterDeclaration(
        parameter,
        parameter:Modifiers(),
        parameter.dotDotDotToken,
        parameter:Name(),
        parameter.questionToken,
        parameter.type,
        nil
    )
end

function EmitContext:AddInitializationStatement(node)
    local scope = self.varScopeStack:Peek()
    if scope == nil then
        error("Tried to add an initialization statement without a surrounding variable scope", 0)
    end
    self:AddEmitFlags(node, EF.EFCustomPrologue)
    scope.initializationStatements[#scope.initializationStatements + 1] = node
end

function EmitContext:ConvertToFunctionBlock(node, multiLine)
    if ast.IsBlock(node) then
        return node
    end
    local returnStatement = self.factory:NewReturnStatement(node)
    returnStatement.loc = node.loc
    local statements = self.factory:NewNodeList({ returnStatement })
    statements.loc = node.loc
    local block = self.factory:NewBlock(statements, multiLine)
    block.loc = node.loc
    return block
end

function EmitContext:VisitFunctionBody(node, visitor)
    -- !!! c.resumeVariableEnvironment()
    local updated = visitor:VisitNode(node)
    local declarations = self:EndVariableEnvironment()
    if #declarations == 0 then
        return updated
    end

    if updated == nil then
        return self.factory:NewBlock(self.factory:NewNodeList(declarations), true --[[multiLine]])
    end

    if not ast.IsBlock(updated) then
        self:AddEmitFlags(updated, EF.EFNoComments)
        local block = self:ConvertToFunctionBlock(updated, false --[[multiLine]])
        return self.factory:UpdateBlock(
            block:AsBlock(),
            self:MergeEnvironmentList(block:StatementList(), declarations),
            block:AsBlock().multiLine
        )
    end

    return self.factory:UpdateBlock(
        updated:AsBlock(),
        self:MergeEnvironmentList(updated:StatementList(), declarations),
        updated:AsBlock().multiLine
    )
end

function EmitContext:VisitIterationBody(body, visitor)
    if body == nil then
        return nil
    end

    self:StartLexicalEnvironment()
    local updated = self:VisitEmbeddedStatement(body, visitor)
    if updated == nil then
        error("Expected visitor to return a statement.", 0)
    end

    local statements = self:EndLexicalEnvironment()
    if #statements > 0 then
        if ast.IsBlock(updated) then
            for _, s in ipairs(updated:Statements() or {}) do
                statements[#statements + 1] = s
            end
            local statementsList = self.factory:NewNodeList(statements)
            statementsList.loc = updated:StatementList().loc
            return self.factory:UpdateBlock(updated:AsBlock(), statementsList, updated:AsBlock().multiLine)
        end
        statements[#statements + 1] = updated
        return self.factory:NewBlock(self.factory:NewNodeList(statements), true --[[multiLine]])
    end

    return updated
end

function EmitContext:VisitEmbeddedStatement(node, visitor)
    if node == nil then
        return nil
    end
    local embeddedStatement = visitor:VisitEmbeddedStatement(node)
    if embeddedStatement == nil or ast.IsNotEmittedStatement(embeddedStatement) then
        local emptyStatement = visitor.factory:NewEmptyStatement()
        emptyStatement.loc = node.loc
        self:SetOriginal(emptyStatement, node)
        self:AssignCommentRange(emptyStatement, node)
        return emptyStatement
    end
    return embeddedStatement
end

function EmitContext:SetSyntheticLeadingComments(node, comments)
    self:getEmitNode(node).leadingComments = comments
    return node
end

function EmitContext:AddSyntheticLeadingComment(node, kind, text, hasTrailingNewLine)
    local e = self:getEmitNode(node)
    e.leadingComments = core.Append(e.leadingComments, { kind = kind, loc = core.NewTextRange(-1, -1), hasLeadingNewLine = false, hasTrailingNewLine = hasTrailingNewLine, text = text })
    return node
end

function EmitContext:GetSyntheticLeadingComments(node)
    local e = self.emitNodes[node]
    if e ~= nil then
        return e.leadingComments
    end
    return nil
end

function EmitContext:SetSyntheticTrailingComments(node, comments)
    self:getEmitNode(node).trailingComments = comments
    return node
end

function EmitContext:AddSyntheticTrailingComment(node, kind, text, hasTrailingNewLine)
    local e = self:getEmitNode(node)
    e.trailingComments = core.Append(e.trailingComments, { kind = kind, loc = core.NewTextRange(-1, -1), hasLeadingNewLine = false, hasTrailingNewLine = hasTrailingNewLine, text = text })
    return node
end

function EmitContext:GetSyntheticTrailingComments(node)
    local e = self.emitNodes[node]
    if e ~= nil then
        return e.trailingComments
    end
    return nil
end

-- SetTypeNode stores the original type node on a name node when the type is erased,
-- so the emitter can use the type's position for comment preservation.
function EmitContext:SetTypeNode(node, typeNode)
    self:getEmitNode(node).typeNode = typeNode
end

-- GetTypeNode gets the type node stored on a name node by the type eraser.
function EmitContext:GetTypeNode(node)
    local e = self.emitNodes[node]
    if e ~= nil then
        return e.typeNode
    end
    return nil
end

function EmitContext:NewNotEmittedStatement(node)
    local statement = self.factory:NewNotEmittedStatement()
    statement.loc = node.loc
    self:SetOriginal(statement, node)
    self:AssignCommentRange(statement, node)
    return statement
end
