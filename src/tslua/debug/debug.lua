local debug = require("tslua.debug")

-- fmt.Sprint for the values debug messages are built from.
local function sprint(...)
    local n = select("#", ...)
    local parts = {}
    local prevString = true
    for i = 1, n do
        local v = select(i, ...)
        local isString = type(v) == "string"
        -- fmt.Sprint adds spaces between operands when neither is a string.
        if i > 1 and not isString and not prevString then
            parts[#parts + 1] = " "
        end
        parts[#parts + 1] = debug.formatValue(v)
        prevString = isString
    end
    return table.concat(parts)
end

function debug.formatValue(v)
    if type(v) == "table" then
        local mt = getmetatable(v)
        if mt ~= nil then
            if type(v.KindString) == "function" then
                return v:KindString()
            end
            if mt.__tostring ~= nil then
                return tostring(v)
            end
            if type(v.String) == "function" then
                return v:String()
            end
        end
        return tostring(v)
    elseif v == nil then
        return "<nil>"
    end
    return tostring(v)
end

function debug.Fail(reason)
    if reason == nil or #reason == 0 then
        reason = "Debug failure."
    else
        reason = "Debug failure. " .. reason
    end
    error(reason, 2)
end

function debug.FailBadSyntaxKind(node, ...)
    local msg
    if select("#", ...) == 0 then
        msg = "Unexpected node."
    else
        msg = sprint(...)
    end
    debug.Fail(msg .. "\nNode " .. node:KindString() .. " was unexpected.")
end

function debug.AssertNever(member, ...)
    local msg
    if select("#", ...) == 0 then
        msg = "Illegal value:"
    else
        msg = sprint(...)
    end
    debug.Fail(msg .. " " .. debug.formatValue(member))
end

function debug.Assert(value, ...)
    if value then
        return
    end
    debug.assertSlow(...)
end

function debug.assertSlow(...)
    local msg
    if select("#", ...) > 0 then
        msg = "False expression: " .. sprint(...)
    else
        msg = "False expression."
    end
    debug.Fail(msg)
end
