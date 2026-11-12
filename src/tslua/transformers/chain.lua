local transformers = require("tslua.transformers")
local ast = require("tslua.ast")

local chainedTransformer = transformers.NewTransformerType()
transformers.chainedTransformer = chainedTransformer

function chainedTransformer:visit(node)
    if node.kind ~= ast.Kind.SourceFile then
        error("Chained transform passed non-sourcefile initial node", 0)
    end
    local result = node:AsSourceFile()
    for _, t in ipairs(self.components) do
        result = t:TransformSourceFile(result)
    end
    return result:AsNode()
end

-- TransformOptions is a plain table:
--   { context = printer.EmitContext, compilerOptions = core.CompilerOptions,
--     resolver = binder.ReferenceResolver, emitResolver = printer.EmitResolver,
--     getEmitModuleFormatOfFile = function(file) -> core.ModuleKind }
-- TransformerFactory = function(opt) -> Transformer (or nil)

-- Chains transforms in left-to-right order, running them one at a time in order (as opposed to interleaved at each node)
-- - the resulting combined transform only operates on SourceFile nodes
function transformers.Chain(...)
    local transforms = { ... }
    if #transforms < 2 then
        if #transforms == 0 then
            error("Expected some number of transforms to chain, but got none", 0)
        end
        return transforms[1]
    end
    return function(opt)
        local constructed = {}
        for _, t in ipairs(transforms) do
            -- TODO: flatten nested chains?
            local result = t(opt)
            if result ~= nil then
                constructed[#constructed + 1] = result
            end
        end
        if #constructed == 0 then
            return nil
        elseif #constructed == 1 then
            return constructed[1]
        end
        local ch = setmetatable({ components = constructed }, chainedTransformer)
        return ch:NewTransformer(function(node) return ch:visit(node) end, opt.context)
    end
end
