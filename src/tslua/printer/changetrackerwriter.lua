local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

-- ChangeTrackerWriter: { textWriter (the embedded textWriter, kept as its own table because
-- textWriter:Clear resets every field of its receiver), lastNonTriviaPosition, pos, end_ }
-- pos/end_ are keyed by *ast.Node or *ast.NodeList (identity).
local ChangeTrackerWriter = {}
printer.ChangeTrackerWriter = ChangeTrackerWriter
ChangeTrackerWriter.__index = function(self, k)
    local m = ChangeTrackerWriter[k]
    if m ~= nil then
        return m
    end
    -- methods promoted from the embedded textWriter
    local tm = printer.textWriter[k]
    if type(tm) == "function" then
        return function(ct, ...)
            return tm(ct.textWriter, ...)
        end
    end
    return nil
end

function printer.NewChangeTrackerWriter(newline, indentSize)
    -- TODO: Callers passing -1 should pass actual indent options once indent-related formatting is ported.
    if indentSize < 0 then
        indentSize = printer.defaultIndentSize
    end
    local ctw = setmetatable({
        textWriter = setmetatable({ newLine = newline, indentSize = indentSize }, printer.textWriter),
        lastNonTriviaPosition = 0,
        pos = {},
        end_ = {},
    }, ChangeTrackerWriter)
    ctw.textWriter:Clear()
    return ctw
end

function ChangeTrackerWriter:GetPrintHandlers()
    return {
        onBeforeEmitNode = function(nodeOpt)
            if nodeOpt ~= nil then
                self:setPos(nodeOpt)
            end
        end,
        onAfterEmitNode = function(nodeOpt)
            if nodeOpt ~= nil then
                self:setEnd(nodeOpt)
            end
        end,
        onBeforeEmitNodeList = function(nodesOpt)
            if nodesOpt ~= nil then
                self:setPos(nodesOpt)
            end
        end,
        onAfterEmitNodeList = function(nodesOpt)
            if nodesOpt ~= nil then
                self:setEnd(nodesOpt)
            end
        end,
        onBeforeEmitToken = function(nodeOpt)
            if nodeOpt ~= nil then
                self:setPos(nodeOpt)
            end
        end,
        onAfterEmitToken = function(nodeOpt)
            if nodeOpt ~= nil then
                self:setEnd(nodeOpt)
            end
        end,
    }
end

function ChangeTrackerWriter:setPos(node)
    self.pos[node] = self.lastNonTriviaPosition
end

function ChangeTrackerWriter:setEnd(node)
    self.end_[node] = self.lastNonTriviaPosition
end

function ChangeTrackerWriter:getPos(node)
    return self.pos[node] or 0
end

function ChangeTrackerWriter:getEnd(node)
    return self.end_[node] or 0
end

function ChangeTrackerWriter:setLastNonTriviaPosition(s, force)
    if force or scanner.SkipTrivia(s, 0) ~= #s then
        self.lastNonTriviaPosition = self.textWriter:GetTextPos()
        -- trim trailing whitespaces
        local pos = #s
        while pos > 0 do
            local r, size = core.DecodeLastRune(s, pos)
            if stringutil.IsWhiteSpaceLike(r) then
                pos = pos - size
            else
                break
            end
        end
        self.lastNonTriviaPosition = self.lastNonTriviaPosition - (#s - pos)
    end
end

function ChangeTrackerWriter:AssignPositionsToNode(node, factory)
    local visitor
    visitor = ast.NewNodeVisitor(function(n)
        return self:assignPositionsToNodeWorker(n, visitor)
    end, factory, {
        visitNode = function(n, v)
            return self:assignPositionsToNodeWorker(n, v)
        end,
        visitNodes = function(nodes, v)
            return self:assignPositionsToNodeArray(nodes, v)
        end,
        visitToken = function(n, v)
            return self:assignPositionsToNodeWorker(n, v)
        end,
        visitModifiers = function(modifiers, v)
            if modifiers ~= nil then
                local newNodeList = self:assignPositionsToNodeArray(modifiers, v)
                -- Return a new ModifierList so that VisitEachChild/Update detects the
                -- change and creates a new node with reassigned child positions.
                return factory:NewModifierList(newNodeList.nodes)
            end
            return modifiers
        end,
    })
    return self:assignPositionsToNodeWorker(node, visitor)
end

function ChangeTrackerWriter:assignPositionsToNodeWorker(node, v)
    if node == nil then
        return node
    end
    local visited = node:VisitEachChild(v)
    -- create proxy node for non synthesized nodes
    local newNode = visited
    if not ast.NodeIsSynthesized(visited) then
        newNode = visited:Clone(v.factory)
    end
    newNode:ForEachChild(function(child)
        child.parent = newNode
        return true
    end)
    newNode.loc = core.NewTextRange(self:getPos(node), self:getEnd(node))
    return newNode
end

function ChangeTrackerWriter:assignPositionsToNodeArray(nodes, v)
    local visited = v:VisitNodes(nodes)
    if visited == nil then
        return visited
    end
    if nodes == nil then
        -- Debug.assert(nodes);
        error("if nodes is nil, visited should not be nil", 0)
    end
    -- clone nodearray if necessary
    local nodeArray = visited
    if visited == nodes then
        nodeArray = visited:Clone(v.factory)
    end

    nodeArray.loc = core.NewTextRange(self:getPos(nodes), self:getEnd(nodes))
    return nodeArray
end

function ChangeTrackerWriter:Write(text)
    self.textWriter:Write(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteTrailingSemicolon(text)
    self.textWriter:WriteTrailingSemicolon(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteComment(text) self.textWriter:WriteComment(text) end

function ChangeTrackerWriter:WriteKeyword(text)
    self.textWriter:WriteKeyword(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteOperator(text)
    self.textWriter:WriteOperator(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WritePunctuation(text)
    self.textWriter:WritePunctuation(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteSpace(text)
    self.textWriter:WriteSpace(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteStringLiteral(text)
    self.textWriter:WriteStringLiteral(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteParameter(text)
    self.textWriter:WriteParameter(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteProperty(text)
    self.textWriter:WriteProperty(text)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteSymbol(text, symbol)
    self.textWriter:WriteSymbol(text, symbol)
    self:setLastNonTriviaPosition(text, false)
end

function ChangeTrackerWriter:WriteLine() self.textWriter:WriteLine() end
function ChangeTrackerWriter:WriteLineForce(force) self.textWriter:WriteLineForce(force) end
function ChangeTrackerWriter:IncreaseIndent() self.textWriter:IncreaseIndent() end
function ChangeTrackerWriter:DecreaseIndent() self.textWriter:DecreaseIndent() end

function ChangeTrackerWriter:Clear()
    self.textWriter:Clear()
    self.lastNonTriviaPosition = 0
end

function ChangeTrackerWriter:String() return self.textWriter:String() end

function ChangeTrackerWriter:RawWrite(s)
    self.textWriter:RawWrite(s)
    self:setLastNonTriviaPosition(s, false)
end

function ChangeTrackerWriter:WriteLiteral(s)
    self.textWriter:WriteLiteral(s)
    self:setLastNonTriviaPosition(s, true)
end

function ChangeTrackerWriter:GetTextPos() return self.textWriter:GetTextPos() end
function ChangeTrackerWriter:GetLine() return self.textWriter:GetLine() end
function ChangeTrackerWriter:GetColumn() return self.textWriter:GetColumn() end
function ChangeTrackerWriter:GetIndent() return self.textWriter:GetIndent() end
function ChangeTrackerWriter:IsAtStartOfLine() return self.textWriter:IsAtStartOfLine() end

function ChangeTrackerWriter:HasTrailingComment() return self.textWriter:HasTrailingComment() end

function ChangeTrackerWriter:HasTrailingWhitespace()
    return self.textWriter:HasTrailingWhitespace()
end
