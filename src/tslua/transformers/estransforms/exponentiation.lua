local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SubtreeFacts = ast.SubtreeFacts

local exponentiationTransformer = transformers.NewTransformerType()
estransforms.exponentiationTransformer = exponentiationTransformer

function exponentiationTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsExponentiationOperator == 0 then
        return node
    end
    if node.kind == Kind.BinaryExpression then
        return self:visitBinaryExpression(node:AsBinaryExpression())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function exponentiationTransformer:visitBinaryExpression(node)
    local k = node.operatorToken.kind
    if k == Kind.AsteriskAsteriskEqualsToken then
        return self:visitExponentiationAssignmentExpression(node)
    elseif k == Kind.AsteriskAsteriskToken then
        return self:visitExponentiationExpression(node)
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function exponentiationTransformer:visitExponentiationAssignmentExpression(node)
    local target
    local value
    local left = self:Visitor():VisitNode(node.left)
    local right = self:Visitor():VisitNode(node.right)
    if ast.IsElementAccessExpression(left) then
        -- Transforms `a[x] **= b` into `(_a = a)[_x = x] = Math.pow(_a[_x], b)`
        local expressionTemp = self:Factory():NewTempVariable()
        self:EmitContext():AddVariableDeclaration(expressionTemp)
        local argumentExpressionTemp = self:Factory():NewTempVariable()
        self:EmitContext():AddVariableDeclaration(argumentExpressionTemp)

        local objExpr = self:Factory():NewAssignmentExpression(expressionTemp, left:Expression())
        objExpr.loc = left:Expression().loc
        local accessExpr = self:Factory():NewAssignmentExpression(argumentExpressionTemp, left:AsElementAccessExpression().argumentExpression)
        accessExpr.loc = left:AsElementAccessExpression().argumentExpression.loc

        target = self:Factory():NewElementAccessExpression(objExpr, nil, accessExpr, NodeFlags.None)

        value = self:Factory():NewElementAccessExpression(expressionTemp, nil, argumentExpressionTemp, NodeFlags.None)
        value.loc = left.loc
    elseif ast.IsPropertyAccessExpression(left) then
        -- Transforms `a.x **= b` into `(_a = a).x = Math.pow(_a.x, b)`
        local expressionTemp = self:Factory():NewTempVariable()
        self:EmitContext():AddVariableDeclaration(expressionTemp)
        local assignment = self:Factory():NewAssignmentExpression(expressionTemp, left:Expression())
        assignment.loc = left:Expression().loc
        target = self:Factory():NewPropertyAccessExpression(assignment, nil, left:Name(), NodeFlags.None)
        target.loc = left.loc

        value = self:Factory():NewPropertyAccessExpression(expressionTemp, nil, left:Name(), NodeFlags.None)
        value.loc = left.loc
    else
        -- Transforms `a **= b` into `a = Math.pow(a, b)`
        target = left
        value = left
    end

    local rhs = self:Factory():NewGlobalMethodCall("Math", "pow", { value, right })
    rhs.loc = node.loc
    local result = self:Factory():NewAssignmentExpression(target, rhs)
    result.loc = node.loc
    return result
end

function exponentiationTransformer:visitExponentiationExpression(node)
    local left = self:Visitor():VisitNode(node.left)
    local right = self:Visitor():VisitNode(node.right)
    local result = self:Factory():NewGlobalMethodCall("Math", "pow", { left, right })
    result.loc = node.loc
    return result
end

function estransforms.newExponentiationTransformer(opts)
    local tx = setmetatable({}, exponentiationTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end
