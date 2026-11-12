local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SubtreeFacts = ast.SubtreeFacts

local logicalAssignmentTransformer = transformers.NewTransformerType()
estransforms.logicalAssignmentTransformer = logicalAssignmentTransformer

function logicalAssignmentTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsLogicalAssignments == 0 then
        return node
    end
    if node.kind == Kind.BinaryExpression then
        return self:visitBinaryExpression(node:AsBinaryExpression())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function logicalAssignmentTransformer:visitBinaryExpression(node)
    local nonAssignmentOperator
    local k = node.operatorToken.kind
    if k == Kind.BarBarEqualsToken then
        nonAssignmentOperator = Kind.BarBarToken
    elseif k == Kind.AmpersandAmpersandEqualsToken then
        nonAssignmentOperator = Kind.AmpersandAmpersandToken
    elseif k == Kind.QuestionQuestionEqualsToken then
        nonAssignmentOperator = Kind.QuestionQuestionToken
    else
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local left = ast.SkipParentheses(self:Visitor():VisitNode(node.left))
    local assignmentTarget = left
    local right = ast.SkipParentheses(self:Visitor():VisitNode(node.right))

    if ast.IsAccessExpression(left) then
        local propertyAccessTargetSimpleCopiable = transformers.IsSimpleCopiableExpression(left:Expression())
        local propertyAccessTarget = left:Expression()
        local propertyAccessTargetAssignment = left:Expression()
        if not propertyAccessTargetSimpleCopiable then
            propertyAccessTarget = self:Factory():NewTempVariable()
            self:EmitContext():AddVariableDeclaration(propertyAccessTarget)
            propertyAccessTargetAssignment = self:Factory():NewAssignmentExpression(
                propertyAccessTarget,
                left:Expression()
            )
        end

        if ast.IsPropertyAccessExpression(left) then
            assignmentTarget = self:Factory():NewPropertyAccessExpression(
                propertyAccessTarget,
                nil,
                left:Name(),
                NodeFlags.None
            )
            left = self:Factory():NewPropertyAccessExpression(
                propertyAccessTargetAssignment,
                nil,
                left:Name(),
                NodeFlags.None
            )
        else
            local elementAccessArgumentSimpleCopiable = transformers.IsSimpleCopiableExpression(left:AsElementAccessExpression().argumentExpression)
            local elementAccessArgument = left:AsElementAccessExpression().argumentExpression
            local argumentExpr = elementAccessArgument
            if not elementAccessArgumentSimpleCopiable then
                elementAccessArgument = self:Factory():NewTempVariable()
                self:EmitContext():AddVariableDeclaration(elementAccessArgument)
                argumentExpr = self:Factory():NewAssignmentExpression(
                    elementAccessArgument,
                    left:AsElementAccessExpression().argumentExpression
                )
            end

            assignmentTarget = self:Factory():NewElementAccessExpression(
                propertyAccessTarget,
                nil,
                elementAccessArgument,
                NodeFlags.None
            )
            left = self:Factory():NewElementAccessExpression(
                propertyAccessTargetAssignment,
                nil,
                argumentExpr,
                NodeFlags.None
            )
        end
    end

    return self:Factory():NewBinaryExpression(
        nil,
        left,
        nil,
        self:Factory():NewToken(nonAssignmentOperator),
        self:Factory():NewParenthesizedExpression(
            self:Factory():NewAssignmentExpression(
                assignmentTarget,
                right
            )
        )
    )
end

function estransforms.newLogicalAssignmentTransformer(opts)
    local tx = setmetatable({}, logicalAssignmentTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end
