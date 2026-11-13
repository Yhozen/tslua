local syntax = require("tslua.regexp.syntax")
local strconv = require("tslua.regexp.strconv")

-- Go Op.String.
function syntax.Op_String(i)
    local name = syntax.Op_names[i]
    if name ~= nil then
        return name
    end
    if i == syntax.opPseudo then
        return "opPseudo"
    end
    return "Op(" .. strconv.FormatInt(i, 10) .. ")"
end
