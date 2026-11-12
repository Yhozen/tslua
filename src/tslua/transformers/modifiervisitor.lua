local transformers = require("tslua.transformers")
local ast = require("tslua.ast")

local modifierVisitor = transformers.NewTransformerType()
transformers.modifierVisitor = modifierVisitor

function modifierVisitor:visit(node)
    local flags = ast.ModifierToFlag(node.kind)
    if flags ~= ast.ModifierFlags.None and flags & self.allowedModifiers == 0 then
        return nil
    end
    return node
end

function transformers.ExtractModifiers(emitContext, modifiers, allowed)
    if modifiers == nil then
        return nil
    end
    local tx = setmetatable({ allowedModifiers = allowed }, modifierVisitor)
    tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
    return tx.visitor:VisitModifiers(modifiers)
end
