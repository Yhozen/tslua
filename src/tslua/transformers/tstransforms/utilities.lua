local tstransforms = require("tslua.transformers.tstransforms")
local ast = require("tslua.ast")
local jsnum = require("tslua.jsnum")

function tstransforms.constantExpression(value, factory)
    if type(value) == "string" then
        return factory:NewStringLiteral(value, ast.TokenFlags.None)
    elseif type(value) == "number" then
        if jsnum.Number_IsInf(value) then
            if value > 0 then
                return factory:NewIdentifier("Infinity")
            end
            return factory:NewPrefixUnaryExpression(ast.Kind.MinusToken, factory:NewIdentifier("Infinity"))
        end
        if jsnum.Number_IsNaN(value) then
            return factory:NewIdentifier("NaN")
        end
        if value < 0 then
            return factory:NewPrefixUnaryExpression(ast.Kind.MinusToken, tstransforms.constantExpression(-value, factory))
        end
        return factory:NewNumericLiteral(jsnum.Number_String(value), ast.TokenFlags.None)
    end
    return nil
end
