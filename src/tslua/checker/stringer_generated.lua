local checker = require("tslua.checker")

function checker.SignatureKind_String(i)
    local name = checker.SignatureKind_names[i]
    if name == nil then
        return "SignatureKind(" .. string.format("%d", i) .. ")"
    end
    return "SignatureKind" .. name
end
