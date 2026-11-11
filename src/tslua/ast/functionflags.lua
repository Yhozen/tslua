local ast = require("tslua.ast")

local Kind = ast.Kind
local FunctionFlags = ast.FunctionFlags

function ast.GetFunctionFlags(node)
    if node == nil then
        return FunctionFlags.Invalid
    end
    local data = node:BodyData()
    if data == nil then
        return FunctionFlags.Invalid
    end
    local flags = FunctionFlags.Normal
    local kind = node.kind
    if kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression or kind == Kind.MethodDeclaration or
        kind == Kind.ArrowFunction then
        if kind ~= Kind.ArrowFunction and data.asteriskToken ~= nil then
            flags = flags | FunctionFlags.Generator
        end
        -- fallthrough
        if ast.HasSyntacticModifier(node, ast.ModifierFlags.Async) then
            flags = flags | FunctionFlags.Async
        end
    end
    if data.body == nil then
        flags = flags | FunctionFlags.Invalid
    end
    return flags
end
