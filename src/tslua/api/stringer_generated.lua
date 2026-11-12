local api = require("tslua.api")

-- MessageType_String is Go's MessageType.String (stringer).
function api.MessageType_String(i)
    local name = api.MessageType_names[i]
    if name == nil then
        return "MessageType(" .. tostring(i) .. ")"
    end
    return "MessageType" .. name
end
