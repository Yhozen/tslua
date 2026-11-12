local transformers = require("tslua.transformers")
local printer = require("tslua.printer")

-- Transformer is embedded by every concrete transformer. A concrete transformer is a table whose
-- metatable chain falls back to transformers.Transformer (see transformers.NewTransformerType);
-- Go's `tx.NewTransformer(tx.visit, ctx)` is `tx:NewTransformer(function(node) return tx:visit(node) end, ctx)`
-- and returns the concrete transformer itself (it answers every *Transformer method).
--
-- Fields: emitContext, factory, visitor (nil until NewTransformer is called).
local Transformer = {}
Transformer.__index = Transformer
transformers.Transformer = Transformer

-- Lua helper (Go struct embedding): returns a method table for a struct embedding
-- transformers.Transformer (or another such struct given as base). Instances are created with
-- setmetatable({ ...fields... }, T).
function transformers.NewTransformerType(base)
    local T = setmetatable({}, { __index = base or Transformer })
    T.__index = T
    return T
end

function Transformer:NewTransformer(visit, emitContext)
    if self.emitContext ~= nil then
        error("Transformer already initialized", 0)
    end
    if emitContext == nil then
        emitContext = printer.NewEmitContext()
    end
    self.emitContext = emitContext
    self.factory = emitContext.factory
    self.visitor = emitContext:NewNodeVisitor(visit)
    return self
end

function Transformer:EmitContext()
    return self.emitContext
end

function Transformer:Visitor()
    return self.visitor
end

function Transformer:Factory()
    return self.factory
end

function Transformer:TransformSourceFile(file)
    return self.visitor:VisitSourceFile(file)
end
