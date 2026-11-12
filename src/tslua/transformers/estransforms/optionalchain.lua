local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local debug = require("tslua.debug")
local printer = require("tslua.printer")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SubtreeFacts = ast.SubtreeFacts
local EF = printer.EmitFlags

local optionalChainTransformer = transformers.NewTransformerType()
estransforms.optionalChainTransformer = optionalChainTransformer

function optionalChainTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsOptionalChaining == 0 then
        return node
    end
    local k = node.kind
    if k == Kind.CallExpression then
        return self:visitCallExpression(node:AsCallExpression(), false)
    elseif k == Kind.PropertyAccessExpression or k == Kind.ElementAccessExpression then
        if node.flags & NodeFlags.OptionalChain ~= 0 then
            return self:visitOptionalExpression(node, false, false)
        end
        return self:Visitor():VisitEachChild(node)
    elseif k == Kind.DeleteExpression then
        return self:visitDeleteExpression(node:AsDeleteExpression())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function optionalChainTransformer:visitCallExpression(node, captureThisArg)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        -- If `node` is an optional chain, then it is the outermost chain of an optional expression.
        return self:visitOptionalExpression(node:AsNode(), captureThisArg, false)
    end
    if ast.IsParenthesizedExpression(node.expression) then
        local unwrapped = ast.SkipParentheses(node.expression)
        if unwrapped.flags & NodeFlags.OptionalChain ~= 0 then
            -- capture thisArg for calls of parenthesized optional chains like `(foo?.bar)()`
            local expression = self:visitParenthesizedExpression(node.expression:AsParenthesizedExpression(), true, false)
            local args = self:Visitor():VisitNodes(node.arguments)
            if ast.IsSyntheticReferenceExpression(expression) then
                local res = self:Factory():NewFunctionCallCall(expression:AsSyntheticReferenceExpression().expression, expression:AsSyntheticReferenceExpression().thisArg, args.nodes)
                res.loc = node.loc
                self:EmitContext():SetOriginal(res, node:AsNode())
                return res
            end
            return self:Factory():UpdateCallExpression(node, expression, nil --[[questionDotToken]], nil --[[typeArguments]], args, node.flags)
        end
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function optionalChainTransformer:visitParenthesizedExpression(node, captureThisArg, isDelete)
    local expr = self:visitNonOptionalExpression(node.expression, captureThisArg, isDelete)
    if ast.IsSyntheticReferenceExpression(expr) then
        -- `(a.b)` -> { expression `((_a = a).b)`, thisArg: `_a` }
        -- `(a[b])` -> { expression `((_a = a)[b])`, thisArg: `_a` }
        local synth = expr:AsSyntheticReferenceExpression()
        local res = self:Factory():NewSyntheticReferenceExpression(self:Factory():UpdateParenthesizedExpression(node, synth.expression), synth.thisArg)
        self:EmitContext():SetOriginal(res, node:AsNode())
        return res
    end
    return self:Factory():UpdateParenthesizedExpression(node, expr)
end

function optionalChainTransformer:visitPropertyOrElementAccessExpression(node, captureThisArg, isDelete)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        -- If `node` is an optional chain, then it is the outermost chain of an optional expression.
        return self:visitOptionalExpression(node:AsNode(), captureThisArg, isDelete)
    end
    local expression = self:Visitor():VisitNode(node:Expression())
    debug.Assert(expression == nil or not ast.IsSyntheticReferenceExpression(expression))

    local thisArg
    if captureThisArg then
        if not transformers.IsSimpleCopiableExpression(expression) then
            thisArg = self:Factory():NewTempVariable()
            self:EmitContext():AddVariableDeclaration(thisArg)
            expression = self:Factory():NewAssignmentExpression(thisArg, expression)
        else
            thisArg = expression
        end
    end

    if node.kind == Kind.PropertyAccessExpression then
        local p = node:AsPropertyAccessExpression()
        expression = self:Factory():UpdatePropertyAccessExpression(p, expression, nil --[[questionDotToken]], self:Visitor():VisitNode(p:Name()), p.flags)
    else
        local p = node:AsElementAccessExpression()
        expression = self:Factory():UpdateElementAccessExpression(p, expression, nil, self:Visitor():VisitNode(p:AsElementAccessExpression().argumentExpression), p.flags)
    end

    if thisArg ~= nil then
        local res = self:Factory():NewSyntheticReferenceExpression(expression, thisArg)
        self:EmitContext():SetOriginal(res, node:AsNode())
        return res
    end
    return expression
end

function optionalChainTransformer:visitDeleteExpression(node)
    local unwrapped = ast.SkipParentheses(node.expression)
    if unwrapped.flags & NodeFlags.OptionalChain ~= 0 then
        return self:visitNonOptionalExpression(node.expression, false, true)
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function optionalChainTransformer:visitNonOptionalExpression(node, captureThisArg, isDelete)
    local k = node.kind
    if k == Kind.ParenthesizedExpression then
        return self:visitParenthesizedExpression(node:AsParenthesizedExpression(), captureThisArg, isDelete)
    elseif k == Kind.ElementAccessExpression or k == Kind.PropertyAccessExpression then
        return self:visitPropertyOrElementAccessExpression(node, captureThisArg, isDelete)
    elseif k == Kind.CallExpression then
        return self:visitCallExpression(node:AsCallExpression(), captureThisArg)
    else
        return self:Visitor():VisitNode(node:AsNode())
    end
end

-- flattenResult: { expression = Expression, chain = []Node }

function estransforms.isNonNullChain(node)
    return ast.IsNonNullExpression(node) and node.flags & NodeFlags.OptionalChain ~= 0
end

function estransforms.flattenChain(chain)
    debug.Assert(not estransforms.isNonNullChain(chain))
    local links = { chain }
    while not ast.IsTaggedTemplateExpression(chain) and chain:QuestionDotToken() == nil do
        chain = ast.SkipPartiallyEmittedExpressions(chain:Expression())
        debug.Assert(not estransforms.isNonNullChain(chain))
        table.insert(links, 1, chain)
    end
    return { expression = chain:Expression(), chain = links }
end

function estransforms.isCallChain(node)
    return ast.IsCallExpression(node) and node.flags & NodeFlags.OptionalChain ~= 0
end

function optionalChainTransformer:visitOptionalExpression(node, captureThisArg, isDelete)
    local r = estransforms.flattenChain(node)
    local expression = r.expression
    local chain = r.chain
    local left = self:visitNonOptionalExpression(ast.SkipPartiallyEmittedExpressions(expression), estransforms.isCallChain(chain[1]), false)
    local leftThisArg
    local capturedLeft = left
    if ast.IsSyntheticReferenceExpression(left) then
        leftThisArg = left:AsSyntheticReferenceExpression().thisArg
        capturedLeft = left:AsSyntheticReferenceExpression().expression
    end
    local leftExpression = self:Factory():RestoreOuterExpressions(expression, capturedLeft, ast.OuterExpressionKinds.OEKPartiallyEmittedExpressions)
    if not transformers.IsSimpleCopiableExpression(capturedLeft) then
        capturedLeft = self:Factory():NewTempVariable()
        self:EmitContext():AddVariableDeclaration(capturedLeft)
        leftExpression = self:Factory():NewAssignmentExpression(capturedLeft, leftExpression)
    end
    local rightExpression = capturedLeft
    local thisArg

    for i1, segment in ipairs(chain) do
        local i = i1 - 1
        local k = segment.kind
        if k == Kind.ElementAccessExpression or k == Kind.PropertyAccessExpression then
            if i == #chain - 1 and captureThisArg then
                if not transformers.IsSimpleCopiableExpression(rightExpression) then
                    thisArg = self:Factory():NewTempVariable()
                    self:EmitContext():AddVariableDeclaration(thisArg)
                    rightExpression = self:Factory():NewAssignmentExpression(thisArg, rightExpression)
                else
                    thisArg = rightExpression
                end
            end
            if segment.kind == Kind.ElementAccessExpression then
                rightExpression = self:Factory():NewElementAccessExpression(rightExpression, nil, self:Visitor():VisitNode(segment:AsElementAccessExpression().argumentExpression), NodeFlags.None)
            else
                rightExpression = self:Factory():NewPropertyAccessExpression(rightExpression, nil, self:Visitor():VisitNode(segment:AsPropertyAccessExpression():Name()), NodeFlags.None)
            end
        elseif k == Kind.CallExpression then
            if i == 0 and leftThisArg ~= nil then
                if not self:EmitContext():HasAutoGenerateInfo(leftThisArg) then
                    leftThisArg = leftThisArg:Clone(self:Factory())
                    self:EmitContext():AddEmitFlags(leftThisArg, EF.EFNoComments)
                end
                local callThisArg = leftThisArg
                if leftThisArg.kind == Kind.SuperKeyword then
                    callThisArg = self:Factory():NewThisExpression()
                end
                rightExpression = self:Factory():NewFunctionCallCall(rightExpression, callThisArg, self:Visitor():VisitNodes(segment:ArgumentList()).nodes)
            else
                rightExpression = self:Factory():NewCallExpression(
                    rightExpression,
                    nil,
                    nil,
                    self:Visitor():VisitNodes(segment:ArgumentList()),
                    NodeFlags.None
                )
            end
        end
        self:EmitContext():SetOriginal(rightExpression, segment)
    end

    local target
    if isDelete then
        target = self:Factory():NewConditionalExpression(
            estransforms.createNotNullCondition(self:EmitContext(), leftExpression, capturedLeft, true),
            self:Factory():NewToken(Kind.QuestionToken),
            self:Factory():NewTrueExpression(),
            self:Factory():NewToken(Kind.ColonToken),
            self:Factory():NewDeleteExpression(rightExpression)
        )
    else
        target = self:Factory():NewConditionalExpression(
            estransforms.createNotNullCondition(self:EmitContext(), leftExpression, capturedLeft, true),
            self:Factory():NewToken(Kind.QuestionToken),
            self:Factory():NewVoidZeroExpression(),
            self:Factory():NewToken(Kind.ColonToken),
            rightExpression
        )
    end
    target.loc = node.loc
    if thisArg ~= nil then
        target = self:Factory():NewSyntheticReferenceExpression(target, thisArg)
    end
    self:EmitContext():SetOriginal(target, node:AsNode())
    return target
end

function estransforms.newOptionalChainTransformer(opts)
    local tx = setmetatable({}, optionalChainTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end
