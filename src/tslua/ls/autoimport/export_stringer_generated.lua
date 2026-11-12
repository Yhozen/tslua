local autoimport = require("tslua.ls.autoimport")

function autoimport.ExportSyntax_String(i)
    local name = autoimport.ExportSyntax_names[i]
    if name == nil then
        return "ExportSyntax(" .. tostring(i) .. ")"
    end
    return "ExportSyntax" .. name
end
