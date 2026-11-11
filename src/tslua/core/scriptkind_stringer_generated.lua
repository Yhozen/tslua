local core = require("tslua.core")

function core.ScriptKind_String(i)
    local name = core.ScriptKind_names[i]
    if name == nil then
        return "ScriptKind(" .. string.format("%d", i) .. ")"
    end
    return "ScriptKind" .. name
end
