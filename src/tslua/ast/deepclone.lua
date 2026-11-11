local ast = require("tslua.ast")
local core = require("tslua.core")

-- Ideally, this would get cached on the node factory so there's only ever one set of closures made per factory
function ast.getDeepCloneVisitor(f, syntheticLocation)
    local visitor
    visitor = ast.NewNodeVisitor(
        function(node)
            local visited = visitor:VisitEachChild(node)
            if visited ~= node then
                if syntheticLocation then
                    visited.loc = core.NewTextRange(-1, -1)
                end
                return visited
            end
            local c = node:Clone(f) -- forcibly clone leaf nodes, which will then cascade new nodes/arrays upwards via `update` calls
            -- In strada, `factory.cloneNode` was dynamic and did _not_ clone positions for any "special cases", meanwhile
            -- Node.Clone in corsa reliably uses `Update` calls for all nodes and so copies locations by default.
            -- Deep clones are done to copy a node across files, so here, we explicitly make the location range synthetic on all cloned nodes
            if syntheticLocation then
                c.loc = core.NewTextRange(-1, -1)
            end
            return c
        end,
        f,
        {
            visitNodes = function(nodes, v)
                if nodes == nil then
                    return nil
                end
                local visited = v:VisitNodes(nodes)
                local newList
                if visited ~= nodes then
                    newList = visited
                else
                    newList = nodes:Clone(v.factory)
                end
                if syntheticLocation then
                    newList.loc = core.NewTextRange(-1, -1)
                    if nodes:HasTrailingComma() then
                        newList.nodes[#newList.nodes].loc = core.NewTextRange(-2, -2)
                    end
                end
                return newList
            end,
            visitModifiers = function(nodes, v)
                if nodes == nil then
                    return nil
                end
                local visited = v:VisitModifiers(nodes)
                local newList
                if visited ~= nodes then
                    newList = visited
                else
                    newList = nodes:Clone(v.factory)
                end
                if syntheticLocation then
                    newList.loc = core.NewTextRange(-1, -1)
                    if nodes:HasTrailingComma() then
                        newList.nodes[#newList.nodes].loc = core.NewTextRange(-2, -2)
                    end
                end
                return newList
            end,
        }
    )
    return visitor
end

function ast.NodeFactory:DeepCloneNode(node)
    return ast.getDeepCloneVisitor(self, true --[[syntheticLocation]]):VisitNode(node)
end

function ast.NodeFactory:DeepCloneReparse(node)
    if node ~= nil then
        node = ast.getDeepCloneVisitor(self, false --[[syntheticLocation]]):VisitNode(node)
        ast.SetParentInChildren(node)
        node.flags = node.flags | ast.NodeFlags.Reparsed
    end
    return node
end

function ast.NodeFactory:DeepCloneReparseModifiers(modifiers)
    return ast.getDeepCloneVisitor(self, false --[[syntheticLocation]]):VisitModifiers(modifiers)
end
