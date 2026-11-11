local vfsmatch = require("tslua.vfs.vfsmatch")

function vfsmatch.Usage_String(i)
    local name = vfsmatch.Usage_names[i]
    if name == nil then
        return "Usage(" .. tostring(i) .. ")"
    end
    return name
end

return vfsmatch
