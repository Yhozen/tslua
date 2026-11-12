local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")

local Kind = ast.Kind

-- Gets whether a node is a `static {}` block containing only a single assignment of the static `this` to the `_classThis`
-- (or similar) variable stored in the `classthis` property of the block's `EmitNode`.
function estransforms.isClassThisAssignmentBlock(emitContext, node)
    if ast.IsClassStaticBlockDeclaration(node) then
        local n = node:AsClassStaticBlockDeclaration()
        local body = n.body:AsBlock()
        if #body.statements.nodes == 1 then
            local statement = body.statements.nodes[1]
            if ast.IsExpressionStatement(statement) then
                local expression = statement:Expression()
                if ast.IsAssignmentExpression(expression, true) then
                    local binary = expression:AsBinaryExpression()
                    return ast.IsIdentifier(binary.left) and
                        emitContext:ClassThis(node) == binary.left and
                        binary.right.kind == Kind.ThisKeyword
                end
            end
        end
    end
    return false
end
