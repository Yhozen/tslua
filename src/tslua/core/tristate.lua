local core = require("tslua.core")

local Tristate = core.Tristate

-- Aliases: docs/PORTING.md spells these core.Tristate.Unknown/False/True; the generated names
-- are core.Tristate.TSUnknown/TSFalse/TSTrue. Both work, as do core.TSUnknown/TSFalse/TSTrue.
Tristate.Unknown = Tristate.TSUnknown
Tristate.False = Tristate.TSFalse
Tristate.True = Tristate.TSTrue
core.TSUnknown = Tristate.TSUnknown
core.TSFalse = Tristate.TSFalse
core.TSTrue = Tristate.TSTrue

function core.Tristate_IsTrue(t)
    return t == Tristate.TSTrue
end

function core.Tristate_IsTrueOrUnknown(t)
    return t == Tristate.TSTrue or t == Tristate.TSUnknown
end

function core.Tristate_IsFalse(t)
    return t == Tristate.TSFalse
end

function core.Tristate_IsFalseOrUnknown(t)
    return t == Tristate.TSFalse or t == Tristate.TSUnknown
end

function core.Tristate_IsUnknown(t)
    return t == Tristate.TSUnknown
end

function core.Tristate_DefaultIfUnknown(t, value)
    if t == Tristate.TSUnknown then
        return value
    end
    return t
end

-- Go (*Tristate).UnmarshalJSON: returns the new Tristate value for the raw JSON text.
function core.Tristate_UnmarshalJSON(data)
    if data == "true" then
        return Tristate.TSTrue
    elseif data == "false" then
        return Tristate.TSFalse
    else
        return Tristate.TSUnknown
    end
end

function core.Tristate_MarshalJSON(t)
    if t == Tristate.TSTrue then
        return "true", nil
    elseif t == Tristate.TSFalse then
        return "false", nil
    else
        return "null", nil
    end
end

function core.BoolToTristate(b)
    if b then
        return Tristate.TSTrue
    end
    return Tristate.TSFalse
end
