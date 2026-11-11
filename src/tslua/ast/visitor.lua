local ast = require("tslua.ast")

local Kind = ast.Kind

-- NodeVisitor: { visit = fn(node) -> node, factory = NodeFactory, hooks = NodeVisitorHooks }

local NodeVisitor = {}
NodeVisitor.__index = NodeVisitor
NodeVisitor.__name = "NodeVisitor"
ast.NodeVisitor = NodeVisitor

-- These hooks are used to intercept the default behavior of the visitor.
-- NodeVisitorHooks is a plain table with optional fields (Go field names lowerCamel-cased):
--   visitNode(node, v), visitToken(node, v), visitNodes(nodes, v), visitModifiers(nodes, v),
--   visitEmbeddedStatement(node, v), visitIterationBody(node, v), visitParameters(nodes, v),
--   visitFunctionBody(node, v), visitTopLevelStatements(nodes, v)

function ast.NewNodeVisitor(visit, factory, hooks)
    if factory == nil then
        factory = ast.NewNodeFactory({})
    end
    return setmetatable({ visit = visit, factory = factory, hooks = hooks or {} }, NodeVisitor)
end

function NodeVisitor:VisitSourceFile(node)
    return self:VisitNode(node):AsSourceFile()
end

-- Visits a Node, possibly returning a new Node in its place.
--
--   - If the input node is nil, then the output is nil.
--   - If v.Visit is nil, then the output is the input.
--   - If v.Visit returns nil, then the output is nil.
--   - If v.Visit returns a SyntaxList Node, then the output is the only child of the SyntaxList Node.
function NodeVisitor:VisitNode(node)
    if node == nil or self.visit == nil then
        return node
    end

    if self.visit ~= nil then
        local visited = self.visit(node)
        if visited ~= nil and visited.kind == Kind.SyntaxList then
            local nodes = visited:AsSyntaxList().children
            if nodes == nil or #nodes ~= 1 then
                error("Expected only a single node to be written to output")
            end
            visited = nodes[1]
            if visited ~= nil and visited.kind == Kind.SyntaxList then
                error("The result of visiting and lifting a Node may not be SyntaxList")
            end
        end
        return visited
    end

    return node
end

-- Visits an embedded Statement (i.e., the single statement body of a loop, `if..else` branch, etc.), possibly returning a new Statement in its place.
--
--   - If the input node is nil, then the output is nil.
--   - If v.Visit is nil, then the output is the input.
--   - If v.Visit returns nil, then the output is nil.
--   - If v.Visit returns a SyntaxList Node, then the output is either the only child of the SyntaxList Node, or a Block containing the nodes in the list.
function NodeVisitor:VisitEmbeddedStatement(node)
    if node == nil or self.visit == nil then
        return node
    end

    local visited = self.visit(node)
    if visited == nil then
        return nil
    end
    return self:liftToBlock(visited)
end

-- Visits a NodeList, possibly returning a new NodeList in its place.
--
--   - If the input NodeList is nil, the output is nil.
--   - If v.Visit is nil, then the output is the input.
--   - If v.Visit returns nil, the visited Node will be absent in the output.
--   - If v.Visit returns a different Node than the input, a new NodeList will be generated and returned.
--   - If v.Visit returns a SyntaxList Node, then the children of that node will be merged into the output and a new NodeList will be returned.
--   - If this method returns a new NodeList for any reason, it will have the same Loc as the input NodeList.
function NodeVisitor:VisitNodes(nodes)
    if nodes == nil or self.visit == nil then
        return nodes
    end

    local result, changed = self:VisitSlice(nodes.nodes)
    if changed then
        local list = self.factory:NewNodeList(result)
        list.loc = nodes.loc
        return list
    end

    return nodes
end

-- Visits a ModifierList, possibly returning a new ModifierList in its place.
--
--   - If the input ModifierList is nil, the output is nil.
--   - If v.Visit is nil, then the output is the input.
--   - If v.Visit returns nil, the visited Node will be absent in the output.
--   - If v.Visit returns a different Node than the input, a new ModifierList will be generated and returned.
--   - If v.Visit returns a SyntaxList Node, then the children of that node will be merged into the output and a new NodeList will be returned.
--   - If this method returns a new NodeList for any reason, it will have the same Loc as the input NodeList.
function NodeVisitor:VisitModifiers(nodes)
    if nodes == nil or self.visit == nil then
        return nodes
    end

    local result, changed = self:VisitSlice(nodes.nodes)
    if changed then
        local list = self.factory:NewModifierList(result)
        list.loc = nodes.loc
        return list
    end

    return nodes
end

-- Visits a slice of Nodes, returning the resulting slice and a value indicating whether the slice was changed.
--
--   - If the input slice is nil, the output is nil.
--   - If v.Visit is nil, then the output is the input.
--   - If v.Visit returns nil, the visited Node will be absent in the output.
--   - If v.Visit returns a different Node than the input, a new slice will be generated and returned.
--   - If v.Visit returns a SyntaxList Node, then the children of that node will be merged into the output and a new slice will be returned.
function NodeVisitor:VisitSlice(nodes)
    if nodes == nil or self.visit == nil then
        return nodes, false
    end

    local i = 0
    while i < #nodes do
        local node = nodes[i + 1]
        if self.visit == nil then
            break
        end

        local visited = self.visit(node)
        if visited == nil or visited ~= node then
            local updated = {}
            for k = 1, i do
                updated[k] = nodes[k]
            end

            while true do
                -- finish prior loop
                if visited == nil then
                    -- do nothing
                elseif visited.kind == Kind.SyntaxList then
                    local children = visited:AsSyntaxList().children
                    if children ~= nil then
                        for _, c in ipairs(children) do
                            updated[#updated + 1] = c
                        end
                    end
                else
                    updated[#updated + 1] = visited
                end

                i = i + 1

                -- loop over remaining elements
                if i >= #nodes then
                    break
                end

                if self.visit ~= nil then
                    node = nodes[i + 1]
                    visited = self.visit(node)
                else
                    for k = i + 1, #nodes do
                        updated[#updated + 1] = nodes[k]
                    end
                    break
                end
            end

            return updated, true
        end
        i = i + 1
    end

    return nodes, false
end

-- Visits each child of a Node, possibly returning a new Node of the same kind in its place.
function NodeVisitor:VisitEachChild(node)
    if node == nil or self.visit == nil then
        return node
    end

    return node:VisitEachChild(self)
end

function NodeVisitor:visitNode(node)
    if self.hooks.visitNode ~= nil then
        return self.hooks.visitNode(node, self)
    end
    return self:VisitNode(node)
end

function NodeVisitor:visitEmbeddedStatement(node)
    if self.hooks.visitEmbeddedStatement ~= nil then
        return self.hooks.visitEmbeddedStatement(node, self)
    end
    if self.hooks.visitNode ~= nil then
        return self:liftToBlock(self.hooks.visitNode(node, self))
    end
    return self:VisitEmbeddedStatement(node)
end

function NodeVisitor:visitIterationBody(node)
    if self.hooks.visitIterationBody ~= nil then
        return self.hooks.visitIterationBody(node, self)
    end
    return self:visitEmbeddedStatement(node)
end

function NodeVisitor:visitFunctionBody(node)
    if self.hooks.visitFunctionBody ~= nil then
        return self.hooks.visitFunctionBody(node, self)
    end
    return self:visitNode(node)
end

function NodeVisitor:visitToken(node)
    if self.hooks.visitToken ~= nil then
        return self.hooks.visitToken(node, self)
    end
    return self:VisitNode(node)
end

function NodeVisitor:visitNodes(nodes)
    if self.hooks.visitNodes ~= nil then
        return self.hooks.visitNodes(nodes, self)
    end
    return self:VisitNodes(nodes)
end

function NodeVisitor:visitModifiers(nodes)
    if self.hooks.visitModifiers ~= nil then
        return self.hooks.visitModifiers(nodes, self)
    end
    return self:VisitModifiers(nodes)
end

function NodeVisitor:visitParameters(nodes)
    if self.hooks.visitParameters ~= nil then
        return self.hooks.visitParameters(nodes, self)
    end
    return self:visitNodes(nodes)
end

function NodeVisitor:visitTopLevelStatements(nodes)
    if self.hooks.visitTopLevelStatements ~= nil then
        return self.hooks.visitTopLevelStatements(nodes, self)
    end
    return self:visitNodes(nodes)
end

function NodeVisitor:liftToBlock(node)
    local nodes = nil
    if node ~= nil then
        if node.kind == Kind.SyntaxList then
            nodes = node:AsSyntaxList().children
        else
            nodes = { node }
        end
    end
    if nodes ~= nil and #nodes == 1 then
        node = nodes[1]
    else
        node = self.factory:NewBlock(self.factory:NewNodeList(nodes), true --[[multiLine]])
    end
    if node.kind == Kind.SyntaxList then
        error("The result of visiting and lifting a Node may not be SyntaxList")
    end
    return node
end
