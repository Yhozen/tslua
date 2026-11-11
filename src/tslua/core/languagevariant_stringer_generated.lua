local core = require("tslua.core")

function core.LanguageVariant_String(i)
    local name = core.LanguageVariant_names[i]
    if name == nil then
        return "LanguageVariant(" .. string.format("%d", i) .. ")"
    end
    return "LanguageVariant" .. name
end
