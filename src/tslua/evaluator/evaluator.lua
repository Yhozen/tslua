local evaluator = require("tslua.evaluator")
local ast = require("tslua.ast")
local jsnum = require("tslua.jsnum")

local Kind = ast.Kind

-- Result.value is a Go `any`: nil, a jsnum.Number (Lua number), a string, a boolean or a
-- jsnum.PseudoBigInt (table).
local Result = {}
Result.__index = Result
evaluator.Result = Result

function evaluator.NewResult(value, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
    return setmetatable({
        value = value,
        isSyntacticallyString = isSyntacticallyString,
        resolvedOtherFiles = resolvedOtherFiles,
        hasExternalReferences = hasExternalReferences,
    }, Result)
end

local NewResult = function(...)
    return evaluator.NewResult(...)
end

local function isNumber(v)
    return type(v) == "number"
end

-- Evaluator is a function(expr, location) -> Result.
function evaluator.NewEvaluator(evaluateEntity, outerExpressionsToSkip)
    local evaluate
    evaluate = function(expr, location)
        local isSyntacticallyString = false
        local resolvedOtherFiles = false
        local hasExternalReferences = false
        -- It's unclear when/whether we should consider skipping other kinds of outer expressions.
        -- Type assertions intentionally break evaluation when evaluating literal types, such as:
        --     type T = `one ${"two" as any} three`; // string
        -- But it's less clear whether such an assertion should break enum member evaluation:
        --     enum E {
        --       A = "one" as any
        --     }
        -- SatisfiesExpressions and non-null assertions seem to have even less reason to break
        -- emitting enum members as literals. However, these expressions also break Babel's
        -- evaluation (but not esbuild's), and the isolatedModules errors we give depend on
        -- our evaluation results, so we're currently being conservative so as to issue errors
        -- on code that might break Babel.
        expr = ast.SkipOuterExpressions(expr, outerExpressionsToSkip | ast.OuterExpressionKinds.OEKParentheses)
        local kind = expr.kind
        if kind == Kind.PrefixUnaryExpression then
            local result = evaluate(expr.operand, location)
            resolvedOtherFiles = result.resolvedOtherFiles
            hasExternalReferences = result.hasExternalReferences
            local value = result.value
            if isNumber(value) then
                local op = expr.operator
                if op == Kind.PlusToken then
                    return NewResult(value, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif op == Kind.MinusToken then
                    return NewResult(-value, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif op == Kind.TildeToken then
                    return NewResult(jsnum.Number_BitwiseNOT(value), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                end
            end
        elseif kind == Kind.BinaryExpression then
            local left = evaluate(expr.left, location)
            local right = evaluate(expr.right, location)
            local operator = expr.operatorToken.kind
            isSyntacticallyString = (left.isSyntacticallyString or right.isSyntacticallyString) and expr.operatorToken.kind == Kind.PlusToken
            resolvedOtherFiles = left.resolvedOtherFiles or right.resolvedOtherFiles
            hasExternalReferences = left.hasExternalReferences or right.hasExternalReferences
            local leftIsNum = isNumber(left.value)
            local rightIsNum = isNumber(right.value)
            local leftNum = leftIsNum and left.value or 0.0
            local rightNum = rightIsNum and right.value or 0.0
            if leftIsNum and rightIsNum then
                if operator == Kind.BarToken then
                    return NewResult(jsnum.Number_BitwiseOR(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.AmpersandToken then
                    return NewResult(jsnum.Number_BitwiseAND(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.GreaterThanGreaterThanToken then
                    return NewResult(jsnum.Number_SignedRightShift(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.GreaterThanGreaterThanGreaterThanToken then
                    return NewResult(jsnum.Number_UnsignedRightShift(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.LessThanLessThanToken then
                    return NewResult(jsnum.Number_LeftShift(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.CaretToken then
                    return NewResult(jsnum.Number_BitwiseXOR(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.AsteriskToken then
                    return NewResult(leftNum * rightNum, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.SlashToken then
                    return NewResult(leftNum / rightNum, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.PlusToken then
                    return NewResult(leftNum + rightNum, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.MinusToken then
                    return NewResult(leftNum - rightNum, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.PercentToken then
                    return NewResult(jsnum.Number_Remainder(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                elseif operator == Kind.AsteriskAsteriskToken then
                    return NewResult(jsnum.Number_Exponentiate(leftNum, rightNum), isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
                end
            end
            local leftIsStr = type(left.value) == "string"
            local rightIsStr = type(right.value) == "string"
            local leftStr = leftIsStr and left.value or ""
            local rightStr = rightIsStr and right.value or ""
            if (leftIsStr or leftIsNum) and (rightIsStr or rightIsNum) and operator == Kind.PlusToken then
                if leftIsNum then
                    leftStr = jsnum.Number_String(leftNum)
                end
                if rightIsNum then
                    rightStr = jsnum.Number_String(rightNum)
                end
                return NewResult(leftStr .. rightStr, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
            end
        elseif kind == Kind.StringLiteral or kind == Kind.NoSubstitutionTemplateLiteral then
            return NewResult(expr:Text(), true --[[isSyntacticallyString]], false, false)
        elseif kind == Kind.TemplateExpression then
            return evaluator.evaluateTemplateExpression(expr, location, evaluate)
        elseif kind == Kind.NumericLiteral then
            return NewResult(jsnum.FromString(expr:Text()), false, false, false)
        elseif kind == Kind.Identifier then
            return evaluateEntity(expr, location)
        elseif kind == Kind.ElementAccessExpression or kind == Kind.PropertyAccessExpression then
            if ast.IsEntityNameExpression(expr:Expression()) then
                return evaluateEntity(expr, location)
            end
        end
        return NewResult(nil, isSyntacticallyString, resolvedOtherFiles, hasExternalReferences)
    end
    return evaluate
end

function evaluator.evaluateTemplateExpression(expr, location, evaluate)
    local sb = { expr.head:Text() }
    local resolvedOtherFiles = false
    local hasExternalReferences = false
    for _, span in ipairs(expr.templateSpans.nodes) do
        local spanResult = evaluate(span:Expression(), location)
        if spanResult.value == nil then
            return NewResult(nil, true --[[isSyntacticallyString]], false, false)
        end
        sb[#sb + 1] = evaluator.AnyToString(spanResult.value)
        sb[#sb + 1] = span.literal:Text()
        resolvedOtherFiles = resolvedOtherFiles or spanResult.resolvedOtherFiles
        hasExternalReferences = hasExternalReferences or spanResult.hasExternalReferences
    end
    return NewResult(table.concat(sb), true, resolvedOtherFiles, hasExternalReferences)
end

function evaluator.AnyToString(v)
    local t = type(v)
    if t == "string" then
        return v
    elseif t == "number" then
        return jsnum.Number_String(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "table" then -- jsnum.PseudoBigInt
        return v:String()
    end
    error("Unhandled case in AnyToString")
end

function evaluator.IsTruthy(v)
    local t = type(v)
    if t == "string" then
        return #v ~= 0
    elseif t == "number" then
        return v ~= 0 and not jsnum.Number_IsNaN(v)
    elseif t == "boolean" then
        return v
    elseif t == "table" then -- jsnum.PseudoBigInt
        return v.negative ~= false or v.base10Value ~= ""
    end
    error("Unhandled case in IsTruthy")
end
