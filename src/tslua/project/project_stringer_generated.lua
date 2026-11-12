local project = require("tslua.project")

function project.Kind_String(i)
    local name = project.Kind_names[i]
    if name == nil then
        return "Kind(" .. tostring(i) .. ")"
    end
    return name
end
