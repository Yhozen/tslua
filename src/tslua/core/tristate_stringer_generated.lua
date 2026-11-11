local core = require("tslua.core")

function core.Tristate_String(i)
    local name = core.Tristate_names[i]
    if name == nil then
        return "Tristate(" .. string.format("%d", i) .. ")"
    end
    return name
end
