local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local SubtreeFacts = ast.SubtreeFacts

local optionalCatchTransformer = transformers.NewTransformerType()
estransforms.optionalCatchTransformer = optionalCatchTransformer

function optionalCatchTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsMissingCatchClauseVariable == 0 then
        return node
    end
    if node.kind == Kind.CatchClause then
        return self:visitCatchClause(node:AsCatchClause())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function optionalCatchTransformer:visitCatchClause(node)
    if node.variableDeclaration == nil then
        return self:Factory():NewCatchClause(
            self:Factory():NewVariableDeclaration(self:Factory():NewTempVariable(), nil, nil, nil),
            self:Visitor().visit(node.block)
        )
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function estransforms.newOptionalCatchTransformer(opts)
    local tx = setmetatable({}, optionalCatchTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end
