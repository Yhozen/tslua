local modulespecifiers = require("tslua.modulespecifiers")

local function countSlashes(s)
    local n = 0
    for _ in string.gmatch(s, "/") do
        n = n + 1
    end
    return n
end

function modulespecifiers.CountPathComponents(path)
    local initial = 0
    if string.sub(path, 1, 2) == "./" then
        initial = 2
    end
    return countSlashes(string.sub(path, initial + 1))
end

return modulespecifiers
