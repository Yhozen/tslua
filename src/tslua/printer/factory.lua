local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local TokenFlags = ast.TokenFlags
local EF = printer.EmitFlags

-- NodeFactory embeds ast.NodeFactory: the fields of the embedded factory are copied onto the
-- printer factory and methods not defined here fall back to ast.NodeFactory.
local NodeFactory = setmetatable({}, { __index = function(_, k) return ast.NodeFactory[k] end })
NodeFactory.__index = NodeFactory
printer.NodeFactory = NodeFactory

function printer.NewNodeFactory(context)
    local base = ast.NewNodeFactory({
        onCreate = function(node) context:onCreate(node) end,
        onUpdate = function(updated, original) context:onUpdate(updated, original) end,
        onClone = function(updated, original) context:onClone(updated, original) end,
    })
    local f = setmetatable({}, NodeFactory)
    for k, v in pairs(base) do
        f[k] = v
    end
    f.emitContext = context
    return f
end

-- Go returns the embedded *ast.NodeFactory; the fields are flattened onto this table, so it is
-- the factory itself.
function NodeFactory:AsNodeFactory()
    return self
end

-- Go: atomic counter shared by all factories.
printer.nextAutoGenerateId = 0

-- options: AutoGenerateOptions { flags, prefix, suffix } (nil or partial means Go zero values).
function NodeFactory:newGeneratedIdentifier(kind, text, node, options)
    options = options or {}
    printer.nextAutoGenerateId = printer.nextAutoGenerateId + 1
    local id = printer.nextAutoGenerateId

    if #text == 0 then
        if node == nil then
            text = string.format("(auto@%d)", id)
        elseif ast.IsMemberName(node) then
            text = node:Text()
        else
            text = string.format("(generated@%d)", ast.GetNodeId(self.emitContext:getNodeForGeneratedNameWorker(node, id)))
        end
        text = printer.FormatGeneratedName(false --[[privateName]], options.prefix or "", text, options.suffix or "")
    end

    local name = self:NewIdentifier(text)
    local autoGenerate = {
        id = id,
        flags = kind | ((options.flags or 0) & ~printer.GeneratedIdentifierFlagsKindMask),
        prefix = options.prefix or "",
        suffix = options.suffix or "",
        node = node,
    }
    if self.emitContext.autoGenerate == nil then
        self.emitContext.autoGenerate = {}
    end
    self.emitContext.autoGenerate[name] = autoGenerate
    return name
end

-- Allocates a new temp variable name, but does not record it in the environment. It is recommended to pass this to either
-- `AddVariableDeclaration` or `AddLexicalDeclaration` to ensure it is properly tracked, if you are not otherwise handling
-- it yourself.
function NodeFactory:NewTempVariable()
    return self:NewTempVariableEx({})
end

-- Allocates a new temp variable name, but does not record it in the environment. It is recommended to pass this to either
-- `AddVariableDeclaration` or `AddLexicalDeclaration` to ensure it is properly tracked, if you are not otherwise handling
-- it yourself.
function NodeFactory:NewTempVariableEx(options)
    return self:newGeneratedIdentifier(printer.GeneratedIdentifierFlagsAuto, "", nil --[[node]], options)
end

-- Allocates a new loop variable name.
function NodeFactory:NewLoopVariable()
    return self:NewLoopVariableEx({})
end

-- Allocates a new loop variable name.
function NodeFactory:NewLoopVariableEx(options)
    return self:newGeneratedIdentifier(printer.GeneratedIdentifierFlagsLoop, "", nil --[[node]], options)
end

-- Allocates a new unique name based on the provided text.
function NodeFactory:NewUniqueName(text)
    return self:NewUniqueNameEx(text, {})
end

-- Allocates a new unique name based on the provided text.
function NodeFactory:NewUniqueNameEx(text, options)
    return self:newGeneratedIdentifier(printer.GeneratedIdentifierFlagsUnique, text, nil --[[node]], options)
end

-- Allocates a new unique name based on the provided node.
function NodeFactory:NewGeneratedNameForNode(node)
    return self:NewGeneratedNameForNodeEx(node, {})
end

-- Allocates a new unique name based on the provided node.
function NodeFactory:NewGeneratedNameForNodeEx(node, options)
    options = options or {}
    local prefix = options.prefix or ""
    local suffix = options.suffix or ""
    local flags = options.flags or 0
    if #prefix > 0 or #suffix > 0 then
        flags = flags | printer.GeneratedIdentifierFlagsOptimistic
    end
    options = { flags = flags, prefix = prefix, suffix = suffix }

    return self:newGeneratedIdentifier(printer.GeneratedIdentifierFlagsNode, "", node, options)
end

function NodeFactory:newGeneratedPrivateIdentifier(kind, text, node, options)
    options = options or {}
    printer.nextAutoGenerateId = printer.nextAutoGenerateId + 1
    local id = printer.nextAutoGenerateId

    if #text == 0 then
        if node == nil then
            text = string.format("(auto@%d)", id)
        elseif ast.IsMemberName(node) then
            text = node:Text()
        else
            text = string.format("(generated@%d)", ast.GetNodeId(self.emitContext:getNodeForGeneratedNameWorker(node, id)))
        end
        text = printer.FormatGeneratedName(true --[[privateName]], options.prefix or "", text, options.suffix or "")
    elseif string.sub(text, 1, 1) ~= "#" then
        error("First character of private identifier must be #: " .. text, 0)
    end

    local name = self:NewPrivateIdentifier(text)
    local autoGenerate = {
        id = id,
        flags = kind | ((options.flags or 0) & ~printer.GeneratedIdentifierFlagsKindMask),
        prefix = options.prefix or "",
        suffix = options.suffix or "",
        node = node,
    }
    if self.emitContext.autoGenerate == nil then
        self.emitContext.autoGenerate = {}
    end
    self.emitContext.autoGenerate[name] = autoGenerate
    return name
end

-- Allocates a new unique private name based on the provided text.
function NodeFactory:NewUniquePrivateName(text)
    return self:NewUniquePrivateNameEx(text, {})
end

-- Allocates a new unique private name based on the provided text.
function NodeFactory:NewUniquePrivateNameEx(text, options)
    return self:newGeneratedPrivateIdentifier(printer.GeneratedIdentifierFlagsUnique, text, nil --[[node]], options)
end

-- Allocates a new unique private name based on the provided node.
function NodeFactory:NewGeneratedPrivateNameForNode(node)
    return self:NewGeneratedPrivateNameForNodeEx(node, {})
end

-- Allocates a new unique private name based on the provided node.
function NodeFactory:NewGeneratedPrivateNameForNodeEx(node, options)
    options = options or {}
    local prefix = options.prefix or ""
    local suffix = options.suffix or ""
    local flags = options.flags or 0
    if #prefix > 0 or #suffix > 0 then
        flags = flags | printer.GeneratedIdentifierFlagsOptimistic
    end
    options = { flags = flags, prefix = prefix, suffix = suffix }

    return self:newGeneratedPrivateIdentifier(printer.GeneratedIdentifierFlagsNode, "", node, options)
end

local textSourceKinds = {
    [Kind.Identifier] = true,
    [Kind.PrivateIdentifier] = true,
    [Kind.JsxNamespacedName] = true,
    [Kind.StringLiteral] = true,
    [Kind.NumericLiteral] = true,
    [Kind.BigIntLiteral] = true,
    [Kind.NoSubstitutionTemplateLiteral] = true,
    [Kind.TemplateHead] = true,
    [Kind.TemplateMiddle] = true,
    [Kind.TemplateTail] = true,
    [Kind.RegularExpressionLiteral] = true,
}

-- Allocates a new StringLiteral whose source text is derived from the provided node. This is often used to create a
-- string representation of an Identifier or NumericLiteral.
function NodeFactory:NewStringLiteralFromNode(textSourceNode)
    local text = ""
    if textSourceKinds[textSourceNode.kind] then
        text = textSourceNode:Text()
    end
    local node = self:NewStringLiteral(text, TokenFlags.None)
    if self.emitContext.textSource == nil then
        self.emitContext.textSource = {}
    end
    self.emitContext.textSource[node] = textSourceNode
    return node
end

--
-- Common Tokens
--

function NodeFactory:NewThisExpression()
    return self:NewKeywordExpression(Kind.ThisKeyword)
end

function NodeFactory:NewTrueExpression()
    return self:NewKeywordExpression(Kind.TrueKeyword)
end

function NodeFactory:NewFalseExpression()
    return self:NewKeywordExpression(Kind.FalseKeyword)
end

--
-- Common Operators
--

function NodeFactory:NewCommaExpression(left, right)
    return self:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], self:NewToken(Kind.CommaToken), right)
end

function NodeFactory:NewAssignmentExpression(left, right)
    return self:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], self:NewToken(Kind.EqualsToken), right)
end

function NodeFactory:NewLogicalORExpression(left, right)
    return self:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], self:NewToken(Kind.BarBarToken), right)
end

function NodeFactory:NewLogicalANDExpression(left, right)
    return self:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], self:NewToken(Kind.AmpersandAmpersandToken), right)
end

-- func (f *NodeFactory) NewLogicalANDExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
-- func (f *NodeFactory) NewBitwiseORExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
-- func (f *NodeFactory) NewBitwiseXORExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
-- func (f *NodeFactory) NewBitwiseANDExpression(left *ast.Expression, right *ast.Expression) *ast.Expression
function NodeFactory:NewStrictEqualityExpression(left, right)
    return self:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], self:NewToken(Kind.EqualsEqualsEqualsToken), right)
end

function NodeFactory:NewStrictInequalityExpression(left, right)
    return self:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], self:NewToken(Kind.ExclamationEqualsEqualsToken), right)
end

--
-- Compound Nodes
--

function NodeFactory:NewVoidZeroExpression()
    return self:NewVoidExpression(self:NewNumericLiteral("0", TokenFlags.None))
end

-- expressions may be nil (Go nil slice); returns the (possibly new) array.
function printer.flattenCommaElement(node, expressions)
    if ast.IsBinaryExpression(node) and ast.NodeIsSynthesized(node) and node.operatorToken.kind == Kind.CommaToken then
        expressions = printer.flattenCommaElement(node.left, expressions)
        expressions = printer.flattenCommaElement(node.right, expressions)
    else
        expressions = expressions or {}
        expressions[#expressions + 1] = node
    end
    return expressions
end

function printer.flattenCommaElements(expressions)
    local result = nil
    for _, expression in ipairs(expressions) do
        result = printer.flattenCommaElement(expression, result)
    end
    return result
end

-- Converts a slice of expressions into a single comma-delimited expression. Returns nil if expressions is nil or empty.
function NodeFactory:InlineExpressions(expressions)
    if expressions == nil or #expressions == 0 then
        return nil
    end
    if #expressions == 1 then
        return expressions[1]
    end
    expressions = printer.flattenCommaElements(expressions)
    local expression = expressions[1]
    for i = 2, #expressions do
        expression = self:NewCommaExpression(expression, expressions[i])
    end
    return expression
end

--
-- Utilities
--

function NodeFactory:CreateExpressionFromEntityName(node)
    if ast.IsQualifiedName(node) then
        local left = self:CreateExpressionFromEntityName(node.left)
        local right = node.right:Clone(self:AsNodeFactory())
        right.loc = node.right.loc
        -- TODO(rbuckton): Does this need to be parented?
        right.parent = node.right.parent
        local propAccess = self:NewPropertyAccessExpression(left, nil, right, NodeFlags.None)
        propAccess.loc = node.loc
        return propAccess
    end
    local res = node:Clone(self:AsNodeFactory())
    res.loc = node.loc
    -- TODO(rbuckton): Does this need to be parented?
    res.parent = node.parent
    return res
end

function NodeFactory:RestoreEnclosingLabel(node, outermostLabeledStatement)
    if outermostLabeledStatement == nil then
        return node
    end
    local innerLabel = node
    if ast.IsLabeledStatement(outermostLabeledStatement.statement) then
        innerLabel = self:RestoreEnclosingLabel(node, outermostLabeledStatement.statement:AsLabeledStatement())
    end
    return self:UpdateLabeledStatement(
        outermostLabeledStatement,
        outermostLabeledStatement.label,
        innerLabel
    )
end

-- CreateForOfBindingStatement creates a statement to bind the iteration value.
function NodeFactory:CreateForOfBindingStatement(node, boundValue)
    if ast.IsVariableDeclarationList(node) then
        local firstDeclaration = node:AsVariableDeclarationList().declarations.nodes[1]
        local updatedDeclaration = self:UpdateVariableDeclaration(
            firstDeclaration:AsVariableDeclaration(),
            firstDeclaration:Name(),
            nil, --[[exclamationToken]]
            nil, --[[type]]
            boundValue
        )
        local statement = self:NewVariableStatement(
            nil,
            self:UpdateVariableDeclarationList(
                node:AsVariableDeclarationList(),
                self:NewNodeList({ updatedDeclaration }),
                node.flags
            )
        )
        statement.loc = node.loc
        return statement
    end
    local updatedExpression = self:NewAssignmentExpression(node, boundValue)
    updatedExpression.loc = node.loc
    local statement = self:NewExpressionStatement(updatedExpression)
    statement.loc = node.loc
    return statement
end

function NodeFactory:NewTypeCheck(value, tag)
    if tag == "null" then
        return self:NewStrictEqualityExpression(value, self:NewKeywordExpression(Kind.NullKeyword))
    elseif tag == "undefined" then
        return self:NewStrictEqualityExpression(value, self:NewVoidZeroExpression())
    else
        return self:NewStrictEqualityExpression(self:NewTypeOfExpression(value), self:NewStringLiteral(tag, TokenFlags.None))
    end
end

function NodeFactory:NewMethodCall(object, methodName, argumentsList)
    -- Preserve the optionality of `object`.
    if ast.IsCallExpression(object) and (object.flags & NodeFlags.OptionalChain ~= 0) then
        return self:NewCallExpression(
            self:NewPropertyAccessExpression(object, nil, methodName, NodeFlags.None),
            nil,
            nil,
            self:NewNodeList(argumentsList or {}),
            NodeFlags.OptionalChain
        )
    end
    return self:NewCallExpression(
        self:NewPropertyAccessExpression(object, nil, methodName, NodeFlags.None),
        nil,
        nil,
        self:NewNodeList(argumentsList or {}),
        NodeFlags.None
    )
end

function NodeFactory:NewGlobalMethodCall(globalObjectName, methodName, argumentsList)
    return self:NewMethodCall(self:NewIdentifier(globalObjectName), self:NewIdentifier(methodName), argumentsList)
end

function NodeFactory:NewFunctionCallCall(target, thisArg, argumentsList)
    if thisArg == nil then
        error("Attempted to construct function call call without this argument expression", 0)
    end
    local args = { thisArg }
    for _, a in ipairs(argumentsList or {}) do
        args[#args + 1] = a
    end
    return self:NewMethodCall(target, self:NewIdentifier("call"), args)
end

function NodeFactory:NewArraySliceCall(array, start)
    local args = nil
    if start ~= 0 then
        args = { self:NewNumericLiteral(string.format("%d", start), TokenFlags.None) }
    end
    return self:NewMethodCall(array, self:NewIdentifier("slice"), args)
end

-- Determines whether a node is a parenthesized expression that can be ignored when recreating outer expressions.
--
-- A parenthesized expression can be ignored when all of the following are true:
--
-- - It's `pos` and `end` are not -1
-- - It does not have a custom source map range
-- - It does not have a custom comment range
-- - It does not have synthetic leading or trailing comments
--
-- If an outermost parenthesized expression is ignored, but the containing expression requires a parentheses around
-- the expression to maintain precedence, a new parenthesized expression should be created automatically when
-- the containing expression is created/updated.
function NodeFactory:isIgnorableParen(node)
    return ast.IsParenthesizedExpression(node) and
        ast.NodeIsSynthesized(node) and
        ast.RangeIsSynthesized(self.emitContext:SourceMapRange(node)) and
        ast.RangeIsSynthesized(self.emitContext:CommentRange(node)) -- &&
    -- len(emitContext.SyntheticLeadingComments(node)) == 0 &&
    -- len(emitContext.SyntheticTrailingComments(node)) == 0
end

function NodeFactory:updateOuterExpression(outerExpression, expression)
    local kind = outerExpression.kind
    if kind == Kind.ParenthesizedExpression then
        return self:UpdateParenthesizedExpression(outerExpression:AsParenthesizedExpression(), expression)
    elseif kind == Kind.TypeAssertionExpression then
        return self:UpdateTypeAssertion(outerExpression:AsTypeAssertion(), outerExpression:Type(), expression)
    elseif kind == Kind.AsExpression then
        return self:UpdateAsExpression(outerExpression:AsAsExpression(), expression, outerExpression:Type())
    elseif kind == Kind.SatisfiesExpression then
        return self:UpdateSatisfiesExpression(outerExpression:AsSatisfiesExpression(), expression, outerExpression:Type())
    elseif kind == Kind.NonNullExpression then
        return self:UpdateNonNullExpression(outerExpression:AsNonNullExpression(), expression, outerExpression.flags)
    elseif kind == Kind.ExpressionWithTypeArguments then
        return self:UpdateExpressionWithTypeArguments(outerExpression:AsExpressionWithTypeArguments(), expression, outerExpression:TypeArgumentList())
    elseif kind == Kind.PartiallyEmittedExpression then
        return self:UpdatePartiallyEmittedExpression(outerExpression:AsPartiallyEmittedExpression(), expression)
    else
        error("Unexpected outer expression kind: " .. tostring(ast.Kind_names[kind]), 0)
    end
end

function NodeFactory:RestoreOuterExpressions(outerExpression, innerExpression, kinds)
    if outerExpression ~= nil and ast.IsOuterExpression(outerExpression, kinds) and not self:isIgnorableParen(outerExpression) then
        return self:updateOuterExpression(
            outerExpression,
            self:RestoreOuterExpressions(outerExpression:Expression(), innerExpression, ast.OuterExpressionKinds.OEKAll)
        )
    end
    return innerExpression
end

-- Ensures `"use strict"` is the first statement of a slice of statements.
function NodeFactory:EnsureUseStrict(statements)
    local first = statements and statements[1]
    if first ~= nil and ast.IsPrologueDirective(first) and first:Expression():Text() == "use strict" then
        return statements
    end
    local useStrictPrologue = self:NewExpressionStatement(self:NewStringLiteral("use strict", TokenFlags.None))
    local result = { useStrictPrologue }
    for _, s in ipairs(statements or {}) do
        result[#result + 1] = s
    end
    return result
end

-- Splits a slice of statements into two parts: standard prologue statements and the rest of the statements
function NodeFactory:SplitStandardPrologue(source)
    for i1, statement in ipairs(source or {}) do
        local i = i1 - 1
        if not ast.IsPrologueDirective(statement) then
            return core.Slice(source, 0, i), core.Slice(source, i, #source)
        end
    end
    return source, nil
end

-- Splits a slice of statements into two parts: custom prologue statements (e.g., with `EFCustomPrologue` set) and the rest of the statements
function NodeFactory:SplitCustomPrologue(source)
    for i1, statement in ipairs(source or {}) do
        local i = i1 - 1
        if ast.IsPrologueDirective(statement) or self.emitContext:EmitFlags(statement) & EF.EFCustomPrologue == 0 then
            return core.Slice(source, 0, i), core.Slice(source, i, #source)
        end
    end
    return nil, source
end

--
-- Declaration Names
--

-- NameOptions: { allowComments, allowSourceMaps } (nil or missing fields mean false).
-- AssignedNameOptions: { allowComments, allowSourceMaps, ignoreAssignedName } (nil or missing fields mean false).

function NodeFactory:getName(node, emitFlags, opts)
    opts = opts or {}
    local nodeName = nil
    if node ~= nil then
        if opts.ignoreAssignedName then
            nodeName = ast.GetNonAssignedNameOfDeclaration(node)
        else
            nodeName = ast.GetNameOfDeclaration(node)
        end
    end

    if nodeName ~= nil then
        local name = nodeName:Clone(self)
        if not opts.allowComments then
            emitFlags = emitFlags | EF.EFNoComments
        end
        if not opts.allowSourceMaps then
            emitFlags = emitFlags | EF.EFNoSourceMap
        end
        self.emitContext:AddEmitFlags(name, emitFlags)
        return name
    end

    return self:NewGeneratedNameForNode(node)
end

-- Gets the local name of a declaration. This is primarily used for declarations that can be referred to by name in the
-- declaration's immediate scope (classes, enums, namespaces). A local name will *never* be prefixed with a module or
-- namespace export modifier like "exports." when emitted as an expression.
function NodeFactory:GetLocalName(node)
    return self:GetLocalNameEx(node, {})
end

-- Gets the local name of a declaration. This is primarily used for declarations that can be referred to by name in the
-- declaration's immediate scope (classes, enums, namespaces). A local name will *never* be prefixed with a module or
-- namespace export modifier like "exports." when emitted as an expression.
function NodeFactory:GetLocalNameEx(node, opts)
    return self:getName(node, EF.EFLocalName, opts)
end

-- Gets the export name of a declaration. This is primarily used for declarations that can be
-- referred to by name in the declaration's immediate scope (classes, enums, namespaces). An
-- export name will *always* be prefixed with an module or namespace export modifier like
-- `"exports."` when emitted as an expression if the name points to an exported symbol.
function NodeFactory:GetExportName(node)
    return self:GetExportNameEx(node, {})
end

-- Gets the export name of a declaration. This is primarily used for declarations that can be
-- referred to by name in the declaration's immediate scope (classes, enums, namespaces). An
-- export name will *always* be prefixed with an module or namespace export modifier like
-- `"exports."` when emitted as an expression if the name points to an exported symbol.
function NodeFactory:GetExportNameEx(node, opts)
    return self:getName(node, EF.EFExportName, opts)
end

-- Gets the name of a declaration to use during emit.
function NodeFactory:GetDeclarationName(node)
    return self:GetDeclarationNameEx(node, {})
end

-- Gets the name of a declaration to use during emit.
function NodeFactory:GetDeclarationNameEx(node, opts)
    opts = opts or {}
    return self:getName(node, EF.EFNone, { allowComments = opts.allowComments or false, allowSourceMaps = opts.allowSourceMaps or false })
end

function NodeFactory:GetNamespaceMemberName(ns, name, opts)
    opts = opts or {}
    if not self.emitContext:HasAutoGenerateInfo(name) then
        name = name:Clone(self)
    end
    local qualifiedName = self:NewPropertyAccessExpression(ns, nil --[[questionDotToken]], name, NodeFlags.None)
    self.emitContext:AssignCommentAndSourceMapRanges(qualifiedName, name)
    if not opts.allowComments then
        self.emitContext:AddEmitFlags(qualifiedName, EF.EFNoComments)
    end
    if not opts.allowSourceMaps then
        self.emitContext:AddEmitFlags(qualifiedName, EF.EFNoSourceMap)
    end
    return qualifiedName
end

-- Gets the export name of a declaration for use in expressions.
--
-- An export name will *always* be prefixed with a module or namespace export modifier like
-- `"exports."` when emitted as an expression if the name points to an exported symbol.
function NodeFactory:GetExternalModuleOrNamespaceExportName(ns, node, allowComments, allowSourceMaps)
    if ns ~= nil and ast.HasSyntacticModifier(node, ast.ModifierFlags.Export) then
        local nameOpts = { allowComments = allowComments, allowSourceMaps = allowSourceMaps }
        return self:GetNamespaceMemberName(ns, self:GetDeclarationNameEx(node, nameOpts), nameOpts)
    end
    return self:GetExportNameEx(node, { allowComments = allowComments, allowSourceMaps = allowSourceMaps })
end

--
-- Emit Helpers
--

-- Allocates a new Identifier representing a reference to a helper function.
function NodeFactory:NewUnscopedHelperName(name)
    local node = self:NewIdentifier(name)
    self.emitContext:SetEmitFlags(node, EF.EFHelperName)
    return node
end

-- TypeScript Helpers

function NodeFactory:NewDecorateHelper(decoratorExpressions, target, memberName, descriptor)
    self.emitContext:RequestEmitHelper(printer.decorateHelper)

    local argumentsArray = {}
    argumentsArray[#argumentsArray + 1] = self:NewArrayLiteralExpression(self:NewNodeList(decoratorExpressions or {}), true)
    argumentsArray[#argumentsArray + 1] = target
    if memberName ~= nil then
        argumentsArray[#argumentsArray + 1] = memberName
        if descriptor ~= nil then
            argumentsArray[#argumentsArray + 1] = descriptor
        end
    end

    return self:NewCallExpression(
        self:NewUnscopedHelperName("__decorate"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList(argumentsArray),
        NodeFlags.None
    )
end

function NodeFactory:NewMetadataHelper(metadataKey, metadataValue)
    self.emitContext:RequestEmitHelper(printer.metadataHelper)

    return self:NewCallExpression(
        self:NewUnscopedHelperName("__metadata"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({
            self:NewStringLiteral(metadataKey, TokenFlags.None),
            metadataValue,
        }),
        NodeFlags.None
    )
end

function NodeFactory:NewParamHelper(expression, parameterOffset, location)
    self.emitContext:RequestEmitHelper(printer.paramHelper)
    local helper = self:NewCallExpression(
        self:NewUnscopedHelperName("__param"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ self:NewNumericLiteral(string.format("%d", parameterOffset), TokenFlags.None), expression }),
        NodeFlags.None
    )
    helper.loc = location
    return helper
end

-- ESNext Helpers

function NodeFactory:NewAddDisposableResourceHelper(envBinding, value, async)
    self.emitContext:RequestEmitHelper(printer.addDisposableResourceHelper)
    local keyword = Kind.FalseKeyword
    if async then
        keyword = Kind.TrueKeyword
    end
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__addDisposableResource"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ envBinding, value, self:NewKeywordExpression(keyword) }),
        NodeFlags.None
    )
end

function NodeFactory:NewDisposeResourcesHelper(envBinding)
    self.emitContext:RequestEmitHelper(printer.disposeResourcesHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__disposeResources"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ envBinding }),
        NodeFlags.None
    )
end

-- Class Fields Helpers

-- PrivateIdentifierKind constants are generated: printer.PrivateIdentifierKind.Field, ...

function NodeFactory:NewClassPrivateFieldGetHelper(receiver, state, kind, fn)
    self.emitContext:RequestEmitHelper(printer.classPrivateFieldGetHelper)
    local args
    if fn == nil then
        args = { receiver, state, self:NewStringLiteral(kind, TokenFlags.None) }
    else
        args = { receiver, state, self:NewStringLiteral(kind, TokenFlags.None), fn }
    end
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__classPrivateFieldGet"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList(args),
        NodeFlags.None
    )
end

function NodeFactory:NewClassPrivateFieldSetHelper(receiver, state, value, kind, fn)
    self.emitContext:RequestEmitHelper(printer.classPrivateFieldSetHelper)
    local args
    if fn == nil then
        args = { receiver, state, value, self:NewStringLiteral(kind, TokenFlags.None) }
    else
        args = { receiver, state, value, self:NewStringLiteral(kind, TokenFlags.None), fn }
    end
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__classPrivateFieldSet"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList(args),
        NodeFlags.None
    )
end

function NodeFactory:NewClassPrivateFieldInHelper(state, receiver)
    self.emitContext:RequestEmitHelper(printer.classPrivateFieldInHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__classPrivateFieldIn"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ state, receiver }),
        NodeFlags.None
    )
end

-- Creates `Object.defineProperty(target, name, descriptor)`.
function NodeFactory:NewObjectDefinePropertyCall(target, name, descriptor)
    return self:NewCallExpression(
        self:NewPropertyAccessExpression(
            self:NewIdentifier("Object"),
            nil,
            self:NewIdentifier("defineProperty"),
            NodeFlags.None
        ),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ target, name, descriptor }),
        NodeFlags.None
    )
end

-- Creates `Reflect.get(target, propertyKey, receiver)`.
function NodeFactory:NewReflectGetCall(target, propertyKey, receiver)
    return self:NewCallExpression(
        self:NewPropertyAccessExpression(
            self:NewIdentifier("Reflect"),
            nil,
            self:NewIdentifier("get"),
            NodeFlags.None
        ),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ target, propertyKey, receiver }),
        NodeFlags.None
    )
end

-- Creates `Reflect.set(target, propertyKey, value, receiver)`.
function NodeFactory:NewReflectSetCall(target, propertyKey, value, receiver)
    return self:NewCallExpression(
        self:NewPropertyAccessExpression(
            self:NewIdentifier("Reflect"),
            nil,
            self:NewIdentifier("set"),
            NodeFlags.None
        ),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ target, propertyKey, value, receiver }),
        NodeFlags.None
    )
end

-- Creates `target.bind(thisArg, ...args)`.
function NodeFactory:NewFunctionBindCall(target, thisArg, argumentsList)
    local args = { thisArg }
    for _, a in ipairs(argumentsList or {}) do
        args[#args + 1] = a
    end
    return self:NewMethodCall(target, self:NewIdentifier("bind"), args)
end

-- Creates `(() => { ...statements })()` — an immediately invoked arrow function.
function NodeFactory:NewImmediatelyInvokedArrowFunction(statements)
    local arrow = self:NewArrowFunction(
        nil, --[[modifiers]]
        nil, --[[typeParameters]]
        self:NewNodeList({}), --[[parameters]]
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:NewToken(Kind.EqualsGreaterThanToken), --[[equalsGreaterThanToken]]
        self:NewBlock(self:NewNodeList(statements or {}), true)
    )
    return self:NewCallExpression(
        self:NewParenthesizedExpression(arrow),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({}),
        NodeFlags.None
    )
end

-- Creates `export default <expression>;`.
function NodeFactory:NewExportDefault(expression)
    return self:NewExportAssignment(nil, false, nil, expression)
end

-- Creates `export { <name> };`.
function NodeFactory:NewExternalModuleExport(name)
    local specifier = self:NewExportSpecifier(false, nil, name)
    local namedExports = self:NewNamedExports(self:NewNodeList({ specifier }))
    return self:NewExportDeclaration(nil, false, namedExports, nil, nil)
end

-- ES2018 Helpers
-- Chains a sequence of expressions using the __assign helper or Object.assign if available in the target
function NodeFactory:NewAssignHelper(attributesSegments, scriptTarget)
    return self:NewCallExpression(self:NewPropertyAccessExpression(self:NewIdentifier("Object"), nil, self:NewIdentifier("assign"), NodeFlags.None), nil, nil, self:NewNodeList(attributesSegments or {}), NodeFlags.None)
end

-- ES2018 Destructuring Helpers

function NodeFactory:NewRestHelper(value, elements, computedTempVariables, location)
    self.emitContext:RequestEmitHelper(printer.restHelper)
    local propertyNames = {}
    local computedTempVariableOffset = 0
    for i1, element in ipairs(elements or {}) do
        if i1 == #elements then
            break
        end
        local propertyName = ast.TryGetPropertyNameOfBindingOrAssignmentElement(element)
        if propertyName ~= nil then
            if ast.IsComputedPropertyName(propertyName) then
                printer.debugAssert(computedTempVariables ~= nil, "Encountered computed property name but 'computedTempVariables' argument was not provided.")
                local temp = computedTempVariables[computedTempVariableOffset + 1]
                computedTempVariableOffset = computedTempVariableOffset + 1
                -- typeof _tmp === "symbol" ? _tmp : _tmp + ""
                propertyNames[#propertyNames + 1] = self:NewConditionalExpression(
                    self:NewTypeCheck(temp, "symbol"),
                    self:NewToken(Kind.QuestionToken),
                    temp,
                    self:NewToken(Kind.ColonToken),
                    self:NewBinaryExpression(nil, temp, nil, self:NewToken(Kind.PlusToken), self:NewStringLiteral("", TokenFlags.None))
                )
            else
                propertyNames[#propertyNames + 1] = self:NewStringLiteralFromNode(propertyName)
            end
        end
    end
    local propNames = self:NewArrayLiteralExpression(self:NewNodeList(propertyNames), false)
    propNames.loc = location
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__rest"),
        nil,
        nil,
        self:NewNodeList({
            value,
            propNames,
        }),
        NodeFlags.None
    )
end

-- ES2018 Helpers

-- Allocates a new Call expression to the `__await` helper.
function NodeFactory:NewAwaitHelper(expression)
    self.emitContext:RequestEmitHelper(printer.awaitHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__await"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ expression }),
        NodeFlags.None
    )
end

-- Allocates a new Call expression to the `__asyncGenerator` helper.
function NodeFactory:NewAsyncGeneratorHelper(generatorFunc, hasLexicalThis)
    self.emitContext:RequestEmitHelper(printer.awaitHelper)
    self.emitContext:RequestEmitHelper(printer.asyncGeneratorHelper)

    -- Mark this node as originally an async function body
    self.emitContext:AddEmitFlags(generatorFunc, EF.EFAsyncFunctionBody | EF.EFReuseTempVariableScope)

    local thisArg
    if hasLexicalThis then
        thisArg = self:NewKeywordExpression(Kind.ThisKeyword)
    else
        thisArg = self:NewVoidZeroExpression()
    end

    return self:NewCallExpression(
        self:NewUnscopedHelperName("__asyncGenerator"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({
            thisArg,
            self:NewIdentifier("arguments"),
            generatorFunc,
        }),
        NodeFlags.None
    )
end

-- Allocates a new Call expression to the `__asyncDelegator` helper.
function NodeFactory:NewAsyncDelegatorHelper(expression)
    self.emitContext:RequestEmitHelper(printer.awaitHelper)
    self.emitContext:RequestEmitHelper(printer.asyncDelegatorHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__asyncDelegator"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ expression }),
        NodeFlags.None
    )
end

-- Allocates a new Call expression to the `__asyncValues` helper.
function NodeFactory:NewAsyncValuesHelper(expression)
    self.emitContext:RequestEmitHelper(printer.asyncValuesHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__asyncValues"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ expression }),
        NodeFlags.None
    )
end

-- !!! ES2017 Helpers

-- Allocates a new Call expression to the `__awaiter` helper.
function NodeFactory:NewAwaiterHelper(hasLexicalThis, argumentsExpression, parameters, body)
    self.emitContext:RequestEmitHelper(printer.awaiterHelper)

    local params
    if parameters ~= nil then
        params = parameters
    else
        params = self:NewNodeList({})
    end

    local generatorFunc = self:NewFunctionExpression(
        nil, --[[modifiers]]
        self:NewToken(Kind.AsteriskToken),
        nil, --[[name]]
        nil, --[[typeParameters]]
        params,
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        body
    )

    -- Mark this node as originally an async function body
    self.emitContext:AddEmitFlags(generatorFunc, EF.EFAsyncFunctionBody | EF.EFReuseTempVariableScope)

    local thisArg
    if hasLexicalThis then
        thisArg = self:NewKeywordExpression(Kind.ThisKeyword)
    else
        thisArg = self:NewVoidZeroExpression()
    end

    local argsArg
    if argumentsExpression ~= nil then
        argsArg = argumentsExpression
    else
        argsArg = self:NewVoidZeroExpression()
    end

    return self:NewCallExpression(
        self:NewUnscopedHelperName("__awaiter"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({
            thisArg,
            argsArg,
            self:NewVoidZeroExpression(),
            generatorFunc,
        }),
        NodeFlags.None
    )
end

-- ES Decorator Helpers

function NodeFactory:NewESDecorateClassContextObject(nameExpr, metadata)
    local props = {
        self:NewPropertyAssignment(nil, self:NewIdentifier("kind"), nil, nil, self:NewStringLiteral("class", 0)),
        self:NewPropertyAssignment(nil, self:NewIdentifier("name"), nil, nil, nameExpr),
        self:NewPropertyAssignment(nil, self:NewIdentifier("metadata"), nil, nil, metadata),
    }
    return self:NewObjectLiteralExpression(self:NewNodeList(props), false)
end

function NodeFactory:NewESDecorateClassElementAccessGetMethod(nameComputed, nameExpr)
    local accessor
    if nameComputed then
        accessor = self:NewElementAccessExpression(self:NewIdentifier("obj"), nil, nameExpr, NodeFlags.None)
    else
        accessor = self:NewPropertyAccessExpression(self:NewIdentifier("obj"), nil, nameExpr, NodeFlags.None)
    end

    local objParam = self:NewParameterDeclaration(nil, nil, self:NewIdentifier("obj"), nil, nil, nil)

    local arrow = self:NewArrowFunction(
        nil, nil,
        self:NewNodeList({ objParam }),
        nil, nil,
        self:NewToken(Kind.EqualsGreaterThanToken),
        accessor
    )

    return self:NewPropertyAssignment(nil, self:NewIdentifier("get"), nil, nil, arrow)
end

function NodeFactory:NewESDecorateClassElementAccessSetMethod(nameComputed, nameExpr)
    local accessor
    if nameComputed then
        accessor = self:NewElementAccessExpression(self:NewIdentifier("obj"), nil, nameExpr, NodeFlags.None)
    else
        accessor = self:NewPropertyAccessExpression(self:NewIdentifier("obj"), nil, nameExpr, NodeFlags.None)
    end

    local assignment = self:NewAssignmentExpression(accessor, self:NewIdentifier("value"))
    local stmt = self:NewExpressionStatement(assignment)
    local body = self:NewBlock(self:NewNodeList({ stmt }), false)

    local objParam = self:NewParameterDeclaration(nil, nil, self:NewIdentifier("obj"), nil, nil, nil)
    local valueParam = self:NewParameterDeclaration(nil, nil, self:NewIdentifier("value"), nil, nil, nil)

    local arrow = self:NewArrowFunction(
        nil, nil,
        self:NewNodeList({ objParam, valueParam }),
        nil, nil,
        self:NewToken(Kind.EqualsGreaterThanToken),
        body
    )

    return self:NewPropertyAssignment(nil, self:NewIdentifier("set"), nil, nil, arrow)
end

function NodeFactory:NewESDecorateClassElementAccessHasMethod(nameComputed, nameExpr)
    -- The property name for the "in" expression
    local propertyName
    if not nameComputed and nameExpr ~= nil and ast.IsIdentifier(nameExpr) then
        propertyName = self:NewStringLiteralFromNode(nameExpr)
    else
        propertyName = nameExpr
    end

    local objParam = self:NewParameterDeclaration(nil, nil, self:NewIdentifier("obj"), nil, nil, nil)
    local inExpr = self:NewBinaryExpression(nil, propertyName, nil, self:NewToken(Kind.InKeyword), self:NewIdentifier("obj"))

    local arrow = self:NewArrowFunction(
        nil, nil,
        self:NewNodeList({ objParam }),
        nil, nil,
        self:NewToken(Kind.EqualsGreaterThanToken),
        inExpr
    )

    return self:NewPropertyAssignment(nil, self:NewIdentifier("has"), nil, nil, arrow)
end

-- Creates the "access" object for a class element decorator context.
--
-- 15.7.3 CreateDecoratorAccessObject (kind, name)
--
--  2. If _kind_ is ~field~, ~method~, ~accessor~, or ~getter~, then
--     a. Let _getAccess_ be a new Abstract Closure with parameters (_object_) that captures _kind_ and _name_ ...
--     b. Perform ! CreateDataPropertyOrThrow(_access_, "get", _getAccess_).
--  3. If _kind_ is ~field~, ~accessor~, or ~setter~, then
--     a. Let _setAccess_ be a new Abstract Closure with parameters (_object_, _value_) that captures _kind_ and _name_ ...
--     b. Perform ! CreateDataPropertyOrThrow(_access_, "set", _setAccess_).
function NodeFactory:NewESDecorateClassElementAccessObject(nameComputed, nameExpr, hasGet, hasSet)
    local accessProps = {}

    -- "has" method: obj => name in obj
    accessProps[#accessProps + 1] = self:NewESDecorateClassElementAccessHasMethod(nameComputed, nameExpr)

    -- "get" method: obj => obj.name or obj => obj[name]
    if hasGet then
        accessProps[#accessProps + 1] = self:NewESDecorateClassElementAccessGetMethod(nameComputed, nameExpr)
    end

    -- "set" method: (obj, value) => { obj.name = value; } or (obj, value) => { obj[name] = value; }
    if hasSet then
        accessProps[#accessProps + 1] = self:NewESDecorateClassElementAccessSetMethod(nameComputed, nameExpr)
    end

    return self:NewObjectLiteralExpression(self:NewNodeList(accessProps), false)
end

function NodeFactory:NewESDecorateClassElementContextObject(kind, nameComputed, nameExpr, isStatic, isPrivate, hasGet, hasSet, metadata)
    -- Build the name value for the context's "name" property
    local nameValue
    if not nameComputed and nameExpr ~= nil and (ast.IsPrivateIdentifier(nameExpr) or ast.IsIdentifier(nameExpr)) then
        nameValue = self:NewStringLiteralFromNode(nameExpr)
    else
        nameValue = nameExpr
    end

    -- Build the access object with has/get/set arrow functions
    local accessObj = self:NewESDecorateClassElementAccessObject(nameComputed, nameExpr, hasGet, hasSet)

    local staticExpr
    if isStatic then
        staticExpr = self:NewTrueExpression()
    else
        staticExpr = self:NewFalseExpression()
    end

    local privateExpr
    if isPrivate then
        privateExpr = self:NewTrueExpression()
    else
        privateExpr = self:NewFalseExpression()
    end

    local props = {
        self:NewPropertyAssignment(nil, self:NewIdentifier("kind"), nil, nil, self:NewStringLiteral(kind, 0)),
        self:NewPropertyAssignment(nil, self:NewIdentifier("name"), nil, nil, nameValue),
        self:NewPropertyAssignment(nil, self:NewIdentifier("static"), nil, nil, staticExpr),
        self:NewPropertyAssignment(nil, self:NewIdentifier("private"), nil, nil, privateExpr),
        self:NewPropertyAssignment(nil, self:NewIdentifier("access"), nil, nil, accessObj),
        self:NewPropertyAssignment(nil, self:NewIdentifier("metadata"), nil, nil, metadata),
    }
    return self:NewObjectLiteralExpression(self:NewNodeList(props), false)
end

function NodeFactory:NewESDecorateHelper(ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers)
    self.emitContext:RequestEmitHelper(printer.esDecorateHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__esDecorate"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers }),
        NodeFlags.None
    )
end

function NodeFactory:NewRunInitializersHelper(thisArg, initializers, value)
    self.emitContext:RequestEmitHelper(printer.runInitializersHelper)
    local arguments
    if value ~= nil then
        arguments = { thisArg, initializers, value }
    else
        arguments = { thisArg, initializers }
    end
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__runInitializers"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList(arguments),
        NodeFlags.None
    )
end

-- ES2015 Helpers

function NodeFactory:NewTemplateObjectHelper(cookedArray, rawArray)
    self.emitContext:RequestEmitHelper(printer.makeTemplateObjectHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__makeTemplateObject"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ cookedArray, rawArray }),
        NodeFlags.None
    )
end

function NodeFactory:NewPropKeyHelper(expr)
    self.emitContext:RequestEmitHelper(printer.propKeyHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__propKey"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ expr }),
        NodeFlags.None
    )
end

function NodeFactory:NewSetFunctionNameHelper(fn, name, prefix)
    self.emitContext:RequestEmitHelper(printer.setFunctionNameHelper)
    local arguments
    if #prefix > 0 then
        arguments = { fn, name, self:NewStringLiteral(prefix, TokenFlags.None) }
    else
        arguments = { fn, name }
    end
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__setFunctionName"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList(arguments),
        NodeFlags.None
    )
end

-- ES Module Helpers

-- Allocates a new Call expression to the `__importDefault` helper.
function NodeFactory:NewImportDefaultHelper(expression)
    self.emitContext:RequestEmitHelper(printer.importDefaultHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__importDefault"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ expression }),
        NodeFlags.None
    )
end

-- Allocates a new Call expression to the `__importStar` helper.
function NodeFactory:NewImportStarHelper(expression)
    self.emitContext:RequestEmitHelper(printer.importStarHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__importStar"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ expression }),
        NodeFlags.None
    )
end

-- Allocates a new Call expression to the `__exportStar` helper.
function NodeFactory:NewExportStarHelper(moduleExpression, exportsExpression)
    self.emitContext:RequestEmitHelper(printer.exportStarHelper)
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__exportStar"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList({ moduleExpression, exportsExpression }),
        NodeFlags.None
    )
end

function NodeFactory:NewAssignmentTargetWrapper(paramName, expression)
    local setAccessor = self:NewSetAccessorDeclaration(
        nil, --[[modifiers]]
        self:NewIdentifier("value"),
        nil, --[[typeParameters]]
        self:NewNodeList({
            self:NewParameterDeclaration(nil, nil, paramName, nil, nil, nil),
        }),
        nil, --[[returnType]]
        nil, --[[fullSignature]]
        self:NewBlock(self:NewNodeList({
            self:NewExpressionStatement(expression),
        }), false)
    )
    local objLiteral = self:NewObjectLiteralExpression(self:NewNodeList({ setAccessor }), false)
    -- Explicit parens required because of v8 regression (https://bugs.chromium.org/p/v8/issues/detail?id=9560)
    return self:NewPropertyAccessExpression(
        self:NewParenthesizedExpression(objLiteral),
        nil, --[[questionDotToken]]
        self:NewIdentifier("value"),
        NodeFlags.None
    )
end

-- Allocates a new Call expression to the `__rewriteRelativeImportExtension` helper.
function NodeFactory:NewRewriteRelativeImportExtensionsHelper(firstArgument, preserveJsx)
    self.emitContext:RequestEmitHelper(printer.rewriteRelativeImportExtensionsHelper)
    local arguments
    if preserveJsx then
        arguments = { firstArgument, self:NewToken(Kind.TrueKeyword) }
    else
        arguments = { firstArgument }
    end
    return self:NewCallExpression(
        self:NewUnscopedHelperName("__rewriteRelativeImportExtension"),
        nil, --[[questionDotToken]]
        nil, --[[typeArguments]]
        self:NewNodeList(arguments),
        NodeFlags.None
    )
end
