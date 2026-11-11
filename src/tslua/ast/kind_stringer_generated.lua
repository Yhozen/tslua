local ast = require("tslua.ast")

-- Go: func (i Kind) String() string (stringer output, e.g. "KindIdentifier").
function ast.Kind_String(i)
    if i >= 0 and i <= ast.Kind.Count then
        local name = ast.Kind_names[i]
        if name ~= nil then
            return "Kind" .. name
        end
    end
    return "Kind(" .. string.format("%d", i) .. ")"
end
