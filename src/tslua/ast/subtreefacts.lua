local ast = require("tslua.ast")

local SubtreeFacts = ast.SubtreeFacts
local None = SubtreeFacts.None

function ast.propagateEraseableSyntaxListSubtreeFacts(children)
    return children ~= nil and SubtreeFacts.SubtreeContainsTypeScript or None
end

function ast.propagateEraseableSyntaxSubtreeFacts(child)
    return child ~= nil and SubtreeFacts.SubtreeContainsTypeScript or None
end

function ast.propagateObjectBindingElementSubtreeFacts(child)
    local facts = ast.propagateSubtreeFacts(child)
    if facts & SubtreeFacts.SubtreeContainsRestOrSpread ~= 0 then
        facts = facts & ~SubtreeFacts.SubtreeContainsRestOrSpread
        facts = facts | SubtreeFacts.SubtreeContainsObjectRestOrSpread | SubtreeFacts.SubtreeContainsESObjectRestOrSpread
    end
    return facts
end

function ast.propagateBindingElementSubtreeFacts(child)
    return ast.propagateSubtreeFacts(child) & ~SubtreeFacts.SubtreeContainsRestOrSpread
end

function ast.propagateSubtreeFacts(child)
    if child == nil then
        return None
    end
    return child:propagateSubtreeFacts()
end

function ast.propagateNodeListSubtreeFacts(children, propagate)
    if children == nil then
        return None
    end
    local facts = None
    local nodes = children.nodes
    for i = 1, #nodes do
        facts = facts | propagate(nodes[i])
    end
    return facts
end

function ast.propagateModifierListSubtreeFacts(children)
    if children == nil then
        return None
    end
    return ast.propagateNodeListSubtreeFacts(children, ast.propagateSubtreeFacts)
end
