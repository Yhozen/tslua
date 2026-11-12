local format = require("tslua.format")

local ruleImpl = {}
ruleImpl.__index = ruleImpl
format.ruleImpl = ruleImpl

function ruleImpl:Action()
    return self.action
end

function ruleImpl:Context()
    return self.context
end

function ruleImpl:Flags()
    return self.flags
end

function ruleImpl:String()
    return self.debugName
end

-- tokenRange: { tokens = { ast.Kind... }, isSpecific = bool }
-- ruleSpec: { leftTokenRange = tokenRange, rightTokenRange = tokenRange, rule = ruleImpl }

--[[*
 * A rule takes a two tokens (left/right) and a particular context
 * for which you're meant to look at them. You then declare what should the
 * whitespace annotation be between these tokens via the action param.
 *
 * @param debugName Name to print
 * @param left The left side of the comparison
 * @param right The right side of the comparison
 * @param context A set of filters to narrow down the space in which this formatter rule applies
 * @param action a declaration of the expected whitespace
 * @param flags whether the rule deletes a line or not, defaults to no-op
 ]]
function format.rule(debugName, left, right, context, action, ...)
    local flag = format.ruleFlags.None
    if select("#", ...) > 0 then
        flag = (...)
    end
    local leftRange = format.toTokenRange(left)
    local rightRange = format.toTokenRange(right)
    local rule = setmetatable({
        debugName = debugName,
        context = context,
        action = action,
        flags = flag,
    }, ruleImpl)
    return {
        leftTokenRange = leftRange,
        rightTokenRange = rightRange,
        rule = rule,
    }
end

-- e is an ast.Kind (integer), a []ast.Kind (plain array) or a tokenRange (table with isSpecific).
function format.toTokenRange(e)
    if math.type(e) == "integer" then
        return { isSpecific = true, tokens = { e } }
    elseif type(e) == "table" and e.isSpecific == nil then
        return { isSpecific = true, tokens = e }
    elseif type(e) == "table" then
        return e
    end
    error("Unknown argument type passed to toTokenRange - only ast.Kind, []ast.Kind, and tokenRange supported")
end

-- contextPredicate = fn(ctx *FormattingContext) bool

format.anyContext = {}

format.ruleAction = {
    None = 0,
    StopProcessingSpaceActions = 1 << 0,
    StopProcessingTokenActions = 1 << 1,
    InsertSpace = 1 << 2,
    InsertNewLine = 1 << 3,
    DeleteSpace = 1 << 4,
    DeleteToken = 1 << 5,
    InsertTrailingSemicolon = 1 << 6,
}
format.ruleAction.StopAction = format.ruleAction.StopProcessingSpaceActions |
    format.ruleAction.StopProcessingTokenActions
format.ruleAction.ModifySpaceAction = format.ruleAction.InsertSpace | format.ruleAction.InsertNewLine |
    format.ruleAction.DeleteSpace
format.ruleAction.ModifyTokenAction = format.ruleAction.DeleteToken | format.ruleAction.InsertTrailingSemicolon

format.ruleFlags = {
    None = 0,
    CanDeleteNewLines = 1,
}
