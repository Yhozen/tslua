local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local SubtreeFacts = ast.SubtreeFacts

local nullishCoalescingTransformer = transformers.NewTransformerType()
estransforms.nullishCoalescingTransformer = nullishCoalescingTransformer

function nullishCoalescingTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsNullishCoalescing == 0 then
        return node
    end
    if node.kind == Kind.BinaryExpression then
        return self:visitBinaryExpression(node:AsBinaryExpression())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function nullishCoalescingTransformer:visitBinaryExpression(node)
    if node.operatorToken.kind == Kind.QuestionQuestionToken then
        local left = self:Visitor():VisitNode(node.left)
        local right = left
        if not transformers.IsSimpleCopiableExpression(left) then
            right = self:Factory():NewTempVariable()
            self:EmitContext():AddVariableDeclaration(right)
            left = self:Factory():NewAssignmentExpression(right, left)
        end
        return self:Factory():NewConditionalExpression(
            estransforms.createNotNullCondition(self:EmitContext(), left, right, false),
            self:Factory():NewToken(Kind.QuestionToken),
            right,
            self:Factory():NewToken(Kind.ColonToken),
            self:Visitor():VisitNode(node.right)
        )
    else
        return self:Visitor():VisitEachChild(node:AsNode())
    end
end

function estransforms.newNullishCoalescingTransformer(opts)
    local tx = setmetatable({}, nullishCoalescingTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end
